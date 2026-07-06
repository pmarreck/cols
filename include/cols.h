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
} cols_config;

/* Parse column specs (NUL-terminated strings: "2", "4-6", "1,3-", ...) and
 * build a context. Returns NULL on usage-level failure with a NUL-terminated
 * message in errbuf (exit-code-2 territory for a CLI). */
cols_ctx *cols_create(const char *const *specs, size_t nspecs,
                      const cols_config *cfg,
                      char *errbuf, size_t errbuf_cap);

/* Feed a chunk containing only COMPLETE lines (the final line of an input may
 * lack its trailing newline — flush it at EOF). On success (0), *out/*out_len
 * point to this chunk's output, valid until the next call on this ctx.
 * Returns -1 on internal failure (out of memory). */
int cols_process(cols_ctx *ctx, const char *data, size_t len,
                 const char **out, size_t *out_len);

/* Emit any trailing output (JSON close bracket; empty in text mode). */
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
