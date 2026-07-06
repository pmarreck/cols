---
purpose: What cols is, why it exists, and the vocabulary used across its docs
audience: both
maintained_by: agent
---

# cols — PROJECT_OVERVIEW

## One-liner

`cols` extracts columns from line-oriented text by number: `tailscale status | cols 2`.
The tool `column` should have been, with the speed of a purpose-built native binary.

## Why it exists

Extracting "column 2" from command output requires remembering `awk '{print $2}'`
or `cut`'s single-char-delimiter rules. The obvious names — `col`, `column` — are
squatted by util-linux tools that do *other things* (nroff line-feed filtering and
table *formatting*, respectively). A Bash prototype (see `prior_art/`) proved the
interface in a day; this project is its production form: a pure-Zig core behind a
C FFI, dogfooded by a C CLI, cross-compiled to 5 platforms, published on GitHub
(pmarreck/cols), MIT licensed.

Unix ethos applies: **do one thing (select columns) exceedingly well, and be
extremely fast** — competitive with `cut`, faster than awk for the common cases.

## The IFS story (why this is a compiled tool, and why IFS works here)

POSIX shells scrub an inherited `IFS` at startup (the 1980s `IFS=/` PATH-hijack
fix), so `IFS=: some-bash-script` can NEVER deliver the value — the script's own
interpreter destroys it before line 1. Compiled binaries receive `IFS` just fine.
So the native `cols` honors `IFS=: cols 1,7 < /etc/passwd` — the muscle-memory
idiom the Bash prototype physically could not support (it uses `COLS_IFS`, which
the native tool also honors, at higher precedence). This story belongs in the
README; it is the tool's origin myth and its differentiator.

## Terminology

- **spec** — a column selector argument: `n`, `m-n` (closed range), `m-` (open
  range, to end of line), comma-combinable (`2,4-6`) and space-combinable.
  1-indexed. Ranges clamp to the fields present.
- **line correspondence** — every input line yields exactly one output line,
  even when empty (no requested field present). Enables `paste`-style rejoining.
- **separator modes** — default (runs of whitespace, leading skipped), literal
  (`-d`/`-t`/single-char `-F`), shell-IFS semantics (`IFS`/`COLS_IFS` env), and
  PCRE2 regex (`-e`/`--regex`, multi-char `-F`).
- **joiner / OFS** — string used to rejoin selected fields on output.
- **prior art** — `prior_art/bash_cols` + `bash_cols_test`: the Bash prototype
  and its 30-case suite, the behavioral spec of record for everything it covers.

## Architecture (fleet standard)

```
C CLI (all I/O, arg parsing) ──► C FFI boundary ──► Zig core (pure, no I/O)
                                                        └── PCRE2 (C, statically linked)
```

The C CLI deliberately dogfoods the FFI — C cannot `@import` Zig, so the
boundary is enforced by physics, not policy. PCRE2 comes from the pmarreck/pcre2
fork (zig-0.16.0 tag) exactly as `~/Code/dirtree` consumes it.

## Non-goals

- Not a table *formatter* (that's `column -t`).
- Not a general text processor — no computed fields, no arithmetic, no
  substitutions. If you need awk, use awk.
- No character/byte-range selection (`cut -c`) in MVP.
