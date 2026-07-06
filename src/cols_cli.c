/* cols — CLI front end. All I/O lives here: argument parsing, env-var
 * precedence (flags > COLS_IFS > IFS > default), file/stdin streaming, and
 * output. Column mechanics live in the Zig core, consumed strictly through
 * the C FFI (include/cols.h) — this file deliberately cannot see Zig.
 *
 * Copyright (c) 2026 Peter Marreck. MIT License.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include "cols.h"

#ifdef _WIN32
#include <io.h>
#include <fcntl.h>
#endif

#define CHUNK_INITIAL (256 * 1024)

static const char *PROG = "cols";

static void *xrealloc(void *p, size_t n) {
	void *q = realloc(p, n);
	if (!q) {
		fprintf(stderr, "%s: out of memory\n", PROG);
		exit(1);
	}
	return q;
}

static void print_help(void) {
	printf(
		"cols — extract columns from line-oriented text by number\n"
		"\n"
		"Usage: <command> | cols <n | m-n | m- | comma,list> [more specs...]\n"
		"       cols [options] <specs...> [file | - | @stdin ...]\n"
		"\n"
		"Columns are 1-indexed. By default, runs of spaces/tabs count as one\n"
		"separator (awk semantics) and selected fields are joined with a single\n"
		"space. Lines missing the requested columns print as empty lines (line\n"
		"correspondence is preserved). Files may follow the specs; default input\n"
		"is stdin ('-' or '@stdin' also mean stdin).\n"
		"\n"
		"Specs (combinable, space- or comma-separated):\n"
		"  n             single column n\n"
		"  m-n           columns m through n\n"
		"  m-            column m through end of line\n"
		"  x,y,z         comma-joined list of any of the above\n"
		"\n"
		"Separator selection (highest precedence first; later flags win):\n"
		"  -e, --regex <pat>   PCRE2 regex separator (UTF-8)\n"
		"  -F <sep>            awk-style: ' ' = default whitespace mode;\n"
		"                      one char = literal; multi-char = PCRE2 regex\n"
		"  -d, -t <sep>        literal string separator, even multi-char\n"
		"                      (cut/sort muscle memory; adjacent = empty fields)\n"
		"  COLS_IFS            env var, shell word-splitting semantics\n"
		"  IFS                 env var, ditto — `IFS=: cols 1,7 < /etc/passwd`\n"
		"                      really works: a compiled binary receives IFS\n"
		"                      intact (shells scrub it for their own scripts)\n"
		"  (default)           runs of spaces/tabs, leading whitespace skipped\n"
		"\n"
		"IFS semantics are true shell word-splitting: whitespace members collapse\n"
		"in runs; non-whitespace members are strict delimiters (adjacent = empty\n"
		"field); empty IFS/COLS_IFS/-d = no splitting (whole line = column 1).\n"
		"\n"
		"Output:\n"
		"  Fields join with: the literal separator (-d/-t/one-char -F), the first\n"
		"  IFS character, or a single space (default and regex modes).\n"
		"  -O, --output-sep <s>  override the output separator\n"
		"  --json                emit a JSON array of arrays (one per input line)\n"
		"\n"
		"Options:\n"
		"  -h, --help, /h, /?    show this help\n"
		"  --about               one-line description with version and platform\n"
		"  -V, --version         print the version\n"
		"  --lang <code>         message language (groundwork; English for now)\n"
		"  --                    end of options\n"
		"\n"
		"Examples:\n"
		"  tailscale status | cols 2               # hostnames\n"
		"  ls -l | cols 5 9-                       # size + filename\n"
		"  IFS=: cols 1,7 < /etc/passwd            # user + shell, ':'-joined\n"
		"  cols -d, 2-4 data.csv                   # csv columns 2..4\n"
		"  cols -e '\\s{2,}' 1,3                    # split on 2+ spaces\n"
		"\n"
		"Exit codes: 0 success · 1 I/O error · 2 usage/spec error\n");
}

static void usage_hint(void) {
	fprintf(stderr, "Usage: <command> | %s <n | m-n | m- | comma,list> [more specs...]\n", PROG);
	fprintf(stderr, "Try '%s --help' for details.\n", PROG);
}

/* Spec-shaped: starts with a digit, contains only [0-9,-]. Such args are
 * always treated as column specs (a file named "3-2" needs a ./ prefix). */
static int is_spec_shaped(const char *s) {
	if (*s < '0' || *s > '9') return 0;
	for (const char *p = s; *p; p++) {
		if (!((*p >= '0' && *p <= '9') || *p == ',' || *p == '-')) return 0;
	}
	return 1;
}

/* Number of UTF-8 code points (continuation bytes don't count). */
static size_t utf8_cp_count(const char *s) {
	size_t n = 0;
	for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
		if ((*p & 0xC0) != 0x80) n++;
	}
	return n;
}

/* --- streaming ----------------------------------------------------------- */

static char *g_buf = NULL;
static size_t g_cap = 0;
static size_t g_fill = 0;

static int emit(cols_ctx *ctx, const char *data, size_t len) {
	const char *out;
	size_t out_len;
	if (cols_process(ctx, data, len, &out, &out_len) != 0) {
		fprintf(stderr, "%s: out of memory\n", PROG);
		return -1;
	}
	if (out_len > 0 && fwrite(out, 1, out_len, stdout) != out_len) {
		fprintf(stderr, "%s: write error: %s\n", PROG, strerror(errno));
		return -1;
	}
	return 0;
}

/* Stream one input through the ctx. Lines are cut at the last newline of
 * each read; the partial tail carries over (the buffer grows for lines
 * longer than it — no line-length limit). EOF flushes the unterminated
 * final line, so per-file line boundaries behave like awk/cut. */
static int stream_file(cols_ctx *ctx, FILE *f, const char *name) {
	for (;;) {
		if (g_fill == g_cap) {
			g_cap = g_cap ? g_cap * 2 : CHUNK_INITIAL;
			g_buf = xrealloc(g_buf, g_cap);
		}
		size_t n = fread(g_buf + g_fill, 1, g_cap - g_fill, f);
		if (n == 0) break;
		size_t scan_end = g_fill + n; /* only new bytes can hold a newline */
		size_t nl_end = 0;
		for (size_t i = scan_end; i > g_fill; i--) {
			if (g_buf[i - 1] == '\n') {
				nl_end = i;
				break;
			}
		}
		g_fill = scan_end;
		if (nl_end > 0) {
			if (emit(ctx, g_buf, nl_end) != 0) return -1;
			memmove(g_buf, g_buf + nl_end, g_fill - nl_end);
			g_fill -= nl_end;
		}
	}
	if (ferror(f)) {
		fprintf(stderr, "%s: read error on '%s': %s\n", PROG, name, strerror(errno));
		return -1;
	}
	if (g_fill > 0) { /* unterminated final line of THIS input */
		if (emit(ctx, g_buf, g_fill) != 0) return -1;
		g_fill = 0;
	}
	return 0;
}

/* --- main ---------------------------------------------------------------- */

int main(int argc, char **argv) {
#ifdef _WIN32
	_setmode(_fileno(stdin), _O_BINARY);
	_setmode(_fileno(stdout), _O_BINARY);
	_setmode(_fileno(stderr), _O_BINARY);
#endif

	if (cols_is_debug_build() && !getenv("MUTE_DEBUG_STATUS")) {
		fputs("\x1b[33mDEBUG BUILD\x1b[0m\n", stderr);
	}

	const char **specs = xrealloc(NULL, (size_t)(argc > 1 ? argc : 1) * sizeof(char *));
	const char **files = xrealloc(NULL, (size_t)(argc > 1 ? argc : 1) * sizeof(char *));
	size_t nspecs = 0, nfiles = 0;

	int sep_flag_set = 0;              /* any of -e/-F/-d/-t seen (flags beat env) */
	int sep_mode = COLS_SEP_DEFAULT;
	const char *sep_val = "";
	const char *out_sep = NULL;
	int out_sep_set = 0;
	int json = 0;
	const char *lang_flag = NULL;
	int after_dd = 0;

	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];

		if (!after_dd && a[0] == '-' && a[1] != '\0') {
			const char *val = NULL;

			if (strcmp(a, "--") == 0) {
				after_dd = 1;
				continue;
			}
			if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) {
				print_help();
				free(specs);
				free(files);
				return 0;
			}
			if (strcmp(a, "--about") == 0) {
				printf("%s\n", cols_about());
				free(specs);
				free(files);
				return 0;
			}
			if (strcmp(a, "-V") == 0 || strcmp(a, "--version") == 0) {
				printf("cols %s\n", cols_version());
				free(specs);
				free(files);
				return 0;
			}
			if (strcmp(a, "--json") == 0) {
				json = 1;
				continue;
			}

			/* value-taking flags: attached (-d:), detached (-d :), --long value,
			 * --long=value */
			if (a[1] == 'e' || a[1] == 'F' || a[1] == 'd' || a[1] == 't' || a[1] == 'O') {
				char c = a[1];
				if (a[2] != '\0') {
					val = a + 2;
				} else if (i + 1 < argc) {
					val = argv[++i];
				} else {
					fprintf(stderr, "%s: option '-%c' requires a value\n", PROG, c);
					return 2;
				}
				switch (c) {
					case 'e':
						sep_flag_set = 1;
						sep_mode = COLS_SEP_REGEX;
						sep_val = val;
						break;
					case 'd':
					case 't':
						sep_flag_set = 1;
						sep_mode = COLS_SEP_LITERAL;
						sep_val = val;
						break;
					case 'F': {
						sep_flag_set = 1;
						size_t cps = utf8_cp_count(val);
						if (strcmp(val, " ") == 0) {
							sep_mode = COLS_SEP_DEFAULT; /* awk: FS=" " is ws mode */
							sep_val = "";
						} else if (cps == 1) {
							sep_mode = COLS_SEP_LITERAL;
							sep_val = val;
						} else {
							sep_mode = COLS_SEP_REGEX; /* awk treats multi-char FS as ERE */
							sep_val = val;
						}
						break;
					}
					case 'O':
						out_sep = val;
						out_sep_set = 1;
						break;
				}
				continue;
			}
			if (strncmp(a, "--regex=", 8) == 0 || strcmp(a, "--regex") == 0) {
				val = (a[7] == '=') ? a + 8 : (i + 1 < argc ? argv[++i] : NULL);
				if (!val) {
					fprintf(stderr, "%s: option '--regex' requires a value\n", PROG);
					return 2;
				}
				sep_flag_set = 1;
				sep_mode = COLS_SEP_REGEX;
				sep_val = val;
				continue;
			}
			if (strncmp(a, "--output-sep=", 13) == 0 || strcmp(a, "--output-sep") == 0) {
				val = (a[12] == '=') ? a + 13 : (i + 1 < argc ? argv[++i] : NULL);
				if (!val) {
					fprintf(stderr, "%s: option '--output-sep' requires a value\n", PROG);
					return 2;
				}
				out_sep = val;
				out_sep_set = 1;
				continue;
			}
			if (strncmp(a, "--lang=", 7) == 0 || strcmp(a, "--lang") == 0) {
				val = (a[6] == '=') ? a + 7 : (i + 1 < argc ? argv[++i] : NULL);
				if (!val) {
					fprintf(stderr, "%s: option '--lang' requires a value\n", PROG);
					return 2;
				}
				lang_flag = val;
				continue;
			}

			fprintf(stderr, "%s: unknown option '%s'\n", PROG, a);
			usage_hint();
			return 2;
		}

		/* positionals */
		if (!after_dd && (strcmp(a, "/h") == 0 || strcmp(a, "/?") == 0)) {
			print_help();
			free(specs);
			free(files);
			return 0;
		}
		if (strcmp(a, "-") == 0 || strcmp(a, "@stdin") == 0) {
			files[nfiles++] = a;
		} else if (is_spec_shaped(a)) {
			specs[nspecs++] = a;
		} else if (nspecs == 0 && nfiles == 0) {
			/* first positional must be a spec; let the core render the
			 * canonical "invalid column spec" message */
			specs[nspecs++] = a;
		} else {
			files[nfiles++] = a;
		}
	}

	/* i18n groundwork (prepare phase): resolve the language now so the
	 * precedence chain is exercised; messages stay English until the
	 * enforce phase. --lang > COLS_LANG > LANG. */
	const char *lang = lang_flag;
	if (!lang) lang = getenv("COLS_LANG");
	if (!lang) lang = getenv("LANG");
	(void)lang;

	if (nspecs == 0) {
		fprintf(stderr, "%s: no column spec given\n", PROG);
		usage_hint();
		return 2;
	}

	/* Separator precedence: flags > COLS_IFS > IFS > default. The env vars
	 * get true shell word-splitting semantics; set-but-empty means "no
	 * splitting" exactly like shell IFS= (the core maps empty to NONE). */
	if (!sep_flag_set) {
		const char *cols_ifs = getenv("COLS_IFS");
		const char *ifs = getenv("IFS");
		if (cols_ifs) {
			sep_mode = COLS_SEP_IFS;
			sep_val = cols_ifs;
		} else if (ifs) {
			sep_mode = COLS_SEP_IFS;
			sep_val = ifs;
		}
	}

	cols_config cfg = {
		.sep_mode = sep_mode,
		.sep = sep_val,
		.sep_len = sep_val ? strlen(sep_val) : 0,
		.out_sep = out_sep_set ? out_sep : NULL,
		.out_sep_len = out_sep_set ? strlen(out_sep) : 0,
		.json = json,
	};

	char errbuf[512];
	cols_ctx *ctx = cols_create(specs, nspecs, &cfg, errbuf, sizeof errbuf);
	if (!ctx) {
		fprintf(stderr, "%s: %s\n", PROG, errbuf);
		return 2;
	}

	int rc = 0;
	if (nfiles == 0) {
		if (stream_file(ctx, stdin, "(stdin)") != 0) rc = 1;
	} else {
		for (size_t i = 0; i < nfiles && rc == 0; i++) {
			const char *path = files[i];
			if (strcmp(path, "-") == 0 || strcmp(path, "@stdin") == 0) {
				if (stream_file(ctx, stdin, "(stdin)") != 0) rc = 1;
				continue;
			}
			FILE *f = fopen(path, "rb");
			if (!f) {
				fprintf(stderr, "%s: cannot open '%s': %s\n", PROG, path, strerror(errno));
				rc = 1;
				break;
			}
			if (stream_file(ctx, f, path) != 0) rc = 1;
			fclose(f);
		}
	}

	if (rc == 0) {
		const char *out;
		size_t out_len;
		if (cols_finish(ctx, &out, &out_len) == 0) {
			if (out_len > 0 && fwrite(out, 1, out_len, stdout) != out_len) {
				fprintf(stderr, "%s: write error: %s\n", PROG, strerror(errno));
				rc = 1;
			}
		} else {
			fprintf(stderr, "%s: out of memory\n", PROG);
			rc = 1;
		}
	}

	if (fflush(stdout) != 0) {
		fprintf(stderr, "%s: write error: %s\n", PROG, strerror(errno));
		rc = 1;
	}

	cols_destroy(ctx);
	free(g_buf);
	free(specs);
	free(files);
	return rc;
}
