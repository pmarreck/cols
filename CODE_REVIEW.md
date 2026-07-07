---
purpose: Deep-code-review findings (2026-07-07) with disposition tracking
audience: both
maintained_by: agent
---

# Code Review — cols
**Date:** 2026-07-07
**Reviewer:** Claude (deep-code-review skill; 6 grouped review agents run 2-at-a-time, findings independently verified against the built 0.2.0 binary, incl. a 300-case stream-vs-general differential fuzz and a 200-case clamp-vs-null-suppression fuzz)
**Scope:** Full codebase audit (11 dimensions + adversarial semantics hunt)

## Summary
- **CRITICAL:** 2 (both fixed in this pass)
- **WARN:** 13 (11 fixed, 2 accepted-with-documentation)
- **INFO:** 20 (12 fixed, 8 deferred/accepted)

Dispositions: ✅ fixed in the post-review commit · 📝 documented instead of changed · ⏳ deferred (backlog below) · 🤝 accepted as-is.

## Critical Issues

### ✅ src/process.zig:437 — `-s` drops fully DELIMITED lines whenever the largest requested column is 1
**Dimension:** Inconsistent functionality / test coverage (found independently by 4 of 6 agents; the stream-vs-general differential fuzz isolated it)
The only-delimited check `nf < 2` reads the **max_fields-capped** field count: for spec `1`, splitters early-exit after one field, so every line — delimited or not — reports nf==1 and is skipped. `printf 'a b\n' | cols -s 1` printed nothing; `cols -d, --json -s 1 file.csv` dropped every row; `-s --strict 1` silently defused strict. The single-byte-literal stream path answers the same question via memchr and was CORRECT, so identical invocations diverged by internal path. Fix: when `only_delimited`, raise the cap to witness delimitedness (`max_fields = @max(max_fields, 2)`), plus regression tests for ws/regex/IFS/multichar/json/strict variants and a mechanical stream-vs-general differential test that would have caught it.

### ✅ src/pcre2.zig:81 — PCRE2 match-time errors swallowed as "no match" → silently wrong columns, exit 0
**Dimension:** Error handling / FFI
`matchAt` collapsed every negative rc — including MATCHLIMIT/DEPTHLIMIT/JIT_STACKLIMIT — into null; `splitRegex` then treats the rest of the line as one field. Reproduced: `cols -e '(a+)+b' 2` on a backtracking-hostile line silently merges fields and exits 0 (the same pattern splits correctly on benign input). Nested-quantifier patterns are common user error; wrong output with exit 0 is the worst failure mode for a tool whose motto is "missing data is visible." Fix: distinguish `PCRE2_ERROR_NOMATCH`; surface other errors as `RegexMatchFailed` → FFI `-3` + `cols_strict_error()` diagnostic (line number + PCRE2 message) → CLI exit 1.

## Warnings

### ✅ src/cols_cli.c:48 — `--help` intro still claims missing columns "print as empty lines" (pre-0.2.0 clamp semantics)
**Dimension:** Incomplete functionality — contradicted the help's own "Missing data" section 40 lines later. Reworded.

### ✅ src/cols_cli.c (emit -2 path) — `--strict --json` emitted syntactically invalid JSON (`[["b"]`, unclosed)
**Dimension:** Inconsistent functionality — the CLI now calls `cols_finish` on the -2 path, so strict failures yield a *valid* JSON array of the clean rows + exit 3.

### ✅ src/process.zig:392-416 — truncated `--strict` diagnostics could name a PHANTOM column (`..., 90, 9` = truncated `91`)
**Dimension:** Error handling — message now lists at most 8 missing columns then `… (+N more)`; buffer sized so a number can never be cut mid-digits.

### ✅ src/process.zig line_no + src/cols_cli.c — multi-file `--strict` reported a cumulative line number with no file name (`viol1:1` reported as "line 4")
**Dimension:** Error handling (3 agents) — new `cols_new_input()` FFI export resets the counter per input; the CLI prefixes the input name: `cols: viol1: line 1: missing column(s) 2` (grep/awk FNR convention). Pinned by a multi-file CLI test.

### ✅ src/process.zig:479-493 — `--null-value ''` spun the full promised extent per line doing zero work (`1-16777216` × 2M lines ≈ hours for output identical to instant `--clamp`)
**Dimension:** Algorithmic complexity — text-mode promised rendering now routes through the clamped path when the glyph is empty (byte-identical output, verified by the existing 200-case fuzz class).

### ✅ src/process.zig:334-339 — usize multiply overflow in the stream path's capacity math → `appendSliceAssumeCapacity` heap corruption (FFI-reachable only; CLI blocked by ARG_MAX arithmetic)
**Dimension:** Memory safety — per-line worst case now computed once at create with checked math; on overflow the Processor simply clears `stream_literal` (the general path can only OOM, never corrupt).

### ✅ src/cols_cli.c:184-194 — POSIX `read()` passed an uncapped count; >2GB single line → EINVAL on macOS ("no line-length limits" broken)
**Dimension:** Language features / portability — the 1GB per-call cap now applies on both branches.

### ✅ tests/cli/cols_cli_test (4 sites) — `wc` output compared as strings; BSD wc pads with spaces → 4 false failures on macOS direct runs
**Dimension:** Test quality — numeric comparisons now.

### ✅ bm:57 + suite timeout — `sha256sum` (machine-id!) and `timeout` are GNU-only; a brew-tooled Mac gets a silently wrong `bench/.ndjson` identity
**Dimension:** Portability — `shasum -a 256` fallback in bm; the suite resolves `timeout`/`gtimeout` and skips the two buffering tests loudly when neither exists.

### ✅ src/ffi.zig:244 — FFI debug-flag test was a tautology (expected value = the implementation expression recomputed)
**Dimension:** Futile test coverage — replaced with a range assertion + pointer to bm's real banner gate.

### ✅ src/process.zig tests — no mechanical stream-vs-general differential; the two emitters are separate implementations of one contract pinned only by hand-picked examples
**Dimension:** Test coverage (this gap concealed the `-s` CRITICAL) — added an in-module differential: every stream-eligible config × an edge corpus is run through both engines (second Processor has `stream_literal` forced off) and must match byte-for-byte.

### 📝 README/--help — newline-bearing `-O`/`-d`/`--null-value`/`IFS=$'\n'` joins break the "one output line per input line" promise
**Dimension:** Documentation — deliberate: `-O $'\n'` (field-per-line) is a legitimate idiom with `cut --output-delimiter` precedent, so values are not rejected; README/help now scope the promise ("with newline-free separators/glyphs").

### 📝 tests/cli/cols_cli_test:661-677 — `-l` buffering tests are timing hacks (sleep/timeout)
**Dimension:** Test quality — the orchestrator's spec mandated this exact harness shape; margins widened (the no-`-l` direction only gets *stronger* under load). Accepted with this note.

## Informational (fixed)
- ✅ spec.zig parseAtom order: `0x10` misreported as "0 is not a column" — zero check now follows grammar validation.
- ✅ cols_cli.c `-c` attach: `-color` misreported as `invalid column spec 'olor'` — attached value must be spec-shaped, else "unknown option '-color'".
- ✅ process.zig: promised-range resolution deduplicated (`resolvePromised` helper used by checkStrict + both emit arms; C1 proved multi-copy semantics drift).
- ✅ cols_cli.c: four hand-offset `--long[=]value` parsers → one `long_opt_value()` helper (magic offsets gone).
- ✅ cols.h: NULL contracts, `cols_finish` return code, post-`-2` "destroy the ctx" protocol, and the new `-3` code documented.
- ✅ process.zig create: clamp+strict now rejected at the CORE too (FFI callers previously got strict silently disabled).
- ✅ "0 is not a column" and FFI "invalid separator mode" now echo the offending input.
- ✅ --no-strict documented in --help; README's flag list mentions it.
- ✅ emit() -2 path: fwrite/fflush results checked (write failure reported alongside the strict diagnostic).
- ✅ create() error-path cleanup: `errdefer` + 4 manual `atoms.deinit` calls collapsed to one `defer` (leak-free before, hazard-free now).
- ✅ New pinning tests: `-F` single multibyte code point; `-F ''` inherits chars-mode strict exemption; `--null-value=` equals-empty form; truncated-multibyte JSON tail; mixed multibyte+whitespace IFS member; FFI errbuf truncation at tiny caps; stale "blank lines" test renamed/merged.
- ✅ tests: `assert_eq` now also asserts rc==0 (every use is a success-path expectation); run helpers scrub COLS_LANG.
- ✅ scanNum stale doc comment; 32-bit-unsafe `@intCast` → `std.math.cast`; orphan `zig-pkg/` trashed.

## Informational (deferred / accepted)
- ⏳ emitLine json/text arms are structurally parallel ~30-line blocks — a slot-iterator refactor is the "bold" option; offered post-ship. (Safe option — the `resolvePromised` dedup — was taken.)
- ⏳ IfsSet.matchNonWs: dedupe members + first-byte bitmap prefilter (adversarially large IFS only; declared O(n·m) is honest).
- ⏳ OOM-injection sweep (`checkAllAllocationFailures`) over Processor.create; FFI wrapper allocs only exercised under leak-blind c_allocator today.
- ⏳ appendJsonString if/else chain → switch (jump table); splitDefaultWs vs tokenizeAny — both cosmetic, current code verified correct.
- 🤝 CLI early-exit `return 2` paths don't free specs/files — process exit reclaims; freeing on ~10 error paths adds noise for valgrind purity only.
- 🤝 cols_create OOM exits 2 rather than 1 (indistinguishable from usage error at the exit-code level) — documented in cols.h as "create failure = exit-2 territory".
- 🤝 First unopenable file aborts remaining files (cut continues) — deliberate fail-fast; README documents input handling.
- 🤝 `-e ''` gets the shell empty-separator rule (whole-line), not a regex interpretation — README's flavor taxonomy now names it explicitly.
- ✅ (superseded 2026-07-07 PM) Extent guard removed entirely: the one-null-per-range refinement makes output bounded by construction (fields present + one null per promised range), so huge ranges are safe without any refusal. The checked capacity math remains as defense-in-depth.

## Verified-clean attestations (from the review agents, evidence in their reports)
Every `// complexity:` claim honest (8/8, incl. splitRegex forced-progress proof); create() error-path frees exactly-once on all 11 paths (full path×resource table); CLI newline back-scan invariant proven by induction; specs/files arrays cannot overflow argc; cols_strict_error NUL bounds safe at len==192; CConfig↔cols_config ABI layout identical field-by-field; exactly 8 exported symbols; errno discipline correct at all 5 strerror sites; happy path allocation-free after warmup; NUL bytes and invalid UTF-8 pass through text mode intact; ownership fully duped across the FFI; dead-code sweep clean.
