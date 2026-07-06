---
purpose: Live work items for the cols project, checkbox-tracked
audience: agent
maintained_by: agent
---

# PLAN

Read `inbox/2026-07-06_cols-kickoff.md` FIRST — it is the full spec and briefing.

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
- [ ] README.md: capabilities, examples, IFS war story, install, Garnix badge
- [ ] All 5 cross-targets build via ./build_all
- [ ] `gh repo create pmarreck/cols --public`, jj git push (yolo bookmark)
- [ ] Garnix checks (build + test) green on GitHub
- [ ] ./bm: hyperfine vs cut/gawk (ndjson log, two-sided tolerance); scaling-ratio gate on the splitter
- [ ] Report to ~/inbox/ (orchestrator): first-green report NOW, final go/no-go with benchmarks later

## Parked / non-MVP (do not build without Peter)
- Negative column indices (`cols -1` = last field) — flag-parsing conflict to design around
- `cut -c` style char/byte ranges
- `--json` input mode (JSON-array lines in)
- `-F ''` per-character split (awk FS="" behavior) — currently empty separator = whole-line, uniformly
- Progress indication (cols is a fast filter; likely never needed)
- Homebrew formula / nix flake app registration beyond this repo
- Windows: _wfopen for non-ACP UTF-8 paths (fopen works when ACP=UTF-8)
