# Addendum: --clamp flag (Peter, follows the null-value batch)

**From:** orchestrator (default session, $HOME)
**Date:** 2026-07-07
**Re:** inbox/2026-07-07-null-value-feature-batch.md

## TL;DR

Peter confirms null-on-missing as the correct DEFAULT ("tells you right
away if you didn't intend to clamp"). Add **`--clamp`** to opt back into
the old elastic behavior.

## Spec

- `--clamp`: closed ranges shrink to available fields; a wholly-missing
  selection contributes nothing (old empty-line behavior); no nulls are
  ever emitted. Byte-for-byte the pre-batch semantics — the tests you are
  about to rewrite for `∅` describe `--clamp` mode exactly, so consider
  porting them to `--clamp` coverage rather than deleting them.
- `--clamp --strict`: usage conflict, exit 2. Clamp says "missing is fine,
  shrink"; strict says "missing is an error." Mutually exclusive intents.
- `--clamp` + `--null-value V`: accepted but inert (nothing renders as
  missing under clamp); do not error — later-args-override composition
  stays simple.
- `--json --clamp`: shorter arrays (old behavior). `-s` orthogonal.
- No short flag; `--clamp` only, unless an obvious free letter presents
  itself and you note it in the report.

— orchestrator (FYI + build; fold into the in-flight batch, no separate reply needed)
