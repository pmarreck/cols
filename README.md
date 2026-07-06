# cols

[![Garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fpmarreck%2Fcols)](https://garnix.io/repo/pmarreck/cols)

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

Columns are 1-indexed. Specs combine freely, space- or comma-separated;
selections repeat and can overlap.

| Spec | Meaning |
|---|---|
| `n` | single column |
| `m-n` | columns m through n |
| `m-` | column m through end of line |
| `x,y,z` | comma-joined list of any of the above |

Lines missing the requested columns print as **empty lines** — input↔output
line correspondence is always preserved, so `cols` stays `paste`-able.
Ranges clamp to the fields present. `0` and reversed ranges are rejected
(exit 2).

## Separators

Default: awk semantics — runs of spaces/tabs are one separator, leading
whitespace skipped. Override precedence (highest wins, later flags beat
earlier ones):

1. **Flags**
   - `-e, --regex <pat>` — PCRE2 regex separator (UTF-8, JIT-compiled)
   - `-F <sep>` — awk muscle memory: `' '` = default mode; one char =
     literal; multi-char = regex (awk's ERE rule, upgraded to PCRE2)
   - `-d, -t <sep>` — literal string separator, even multi-char/multibyte
     (cut/sort muscle memory; adjacent separators delimit empty fields)
2. **`COLS_IFS`** env var (kept from the prototype, now with shell semantics)
3. **`IFS`** env var — the headline feature
4. default whitespace mode

Empty separator (any source) = no splitting: the whole line is column 1,
mirroring shell `IFS=` semantics.

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

Prebuilt binaries for macOS (aarch64), Linux (aarch64/x86_64), and Windows
(aarch64/x86_64): coming with the first tagged release.

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
