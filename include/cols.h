/* cols.h — C API for libcols, the column-extraction core.
 *
 * This header is the tool's real public interface: the cols CLI itself
 * consumes it (dogfooding), and so can any other C-ABI consumer.
 * Keep in lockstep with src/ffi.zig.
 *
 * Copyright (c) 2026 Peter Marreck. MIT License.
 */
#ifndef COLS_H
#define COLS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque processing context. */
typedef struct cols_ctx cols_ctx;

/* Separator mode, resolved by the caller (flag/env precedence is CLI policy,
 * not core policy). Values must match process.SepMode in the Zig core. */
typedef enum {
	COLS_SEP_DEFAULT = 0, /* awk default: runs of spaces/tabs, edges skipped  */
	COLS_SEP_LITERAL = 1, /* whole string is one delimiter (cut semantics)    */
	COLS_SEP_IFS     = 2, /* POSIX shell word-splitting over a character set  */
	COLS_SEP_REGEX   = 3, /* PCRE2 pattern (UTF-8 mode)                       */
	COLS_SEP_NONE    = 4, /* no splitting: whole line is field 1              */
	COLS_SEP_CHARS   = 5  /* every code point is a field (-c / -F ''), NOT bytes */
} cols_sep_mode;

typedef struct {
	int sep_mode;          /* a cols_sep_mode value                          */
	const char *sep;       /* separator/pattern bytes (may be NULL if len 0) */
	size_t sep_len;
	const char *out_sep;   /* output joiner; NULL = derive per mode rules    */
	size_t out_sep_len;
	int json;              /* nonzero: emit JSON array-of-arrays             */
	const char *null_value; /* glyph for missing promised columns.
	                         * NULL = default U+2205 "∅"; non-NULL empty
	                         * suppresses the slot (pre-null behavior).      */
	size_t null_value_len;
	int clamp;             /* nonzero: old clamping semantics, no nulls      */
	int strict;            /* nonzero: missing promised data = failure (-2)  */
	int only_delimited;    /* nonzero: skip lines with < 2 fields (cut -s)   */
} cols_config;

/* NULL contract: every pointer argument in this API must be non-NULL, with
 * two exceptions — errbuf (NULL/cap 0 discards the message) and the cfg
 * string fields documented as nullable above. Passing NULL elsewhere is
 * undefined behavior, per C convention. */

/* Parse column specs (NUL-terminated strings: "2", "4-6", "1,3-", ...) and
 * build a context. Returns NULL on failure with a NUL-terminated message in
 * errbuf — usage-level errors and out-of-memory alike (exit-code-2 territory
 * for a CLI; the message text distinguishes them). */
cols_ctx *cols_create(const char *const *specs, size_t nspecs,
                      const cols_config *cfg,
                      char *errbuf, size_t errbuf_cap);

/* Feed a chunk containing only COMPLETE lines (the final line of an input may
 * lack its trailing newline — flush it at EOF). On success (0), *out / *out_len
 * point to this chunk's output, valid until the next call on this ctx.
 * Returns -1 on internal failure (out of memory).
 * Returns -2 on a strict-mode validation failure, -3 on a regex match-time
 * failure (e.g. catastrophic backtracking exhausting PCRE2's limits): for
 * both, *out / *out_len carry the output of the clean lines BEFORE the
 * offending one and cols_strict_error() returns the diagnostic. After -2/-3
 * the ctx has no resumption protocol — destroy it. */
int cols_process(cols_ctx *ctx, const char *data, size_t len,
                 const char **out, size_t *out_len);

/* Diagnostic for the last -2/-3 from cols_process (e.g. "line 3: missing
 * column(s) 4, 5"). Valid until the next cols_process call. */
const char *cols_strict_error(cols_ctx *ctx);

/* Reset diagnostic line numbering at an input (file) boundary, so "line N"
 * means line N of the CURRENT input (grep/awk-FNR convention). */
void cols_new_input(cols_ctx *ctx);

/* Emit any trailing output (JSON close bracket; empty in text mode).
 * Returns 0, or -1 on out-of-memory (never -2/-3). Safe to call after a
 * failed cols_process to close JSON output before destroying the ctx. */
int cols_finish(cols_ctx *ctx, const char **out, size_t *out_len);

void cols_destroy(cols_ctx *ctx);

/* Version string, e.g. "0.1.0". */
const char *cols_version(void);

/* One-line description + version + platform-arch, for --about. */
const char *cols_about(void);

/* Nonzero when the core was compiled in Debug mode (CLI prints its banner). */
int cols_is_debug_build(void);

#ifdef __cplusplus
}
#endif

#endif /* COLS_H */
