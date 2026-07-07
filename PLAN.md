---
purpose: Live work items for the cols project, checkbox-tracked
audience: agent
maintained_by: agent
---

# PLAN

Read `inbox/processed/2026-07-06_cols-kickoff.md` FIRST — it is the full spec and briefing.

## Phase 0 — scaffolding
- [x] Read kickoff, prior_art/bash_cols + bash_cols_test, ZIG_RECENT_API_CHANGES.md (2026-07-06 12:20 PM EST)
- [x] flake.nix (zig-overlay pinned Zig 0.16, Strategy-1 zigDepsHash FOD for pcre2), build.zig, build.zig.zon (pmarreck/pcre2 zig-0.16.0 tag) (2026-07-06 12:40 PM EST)
- [x] ./build ./test scripts (nix build based); ./build_all (5 targets, untested yet) (2026-07-06 12:40 PM EST)
- [x] Debug-build stderr banner + MUTE_DEBUG_STATUS; ReleaseFast default optimize option (2026-07-06 12:40 PM EST)

## Phase 1 — core (TDD: 30-case bash suite ported as the failing spec first)
- [x] Zig core: spec parsing (n, m-n, m-, comma lists; prior-art validation semantics) (2026-07-06 12:40 PM EST)
- [x] Zig core: splitters — default ws / literal / shell-IFS / PCRE2 regex / whole-line (2026-07-06 12:40 PM EST)
- [x] Zig core: field selection + joining (line correspondence, clamping, OFS, JSON) (2026-07-06 12:40 PM EST)
- [x] C FFI (cols.h) + C CLI dogfooding it; precedence flags > COLS_IFS > IFS > default (2026-07-06 12:40 PM EST)
- [x] CLI suite: all 30 prior-art cases ported, raw-IFS test INVERTED (works natively!), + flags/regex/precedence/JSON/UTF-8/CRLF/files coverage — 92 tests (2026-07-06 12:40 PM EST)
- [x] `./test` green natively (hermetic nix check: 59 unit + 92 CLI) (2026-07-06 12:40 PM EST)

## Phase 2 — ship
- [x] README.md: capabilities, examples (from real runs), IFS war story, install, Garnix badge (2026-07-06 12:50 PM EST)
- [x] All 5 cross-targets build via ./build_all (2026-07-06 12:48 PM EST)
- [x] `gh repo create pmarreck/cols --public`, jj git push (yolo bookmark, default branch) (2026-07-06 12:50 PM EST)
- [x] Garnix checks green on GitHub — evaluate/build/test/package/devShell all succeed; the "All Garnix checks" aggregate stays pending forever, same as dirtree (org norm) (2026-07-06 2:25 PM EST)
- [x] ./bm: hyperfine vs cut/gawk (ndjson log, two-sided tolerance); O(n) scaling-ratio gate — cols beats gawk 1.4–8.4x, within 1.19x of cut on its home turf, scaling cleanly linear (2026-07-06 12:55 PM EST)
- [x] First-green report to ~/inbox/ (orchestrator) (2026-07-06 12:45 PM EST)
- [x] Final GO report to ~/inbox/ with benchmark numbers (2026-07-06 2:25 PM EST)

## Awaiting Peter
- Tagged release with prebuilt binaries for the 5 targets (README promises "with
  the first tagged release" — one /ship away when wanted)
- Parked-ideas list below

## Optimization candidates (post-MVP, measured-first)
- [x] Beat `cut` on colon_1_7 (Peter asked "can we take down cut?"): (1) early-exit
  splitting at max-needed-field, (2) single-byte-literal memchr fast path,
  (3) stream-emit for ascending atoms (no field materialization). Result:
  cols 1.08x FASTER than cut (0.220s vs 0.237s CPU), 9.0x faster than gawk;
  ws mode 3.65x faster than gawk; regex mode 3.4x faster than before;
  scaling gate still cleanly linear (2026-07-06 2:05 PM EST)
- Possible future: stream-emit for default-ws mode (already 3.65x over gawk,
  no external comparator to chase)

## Phase 3 — Peter-approved features (2026-07-06)
- [x] Negative indices from the end: `-1` = last field; ranges via repeated
  hyphen `2--1`, `-3--1`, `-2-`; open range unified as hi=-1 (spec.LAST);
  mixed-sign ranges resolve per line; same-sign reversed rejected statically;
  CLI accepts `-N` args as specs (2026-07-06 3:10 PM EST)
- [x] `-c`/`--chars` Unicode-aware char ranges (code points, NOT bytes — beats
  cut): bare flag + cut-style attached `-c1-5`/`-c-2-`; conflicts with
  -d/-t/-e/-F exit 2; join "" default, -O overrides; invalid UTF-8 degrades
  to byte-per-column (2026-07-06 3:10 PM EST)
- [x] `-F ''` per-char split (awk FS="") — same splitter as -c, literal join
  rules; IFS=''/COLS_IFS=''/-d '' keep shell whole-line semantics
  (2026-07-06 3:10 PM EST)
- [x] /ship: Garnix green on head, tagged release 20260706.d43dee6 with prebuilt
  binaries for all 5 targets + SHA256SUMS (2026-07-06 3:12 PM EST)

## Phase 4 — null-value batch (orchestrator 2026-07-07, Peter-approved, SPEC-CHANGING)
- [x] Atom representation: hi is ?i64 (null = open/elastic) — `-3--1` promised
  vs `-3-` elastic now distinct; pure refactor stayed green (2026-07-07 12:10 PM EST)
- [x] Null semantic: promised positions render `∅` when missing; elastic specs
  render only what exists; 17 assertions flipped RED first (2026-07-07 12:20 PM EST)
- [x] --null-value[=]V (UTF-8 validated; '' suppresses the slot = old behavior);
  JSON emits real null regardless of glyph (2026-07-07 12:20 PM EST)
- [x] --strict: exit 3, fail-fast, diag names line + missing columns (negatives
  in user's own terms); clean prior lines still emitted (2026-07-07 12:20 PM EST)
- [x] -s/--only-delimited: skips <2-field lines before strict; works in the
  stream fast path via first-memchr check (2026-07-07 12:20 PM EST)
- [x] -l/--line-buffered + fread→read() fix (fread blocked until full buffer on
  pipes); default buffering pinned to block-on-pipe via setvbuf — musl
  line-buffers pipes by default, glibc doesn't (2026-07-07 12:22 PM EST)
- [x] Extent guard: promised range > 2^24 positions → exit 2 (skipped under
  --clamp, which keeps old tolerance) (2026-07-07 12:20 PM EST)
- [x] chars mode (-c) unchanged: clamps, exempt from nulls/-s/strict (2026-07-07 12:20 PM EST)
- [x] ADDENDUM --clamp: byte-for-byte old behavior, flipped tests ported to
  --clamp coverage; --clamp --strict exit 2; --null-value inert under clamp
  (2026-07-07 12:20 PM EST)
- [x] Version 0.2.0, suite reads version from build.zig.zon; README "Missing
  data" section; ./bm within tolerance (cut still beaten), scaling linear;
  hermetic ./test green: 94 unit + 150 CLI (2026-07-07 12:25 PM EST)
- [x] Report to ~/inbox (go/no-go + flagged decisions) (2026-07-07 12:28 PM EST); NO release (Peter decides)

## Parked / non-MVP (do not build without Peter)
- `--json` input mode (JSON-array lines in)
- Progress indication (cols is a fast filter; likely never needed)
- Homebrew formula / nix flake app registration beyond this repo
- Windows: _wfopen for non-ACP UTF-8 paths (fopen works when ACP=UTF-8)
- Tagged release with prebuilt binaries (one /ship away when wanted)
