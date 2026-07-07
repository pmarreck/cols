/* cols — CLI front end. All I/O lives here: argument parsing, env-var
 * precedence (flags > COLS_IFS > IFS > default), file/stdin streaming, and
 * output. Column mechanics live in the Zig core, consumed strictly through
 * the C FFI (include/cols.h) — this file deliberately cannot see Zig.
 *
 * Copyright (c) 2026 Peter Marreck. MIT License.
 */
#define _POSIX_C_SOURCE 200809L /* fileno, read under -std=c11 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include "cols.h"

#ifdef _WIN32
#include <io.h>
#include <fcntl.h>
#define cols_fileno _fileno
#else
#include <unistd.h>
#define cols_fileno fileno
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
		"space. Positions a line can't supply render as the null glyph ∅ (see\n"
		"Missing data below; --clamp restores the classic empty-line behavior).\n"
		"Files may follow the specs; default input is stdin ('-' or '@stdin').\n"
		"\n"
		"Specs (combinable, space- or comma-separated; negatives count from\n"
		"the last column: -1 = last, so ranges repeat the hyphen):\n"
		"  n             single column n\n"
		"  m-n           columns m through n\n"
		"  m-            column m through end of line\n"
		"  -2            second-to-last column\n"
		"  2--1          columns 2 through the last\n"
		"  -3--2, -2-    from-the-end ranges\n"
		"  x,y,z         comma-joined list of any of the above\n"
		"\n"
		"Character mode:\n"
		"  -c, --chars   specs select CHARACTERS (Unicode code points — unlike\n"
		"                cut's byte-based -c); selections concatenate. Attached\n"
		"                form -c2-5 works (cut muscle memory). Not combinable\n"
		"                with separator flags.\n"
		"\n"
		"Separator selection (highest precedence first; later flags win):\n"
		"  -e, --regex <pat>   PCRE2 regex separator (UTF-8)\n"
		"  -F <sep>            awk-style: ' ' = default whitespace mode;\n"
		"                      one char = literal; multi-char = PCRE2 regex;\n"
		"                      '' = every character is a field (awk FS=\"\")\n"
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
		"  --ndjson              newline-delimited JSON: one bare array per line,\n"
		"                        no wrapper — streams; pairs well with -l and jq\n"
		"\n"
		"Missing data (explicitly requested columns a line doesn't have):\n"
		"  Single columns and closed ranges PROMISE positions; a missing one\n"
		"  renders as the null glyph ∅ so faulty input is visible immediately.\n"
		"  Open ranges (m-, -2-) and mixed-sign ranges (2--1) are elastic and\n"
		"  never render nulls. In --json, missing positions are JSON null.\n"
		"  --null-value <s>      use <s> instead of ∅ ('' hides missing slots)\n"
		"  --clamp               old behavior: shrink to what exists, no nulls\n"
		"  --strict              missing data = error: exit 3 with a one-line\n"
		"                        diagnostic (input name, line number, columns);\n"
		"                        --no-strict negates an earlier --strict\n"
		"  -s, --only-delimited  skip lines with no separator at all (cut -s);\n"
		"                        such lines are never --strict violations\n"
		"  (-c character mode always clamps; nulls/-s/--strict do not apply)\n"
		"  (line correspondence assumes newline-free separators and glyphs;\n"
		"   -O $'\\n' deliberately emits one field per line)\n"
		"\n"
		"Options:\n"
		"  -h, --help, /h, /?    show this help\n"
		"  --about               one-line description with version and platform\n"
		"  -V, --version         print the version\n"
		"  -l, --line-buffered   flush output after each input burst\n"
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
		"Exit codes: 0 success · 1 I/O error · 2 usage/spec error · 3 validation (--strict)\n");
}

static void usage_hint(void) {
	fprintf(stderr, "Usage: <command> | %s <n | m-n | m- | comma,list> [more specs...]\n", PROG);
	fprintf(stderr, "Try '%s --help' for details.\n", PROG);
}

/* Spec-shaped: an optional leading '-' (negative index), then a digit, then
 * only [0-9,-]. Such args are always treated as column specs (a file named
 * "3-2" or "-1" needs a ./ prefix). */
static int is_spec_shaped(const char *s) {
	if (*s == '-') s++;
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

/* Value of a --long option in either "--name value" or "--name=value" form,
 * or NULL if a is not this option. *err is set when the value is missing
 * (message already printed). One helper instead of four hand-computed
 * offset triples that had to agree with their string literals. */
static const char *long_opt_value(const char *a, const char *name,
                                  int argc, char **argv, int *i, int *err) {
	size_t n = strlen(name);
	if (strncmp(a, name, n) != 0) return NULL;
	if (a[n] == '=') return a + n + 1;
	if (a[n] != '\0') return NULL; /* e.g. --langx */
	if (*i + 1 < argc) return argv[++*i];
	fprintf(stderr, "%s: option '%s' requires a value\n", PROG, name);
	*err = 1;
	return NULL;
}

/* --- streaming ----------------------------------------------------------- */

static char *g_buf = NULL;
static size_t g_cap = 0;
static size_t g_fill = 0;
static int g_line_buffered = 0; /* -l: flush stdout after each processed burst */

/* Returns: 0 ok, -1 I/O or OOM failure, -2 strict-validation failure,
 * -3 regex match failure. For -2/-3: partial clean output is written, JSON
 * output is closed (so it stays parseable), and the diagnostic is printed
 * prefixed with the current input's name. */
static int emit(cols_ctx *ctx, const char *name, const char *data, size_t len) {
	const char *out;
	size_t out_len;
	int rc = cols_process(ctx, data, len, &out, &out_len);
	if (rc == -2 || rc == -3) {
		/* clean lines before the violation still count — write them, then
		 * close any JSON array so downstream parsers see valid output */
		int werr = 0;
		if (out_len > 0 && fwrite(out, 1, out_len, stdout) != out_len) werr = 1;
		const char *tail;
		size_t tail_len;
		if (cols_finish(ctx, &tail, &tail_len) == 0 && tail_len > 0) {
			if (fwrite(tail, 1, tail_len, stdout) != tail_len) werr = 1;
		}
		if (fflush(stdout) != 0) werr = 1;
		if (werr) fprintf(stderr, "%s: write error: %s\n", PROG, strerror(errno));
		fprintf(stderr, "%s: %s: %s\n", PROG, name, cols_strict_error(ctx));
		return rc;
	}
	if (rc != 0) {
		fprintf(stderr, "%s: out of memory\n", PROG);
		return -1;
	}
	if (out_len > 0 && fwrite(out, 1, out_len, stdout) != out_len) {
		fprintf(stderr, "%s: write error: %s\n", PROG, strerror(errno));
		return -1;
	}
	if (g_line_buffered) fflush(stdout);
	return 0;
}

/* One underlying read(2)/_read: unlike fread (which loops until the full
 * count arrives), this returns as soon as ANY data is available — so a slow
 * pipe producer streams through cols line-by-line instead of stalling until
 * a 256KB buffer fills. EINTR is retried. */
static long read_some(int fd, char *buf, size_t cap) {
	/* cap each syscall at 1GB on every platform: Windows _read takes an
	 * unsigned int, and macOS read() rejects counts > INT_MAX (a >2GB
	 * single line would otherwise turn into a spurious "read error") */
	size_t n_req = cap > (1u << 30) ? (1u << 30) : cap;
	for (;;) {
#ifdef _WIN32
		int n = _read(fd, buf, (unsigned)n_req);
#else
		ssize_t n = read(fd, buf, n_req);
#endif
		if (n >= 0) return (long)n;
		if (errno != EINTR) return -1;
	}
}

/* Stream one input through the ctx. Lines are cut at the last newline of
 * each read; the partial tail carries over (the buffer grows for lines
 * longer than it — no line-length limit). EOF flushes the unterminated
 * final line, so per-file line boundaries behave like awk/cut.
 * Returns 0 ok, -1 I/O failure, -2 strict failure, -3 regex failure. */
static int stream_file(cols_ctx *ctx, FILE *f, const char *name) {
	int fd = cols_fileno(f);
	cols_new_input(ctx); /* diagnostics say "line N" of THIS input */
	for (;;) {
		if (g_fill == g_cap) {
			g_cap = g_cap ? g_cap * 2 : CHUNK_INITIAL;
			g_buf = xrealloc(g_buf, g_cap);
		}
		long n = read_some(fd, g_buf + g_fill, g_cap - g_fill);
		if (n < 0) {
			fprintf(stderr, "%s: read error on '%s': %s\n", PROG, name, strerror(errno));
			return -1;
		}
		if (n == 0) break; /* EOF */
		size_t scan_end = g_fill + (size_t)n; /* only new bytes can hold a newline */
		size_t nl_end = 0;
		for (size_t i = scan_end; i > g_fill; i--) {
			if (g_buf[i - 1] == '\n') {
				nl_end = i;
				break;
			}
		}
		g_fill = scan_end;
		if (nl_end > 0) {
			int rc = emit(ctx, name, g_buf, nl_end);
			if (rc != 0) return rc;
			memmove(g_buf, g_buf + nl_end, g_fill - nl_end);
			g_fill -= nl_end;
		}
	}
	if (g_fill > 0) { /* unterminated final line of THIS input */
		int rc = emit(ctx, name, g_buf, g_fill);
		if (rc != 0) return rc;
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
	int chars_flag = 0;                /* -c / --chars: select characters, not fields */
	const char *out_sep = NULL;
	int out_sep_set = 0;
	int json = 0;
	int ndjson = 0;
	const char *null_value = NULL;     /* --null-value; NULL = core default "∅" */
	int null_value_set = 0;
	int strict = 0;
	int clamp = 0;
	int only_delimited = 0;
	const char *lang_flag = NULL;
	int after_dd = 0;

	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];

		if (!after_dd && a[0] == '-' && a[1] != '\0') {
			const char *val = NULL;

			/* "-1", "-2-", "-3--1": a negative column spec, not a flag */
			if (a[1] >= '0' && a[1] <= '9') {
				specs[nspecs++] = a;
				continue;
			}
			if (strcmp(a, "--") == 0) {
				after_dd = 1;
				continue;
			}
			/* -c / -cLIST / --chars: character mode (bare, or with an
			 * attached cut-style spec list) */
			if (a[1] == 'c' && (a[2] == '\0' || is_spec_shaped(a + 2))) {
				// attached form must look like a spec, or "-color" would be
				// eaten as chars-mode + a spec error naming 'olor'
				chars_flag = 1;
				if (a[2] != '\0') specs[nspecs++] = a + 2;
				continue;
			}
			if (strcmp(a, "--chars") == 0) {
				chars_flag = 1;
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
				ndjson = 0; /* sibling output formats: later flag wins */
				continue;
			}
			if (strcmp(a, "--ndjson") == 0) {
				ndjson = 1;
				json = 0;
				continue;
			}
			if (strcmp(a, "-l") == 0 || strcmp(a, "--line-buffered") == 0) {
				g_line_buffered = 1;
				continue;
			}
			if (strcmp(a, "-s") == 0 || strcmp(a, "--only-delimited") == 0) {
				only_delimited = 1;
				continue;
			}
			if (strcmp(a, "--strict") == 0) {
				strict = 1;
				continue;
			}
			if (strcmp(a, "--no-strict") == 0) {
				strict = 0;
				continue;
			}
			if (strcmp(a, "--clamp") == 0) {
				clamp = 1;
				continue;
			}
			int opt_err = 0;
			if ((val = long_opt_value(a, "--null-value", argc, argv, &i, &opt_err)) != NULL) {
				null_value = val;
				null_value_set = 1;
				continue;
			}
			if (opt_err) return 2;

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
						if (val[0] == '\0') {
							sep_mode = COLS_SEP_CHARS; /* awk: FS="" splits per character */
							sep_val = "";
						} else if (strcmp(val, " ") == 0) {
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
			if ((val = long_opt_value(a, "--regex", argc, argv, &i, &opt_err)) != NULL) {
				sep_flag_set = 1;
				sep_mode = COLS_SEP_REGEX;
				sep_val = val;
				continue;
			}
			if (opt_err) return 2;
			if ((val = long_opt_value(a, "--output-sep", argc, argv, &i, &opt_err)) != NULL) {
				out_sep = val;
				out_sep_set = 1;
				continue;
			}
			if (opt_err) return 2;
			if ((val = long_opt_value(a, "--lang", argc, argv, &i, &opt_err)) != NULL) {
				lang_flag = val;
				continue;
			}
			if (opt_err) return 2;

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

	/* Deterministic buffering across libcs: musl line-buffers stdout even
	 * into pipes (glibc block-buffers), so pin the cut/gawk-parity default
	 * explicitly; -l keeps stdio defaults and flushes per burst instead. */
	if (!g_line_buffered) {
#ifdef _WIN32
		int tty = _isatty(_fileno(stdout));
#else
		int tty = isatty(cols_fileno(stdout));
#endif
		if (!tty) setvbuf(stdout, NULL, _IOFBF, 1 << 16);
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

	if (clamp && strict) {
		fprintf(stderr, "%s: --clamp and --strict are mutually exclusive (clamp shrinks missing selections; strict errors on them)\n", PROG);
		return 2;
	}

	/* -c selects characters — a separator makes no sense alongside it */
	if (chars_flag) {
		if (sep_flag_set) {
			fprintf(stderr, "%s: -c/--chars selects characters; it cannot be combined with -d/-t/-e/-F\n", PROG);
			return 2;
		}
		sep_flag_set = 1; /* character mode also overrides IFS/COLS_IFS */
		sep_mode = COLS_SEP_CHARS;
		sep_val = "";
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
		.null_value = null_value_set ? null_value : NULL,
		.null_value_len = null_value_set ? strlen(null_value) : 0,
		.clamp = clamp,
		.strict = strict,
		.only_delimited = only_delimited,
		.ndjson = ndjson,
	};

	char errbuf[512];
	cols_ctx *ctx = cols_create(specs, nspecs, &cfg, errbuf, sizeof errbuf);
	if (!ctx) {
		fprintf(stderr, "%s: %s\n", PROG, errbuf);
		return 2;
	}

	/* stream_file: 0 ok, -1 I/O (exit 1), -2 strict validation (exit 3) */
	int rc = 0;
	if (nfiles == 0) {
		int src = stream_file(ctx, stdin, "(stdin)");
		if (src != 0) rc = (src == -2) ? 3 : 1;
	} else {
		for (size_t i = 0; i < nfiles && rc == 0; i++) {
			const char *path = files[i];
			if (strcmp(path, "-") == 0 || strcmp(path, "@stdin") == 0) {
				int src = stream_file(ctx, stdin, "(stdin)");
				if (src != 0) rc = (src == -2) ? 3 : 1;
				continue;
			}
			FILE *f = fopen(path, "rb");
			if (!f) {
				fprintf(stderr, "%s: cannot open '%s': %s\n", PROG, path, strerror(errno));
				rc = 1;
				break;
			}
			int src = stream_file(ctx, f, path);
			if (src != 0) rc = (src == -2) ? 3 : 1;
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
