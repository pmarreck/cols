# cols

[![Garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fpmarreck%2Fcols%3Fbranch%3Dyolo)](https://garnix.io/repo/pmarreck/cols)

Extract columns from line-oriented text by number. Extremely fast, native,
cross-platform. The tool `column` should have been.

```console
$ tailscale status | cols 2                 # hostnames
$ ls -l | cols 5 9-                         # size + filename
$ IFS=: cols 1,7 < /etc/passwd              # user + shell — yes, this works
```

Nobody should have to remember `awk '{print $2}'`, and the obvious names are
squatted: `col` filters nroff line feeds, `column` *formats* tables. `cols`
does the one thing you actually reach for — select fields — and does it
exceedingly well.

## The IFS story (why this is a compiled tool)

`cols` began as a Bash function. It worked, but hit a wall of history: POSIX
shells **scrub the inherited `IFS` at startup** — the fix for the 1980s
`IFS=/` PATH-hijack attack — so `IFS=: my-script` can *never* deliver the
value to a shell script. Its own interpreter destroys it before line 1 runs.
The prototype had to settle for a bespoke `COLS_IFS` variable, and its test
suite literally asserts that raw `IFS` *doesn't* work.

A compiled binary receives `IFS` just fine. So the native `cols` finally
honors the muscle-memory idiom:

```console
$ head -2 /etc/passwd | IFS=: cols 1,7
root:/run/current-system/sw/bin/bash
messagebus:/run/current-system/sw/bin/nologin
```

And it's safe by construction: `IFS`/`COLS_IFS` follow **true shell
word-splitting rules** (whitespace members collapse in runs, non-whitespace
members are strict delimiters). A parent shell that scrubbed-and-re-exported
`IFS=$' \t\n'` therefore yields behavior bit-for-bit identical to the
default mode — stray inherited IFS is harmless. This suite tests that
property explicitly.

## Column specs

Columns are 1-indexed. Negative indices count from the **last** column
(`-1` = last), resolved per line — so ranges involving them repeat the
hyphen. Specs combine freely, space- or comma-separated; selections repeat
and can overlap.

| Spec | Meaning |
|---|---|
| `n` | single column |
| `m-n` | columns m through n |
| `m-` | column m through end of line |
| `-1` | last column |
| `-2` | second-to-last column |
| `2--1` | columns 2 through the last |
| `-3--2`, `-2-` | from-the-end ranges |
| `x,y,z` | comma-joined list of any of the above |

```console
$ tailscale status | cols -1                # last column
$ IFS=: cols 1,-1 < /etc/passwd             # first and last field
```

Lines missing the requested columns print as **empty lines** — input↔output
line correspondence is always preserved, so `cols` stays `paste`-able.
Ranges clamp to the fields present. `0` and statically reversed ranges
(`3-2`, `-1--2`) are rejected (exit 2); mixed-sign ranges like `2--1`
resolve per line and simply select nothing when a short line makes them
backwards.

## Character mode (`-c`) — Unicode-aware, unlike cut

`-c` makes the specs select **characters** (Unicode code points), not
fields. GNU `cut -c` is secretly byte-based (`cut -c2` on `héllo` hands you
half of an `é`); `cols -c` counts real characters. Selected characters
concatenate (override with `-O`); negative indices work here too.

```console
$ printf 'héllo\n' | cols -c 2-4
éll
$ printf 'a🍕b\n' | cols -c -2-
🍕b
$ cols -c2-5 file.txt          # attached form, cut muscle memory
```

Invalid UTF-8 bytes degrade gracefully to one column per byte. `-c` cannot
be combined with separator flags (exit 2).

## Separators

Default: awk semantics — runs of spaces/tabs are one separator, leading
whitespace skipped. Override precedence (highest wins, later flags beat
earlier ones):

1. **Flags**
   - `-e, --regex <pat>` — PCRE2 regex separator (UTF-8, JIT-compiled)
   - `-F <sep>` — awk muscle memory: `' '` = default mode; one char =
     literal; multi-char = regex (awk's ERE rule, upgraded to PCRE2);
     `''` = every character is its own field (awk `FS=""`)
   - `-d, -t <sep>` — literal string separator, even multi-char/multibyte
     (cut/sort muscle memory; adjacent separators delimit empty fields)
2. **`COLS_IFS`** env var (kept from the prototype, now with shell semantics)
3. **`IFS`** env var — the headline feature
4. default whitespace mode

Empty separator from the *shell-flavored* sources (`-d ''`, `IFS=`,
`COLS_IFS=`) = no splitting: the whole line is column 1, mirroring shell
`IFS=` semantics. Only the awk-flavored `-F ''` means per-character
(matching awk).

```console
$ printf 'id,name,city\n1,Ada,London\n2,Linus,Helsinki\n' | cols -d, 2,3
name,city
Ada,London
Linus,Helsinki

$ printf 'a  b\tc   d\n' | cols -e '\s+' 2,4
b d
```

## Output

Selected fields join with the natural separator: the literal one
(`-d`/`-t`/one-char `-F`), the first `IFS` character (shell `"$*"`
convention), or a single space (default and regex modes). Override with
`-O/--output-sep`:

```console
$ printf 'a b c\n' | cols -O ' | ' 1,3
a | c
```

`--json` emits a JSON array of arrays (one per input line, fields as
strings, fully escaped, always valid UTF-8):

```console
$ printf 'a b\nc d\n' | cols --json 1-2
[["a","b"]
,["c","d"]
]
```

## Input

Reads stdin by default; file paths may follow the specs (`-` and `@stdin`
mean stdin; paths with spaces are fine). CRLF line endings are handled
(Windows is a first-class target). No line-length limits. Errors go to
stderr; exit codes: `0` success, `1` I/O error, `2` usage/spec error.

## Performance

Measured with hyperfine on a 2M-line (~90MB) corpus, x86_64 Linux
(`./bm` reproduces this, logs to `bench/`, and gates on regressions in
both directions plus an O(n) scaling-ratio check):

| Task | vs `cut` | vs `gawk` |
|---|---|---|
| whitespace mode, `cols 2` | n/a (cut can't collapse runs) | **3.7× faster** |
| literal mode, `cols -d: 1,7` | **1.08× faster** | **9.0× faster** |

Yes: faster than `cut` at cut's own game, while doing strictly more. The
engine early-exits at the largest requested column, uses memchr-style SIMD
scans, and stream-emits ascending selections with zero per-field
materialization.

## Install

With Nix (flakes):

```console
$ nix build github:pmarreck/cols && ./result/bin/cols --about
```

From a clone:

```console
$ ./build          # sandboxed nix build → zig-out/bin/cols
$ ./test           # the full hermetic suite (Zig unit + CLI acceptance)
```

Or grab a prebuilt binary from the
[releases page](https://github.com/pmarreck/cols/releases) — macOS (arm64),
Linux (arm64/x86_64, fully static musl), and Windows (arm64/x86_64), with
SHA256SUMS.

## Architecture

```
C CLI (all I/O) ──► C FFI (include/cols.h) ──► pure Zig core (no I/O)
                                                    └── PCRE2-8, static
```

The Zig core is pure in-memory computation; the C CLI does every syscall and
consumes the core strictly through the C header — the same FFI any other
consumer would use, exercised on every test run. `libcols` + `cols.h` are
installable artifacts.

## License

MIT. © 2026 Peter Marreck.
