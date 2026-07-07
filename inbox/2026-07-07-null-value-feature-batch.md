# Peter-approved feature batch: nulls, strictness, -s, line buffering

**From:** orchestrator (default session, $HOME)
**Date:** 2026-07-07
**Re:** follow-up to inbox/processed/2026-07-06_cols-kickoff.md

## TL;DR

Four new flags forming one coherent validation story, approved by Peter
verbatim. **This deliberately CHANGES existing default behavior** (closed
ranges stop clamping; missing fields render a null glyph instead of
nothing) — so the ported prior-art tests change too. Red tests first.

## The unifying semantic

Every **explicitly promised** column position that doesn't exist on a line
renders as the null placeholder (default `∅`, U+2205 EMPTY SET):

```
printf '1 2 3\n' | cols 2-4     →  2 3 ∅
printf 'a b\n'   | cols 5       →  ∅        (was: empty line)
printf 'abc\n'   | cols -d : 2  →  ∅        (undelimited line, was: empty line)
```

"Promised" = specs with static extent: single `n`, closed ranges `m-n`,
same-sign negative closed ranges (`-3--1` promises 3 positions). Elastic
specs — open ranges `m-`, `-2-`, and mixed-sign ranges (`2--1`) whose
extent resolves per line — render only what exists, NO nulls (you didn't
name a fixed count; there is nothing to pad). Line correspondence is
therefore *strengthened*: missing data is now visible instead of silent.

Rationale (Peter): "Faulty-input detection without erroring that shows
exactly what fields weren't matched … and strictness if we want validation
failure to not emit nulls but just error out."

## The four flags

1. **`--line-buffered` / `-l`** — flush stdout after every output line
   regardless of destination (rg precedent). Default stays stdio-normal
   (line-buffered tty, block-buffered pipe — verified identical to
   cut/gawk yesterday). Check `-l` for collisions before claiming it.

2. **`-s` / `--only-delimited`** — skip (emit NOTHING for) lines where
   splitting produced fewer than 2 fields, i.e. no separator matched
   (cut parity, uniform across separator modes). The one sanctioned break
   of line correspondence: "only rows that parse."

3. **`--null-value[=]V`** (also space-form `--null-value V`) — override
   the `∅` glyph. Any UTF-8 string; empty string is legal (restores the
   old invisible behavior). Peter's example: `cols --null-value ␀`.

4. **`--strict`** — input that would emit any null is a validation
   failure: fail fast at the first offending line, one-line stderr
   diagnostic naming line number + missing field(s), nulls NOT emitted.
   Proposed exit-code scheme: 0 ok / 1 I/O / 2 usage / **3 validation** —
   flag in your report if you see a conflict.

## Interactions (spec)

- `-s` runs first: lines it skips are NOT `--strict` violations (they're
  "not data"). A delimited-but-short line IS a violation.
- `--json`: missing promised positions become JSON `null` (the real one),
  NOT the glyph; `--null-value` does not affect JSON mode. `--strict`
  applies identically.
- `-c` char mode: unchanged (clamping stays; nulls/`-s`/`--strict` do not
  apply — chars aren't fields). Document this; open to revisiting.
- Later-args-override holds as everywhere (`--null-value X --null-value Y`
  → Y; `--strict` has no negation yet — add `--no-strict` only if trivial).

## Testing notes

- TDD: update the empty-line-on-missing assertions to `∅` FIRST (watch
  them fail red), then implement. They are intentional spec changes, not
  regressions — note that in the commit message.
- `-l` streaming is testable without timing hacks via the pipe trick:
  `{ printf 'a b\n'; sleep 2; } | timeout 1 ./zig-out/bin/cols -l 2`
  must yield `b` (captured) with rc 124; without `-l` yields nothing.
- Cover: each flag; `-s`+`--strict` composition; `--null-value=` (empty);
  multi-byte glyph joins (∅ is 3 bytes — ensure `-O`/joins are
  byte-clean); JSON null; negative-index promised positions; elastic
  specs get no nulls; UTF-8 validation of `--null-value`.
- Re-run ./bm after: the happy path (all fields present) should be
  unaffected; scaling gate must stay linear.

## Ship

README (nulls get their own section — this is now a distinguishing
feature vs cut/awk), --help, --about, version bump. Commit/push to yolo
when green. **Do NOT cut a new tagged release** — Peter decides when.
Report to ~/inbox/ (orchestrator) with the usual go/no-go.

— orchestrator
