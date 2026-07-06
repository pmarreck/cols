# Kickoff: cols — native Zig column extractor (from orchestrator / thelio-pm)

**Date:** 2026-07-06 · **From:** orchestrator session (`$HOME`) · **Type:** LLMsend kickoff

## Purpose & intent

Peter wants a fast, native, cross-platform `cols`: extract columns from
line-oriented text by number, "in true unix fashion — extremely fast, do one
thing exceedingly well." This graduates today's Bash prototype
(`prior_art/bash_cols`, 30 tests) into a Zig-core/C-FFI/C-CLI tool published
publicly at github.com/pmarreck/cols (MIT — LICENSE already present). He
expects to use it daily and share it.

## Origin story / rationale (put this in the README — it's the differentiator)

Built today because `col` and `column` are unmemorable misnomers (nroff filter;
table FORMATTER) and nobody should have to remember `awk '{print $2}'`. The
Bash prototype hit a wall: **POSIX shells scrub inherited IFS at startup** (the
1980s `IFS=/` PATH-hijack fix), so `IFS=: cols ...` can never reach a shell
script — its own interpreter destroys the value before line 1. It had to fall
back to a `COLS_IFS` env var. A compiled binary receives `IFS` fine, so the
native `cols` finally honors the natural idiom: `IFS=: cols 1,7 < /etc/passwd`.
The prototype's suite even has a test asserting raw IFS *doesn't* work in bash —
your suite must assert the inverse.

## Prior art (READ FIRST)

- `prior_art/bash_cols` — the working prototype. Its behavior is the spec of
  record for: spec grammar (n, m-n, m-, comma-combinable, space-combinable),
  1-indexing, 0-rejection, reversed-range rejection (exit 2 + stderr), range
  clamping, line correspondence (missing fields ⇒ empty output line, never a
  dropped line), default whitespace splitting (runs collapse, leading skipped),
  empty-separator = whole-line-as-one-field, exit codes, clean stderr on success.
- `prior_art/bash_cols_test` — 30 cases. Port ALL of them to the CLI suite
  (adjusting the IFS negative test to positive, and `COLS_IFS=. ` regex-metachar
  literalness per the new flag semantics below).
- `~/Code/dirtree` — consumes PCRE2 from Peter's fork; copy its incantation:
  - `build.zig.zon`:
    ```zig
    .pcre2 = .{
        .url = "https://github.com/pmarreck/pcre2/archive/refs/tags/zig-0.16.0.tar.gz",
        .hash = "pcre2-10.47.0-S7QTbvnVMgDsA1ipkKNj5kVoEda9wcIuZYUpdrTuDaCh",
    },
    ```
  - `build.zig`: `b.dependency("pcre2", ...)` → `artifact("pcre2-8")` →
    `addIncludePath(pcre2_lib.getEmittedIncludeTree())` + `linkLibrary(pcre2_lib)`
    (see dirtree's build.zig:35-79, also applied to unit tests).
- The 2026-07-06 orchestrator session transcript distilled: bash sanitization
  verified empirically (`IFS=: bash -c 'printenv IFS'` prints the default).

## Architecture (fleet standard — physics over policy)

```
C CLI (all I/O) ──► C FFI (cols.h) ──► Zig core (pure, no I/O, no clock, no getenv)
                                            └── PCRE2-8 statically linked
```

- Zig core: pure functions over slices — spec parsing, splitting, selection,
  joining. Env-var *reading* happens in the C CLI; the core receives resolved
  config as parameters (hexagonal DI; makes everything unit-testable).
- The C CLI must consume the FFI header, never the Zig module (dogfooding).
- Zig 0.16 — read `ZIG_RECENT_API_CHANGES.md` (symlinked in root) BEFORE writing
  Zig; 0.12-0.15 idioms will burn you.

## CLI surface (spec)

Positional specs, exactly as prior art: `n`, `m-n`, `m-`; comma- and
space-combinable; later args accumulate. Input: stdin by default; also accept
file path arguments plus `-`/`@stdin` (paths with spaces must work and be
tested). Output: stdout; metadata/errors: stderr.

**Separator selection — precedence (highest wins), later flags override earlier:**
1. Flags:
   - `-e <regex>` / `--regex <regex>`: PCRE2 regex separator (grep/rg `-e`
     muscle memory). UTF-8 mode.
   - `-F <sep>`: awk muscle memory — `' '` (single space) = default whitespace
     mode; any other single char = literal; multi-char = PCRE2 regex (awk
     treats multi-char FS as ERE; we upgrade to PCRE2).
   - `-d <sep>` / `-t <sep>`: literal string separator, whole string, even
     multi-char (cut/sort muscle memory; superset of cut's single-char rule).
     Adjacent separators delimit empty fields (cut semantics).
2. `COLS_IFS` env var (tool-specific override, kept for bash-prototype compat).
3. `IFS` env var — THE headline feature.
4. Default: runs of spaces/tabs, leading whitespace skipped (awk default).

**IFS/COLS_IFS semantics — true shell word-splitting rules, not naive char-split:**
- Whitespace members of the set: runs collapse, leading/trailing stripped.
- Non-whitespace members: strict delimiters; adjacent ⇒ empty field.
- Mixed (e.g. `IFS=': '`): shell rules (space runs around a colon collapse
  into one split).
- Set-but-empty ⇒ no splitting: whole line is field 1.
- **Critical consequence:** a bash parent that scrubbed-and-re-exported
  `IFS=$' \t\n'` yields behavior identical to default mode — stray inherited
  IFS is harmless by construction. This resolves the "spooky action" objection
  to a binary honoring IFS. Test this case explicitly (export IFS=$' \t\n';
  expect default behavior bit-for-bit).

**Output joining:** default single space. If the separator is a literal
(`-d`/`-t`/single-char `-F`), rejoin with that literal; IFS-style set: rejoin
with its first character (shell `"$*"` convention, per prototype). Regex
separator: single space. `-O <str>` / `--output-sep <str>` overrides all
(awk OFS analog).

**Standard surface (per fleet CLI conventions):**
- `-h`/`--help`; `--about` = ONE line: description, version, platform+arch;
  `--version`.
- `--json`: output as JSON array-of-arrays (one inner array per line, selected
  fields as strings). UTF-8 validated.
- Windows-style aliases (`/h`, `/?`) where they don't collide; `--` ends flags.
- Errors: exit 2 for usage/spec errors with a one-line stderr message; 0 on
  success; 1 for I/O failures. 100% UTF-8 clean I/O.
- i18n: groundwork ONLY (prepare phase per the i18n skill): `--lang`,
  `COLS_LANG` > `LANG` precedence, English default, no translations yet.

## Performance ethos

- Competitive with `cut`, beat `gawk`/`mawk` for the default-whitespace and
  literal cases on multi-MB streams. memchr-style scanning; avoid per-byte
  branching where a word-at-a-time scan works (see z7z's u64 XOR+ctz trick).
- Buffered I/O; no line-length limits (grow, don't truncate).
- ReleaseFast default in build.zig (`b.option(OptimizeMode, ...) orelse .ReleaseFast`).
- Debug builds print yellow "DEBUG BUILD" to stderr (suppressible via
  MUTE_DEBUG_STATUS); ./bm must assert its absence AND non-suppression.
- `./bm`: hyperfine (`-N --warmup 3`, fixed generated corpus) vs `cut`, `gawk`,
  and busybox awk if present; ndjson log per fleet conventions (first-line
  `_meta` header, `bench/<machine-id>.ndjson`, two-sided tolerance, new machine
  seeds baseline and passes). Post-MVP: scaling-ratio gate (N, 2N, 4N, 8N —
  declared `// complexity: O(n)` on hot fns).

## Testing (TDD, MFIC-aware)

- Port the 30 prior-art CLI cases FIRST as failing tests, then implement.
  They are the acceptance floor, not the ceiling.
- New coverage: every flag; flag-vs-env precedence (each adjacent pair in the
  chain); `IFS=: cols 1,7` WORKS (the punchline); scrubbed-default-IFS ≡
  default mode; PCRE2 separators (multi-space `\s+`, lookarounds someday —
  keep MVP to real patterns); `--json` (validate with jq in CLI tests);
  UTF-8 fields (emoji, CJK); CRLF input (strip `\r` — Windows target!); huge
  lines; file args incl. spaces in paths; `--` sentinel; stdin via `-` and
  `@stdin`.
- Zig unit tests on the pure core (spec parser and each splitter — table-driven).
- Test scripts: bash, `set -u` only (NEVER `set -e`/pipefail in test scripts —
  error paths are legitimate outputs); source `~/dotfiles/bin/src/capture.bash`
  for stdout/stderr/rc capture; tests run clean (no stray stderr).
- **PATH-SHADOW GOTCHA (critical):** a bash `cols` already exists at
  `~/dotfiles/bin/cols` and IS on PATH. CLI tests MUST invoke the built binary
  by explicit path (`./zig-out/bin/cols` or `$COLS_BIN`), never bare `cols`,
  or you'll green-light the prototype. Add a guard assertion that the binary
  under test is the one just built (e.g. `--about` mentions platform/Zig).
  Do NOT modify ~/dotfiles — the prototype's retirement is Peter's call later.

## Nix / CI / publishing

- `flake.nix` with mitchellh/zig-overlay (fleet standard, exact Zig version);
  Strategy-1 fixed-output zigDeps derivation (`zig build --fetch=all`) for the
  pcre2 dep; `packages.default` + `checks.{build,test}` so Garnix (org-wide)
  picks it up automatically. Garnix badge in README uses the shields.io
  endpoint format (see fleet brief — old status.svg URL is dead).
- `./build`, `./test`, `./build_all` top-level bash scripts (`#!/usr/bin/env
  bash`); native builds go through `nix build`, NEVER `nix develop -c zig
  build` natively; cross-compilation via `nix develop -c zig build
  -Dtarget=...` is fine. 5 targets: aarch64-macos, aarch64-linux,
  x86_64-linux, aarch64-windows, x86_64-windows.
- Repo: jj colocated (already initialized), main bookmark **yolo**. Commit
  early and often, only in green states. When the CLI suite is first fully
  green: `gh repo create pmarreck/cols --public --description "..."`, add
  remote, `jj bookmark set yolo -r @-`, `jj git push --allow-new`. gh is
  allowed; raw git is NOT (block-git hook active).
- README.md: capabilities with examples, the IFS origin story, install
  instructions (nix, prebuilt binaries later), badge, MIT note. `--about`
  string and README must not drift from actual behavior — regenerate examples
  from real runs.

## Guardrails

- jj ONLY (cheatsheet symlinked at root). No raw git, no force pushes.
- TDD non-negotiable: failing test → minimal code → green → refactor.
- No Python, no Go — anywhere, including tooling and one-off scripts.
- Tabs for indentation (Zig formats itself; C and bash use tabs).
- Keep `dirtree note <path> "desc"` current for new files; maintain PLAN.md
  checkboxes (datetime-EST on completion); log to MISTAKES.md / LEARNINGS.md /
  DESIRES.md as events warrant.
- Naming: executable `cols`; identifiers/files underscore style.
- Parked ideas (bottom of PLAN.md) need Peter's sign-off before building.

## Reporting

Report to `~/inbox/` on the thelio-pm host (orchestrator runs in `$HOME`) at:
first green suite (include how to try it), any decision needing Peter
(e.g. `-F` regex-vs-literal semantics if you find a conflict I missed),
and final go/no-go with benchmark numbers vs cut/gawk.
