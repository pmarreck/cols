# Refinement: at most ONE null per promised range — kill the extent guard

**From:** orchestrator (default session, $HOME)
**Date:** 2026-07-07
**Re:** your 2026-07-07 null-batch GO report, flagged decision #3 (2^24 extent guard)
**No rush — pick this up after your current code review. No ping sent; catch it on your next inbox scan.**

## TL;DR

Peter's replacement for the 2^24 refusal, and it's better: **a promised
closed range emits its present fields, then a SINGLE null at the first
gap, then stops that range.** Fields are contiguous, so once position k is
absent every position after it is absent too — more nulls carry zero
information. One null means "this and everything after is gone"; downstream
tooling detects the single null and applies its own rules. The extent guard
disappears entirely — `cols 2-<huge>` becomes safe by construction (output
is bounded by fields-present + 1, never by the range width).

## The rule (precise)

Per **promised closed range** (single `n` is the degenerate 1-wide case):
1. Emit present fields from the low end up.
2. At the first missing position, emit exactly ONE null, then stop THIS range.
3. If no position is missing, no null (unchanged).

**PER-RANGE, NOT GLOBAL.** Independent atoms are still each evaluated — a
later atom naming a *present* field must still emit it. This is the load-
bearing constraint; a global short-circuit would silently swallow real data.

## Before → after (all on ascending positive ranges)

| input | spec | shipped v0.2.0 | new |
|---|---|---|---|
| `1 2 3` | `2-4` | `2 3 ∅` | `2 3 ∅` (unchanged — null already terminal) |
| `1 2 3` | `2-6` | `2 3 ∅ ∅ ∅` | `2 3 ∅` (collapse tail to one) |
| `a b c` | `5-7` | `∅ ∅ ∅` | `∅` |
| `a b c` | `6 2` | `∅ b` | `∅ b` (**MUST stay — per-range, not global**) |
| `a b c` | `5-7,2` | `∅ ∅ ∅ b` | `∅ b` |
| `1` | `2-99999999` | **exit 2 (guard)** | `∅` (guard deleted) |

The only outputs that change are multi-null tails collapsing to one null,
plus the huge-range case flipping from refusal to a clean single `∅`.

## Remove

- The 2^24 extent-guard refusal and its "closed range promises N positions
  (max ...)" message — gone. Invert its tests: `cols 2-<huge>` now succeeds
  with bounded output, not exit 2.

## Interactions

- **`--strict`**: now trips at the first gap (strictly faster fail; also
  means strict never had a huge-range concern either). Diagnostic still
  names the first missing column. Semantics otherwise unchanged.
- **`--clamp`**: unaffected (still shrinks silently, no nulls).
- **`--null-value ''`**: the single null is suppress-entirely as before, so
  `2-6` on `1 2 3` → `2 3` (bounded, invisible). **Add an explicit test for
  `--null-value ''` — Peter called it out specifically.** Cover both the
  terminal-gap case and a mid-line missing atom (`6 2` → `<nothing> b`, i.e.
  a leading empty slot with no dangling separator).
- **`--json`**: one JSON `null` at the gap per range, then stop the range
  (arrays get shorter — consistent with the glyph rule). Verify.
- **Negative same-sign closed ranges** (e.g. `-3--1`, promises a fixed
  count): apply the same "at most one null per range" principle. The
  contiguous gap sits at the far-from-end side, so placement mirrors the
  positive case from the other direction — emit present slots, one null at
  the first missing, stop. If the placement gets genuinely ambiguous for a
  mixed case, keep it elastic (no nulls) and flag it back rather than guess.

## TDD / bench

- Flip the multi-trailing-null assertions and the extent-guard tests RED
  first, then implement. Frame in the commit as the intended refinement of
  the v0.2.0 null semantics (cite this note).
- Keep the `6 2` → `∅ b` and `5-7,2` → `∅ b` cases as explicit regression
  tests for the per-range (non-global) guarantee — that's the subtle one.
- Bench: happy path untouched; the huge-range path goes from O(range width)
  / refusal to O(fields present). Scaling gate stays linear. No new release.

— orchestrator (FYI + build when you surface; no reply needed)
