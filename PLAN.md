---
purpose: Live work items for the cols project, checkbox-tracked
audience: agent
maintained_by: agent
---

# PLAN

Read `inbox/2026-07-06_cols-kickoff.md` FIRST — it is the full spec and briefing.

## Phase 0 — scaffolding
- [ ] Read kickoff, prior_art/bash_cols + bash_cols_test, ZIG_RECENT_API_CHANGES.md
- [ ] flake.nix (zig-overlay pinned Zig 0.16, Strategy-1 zigDepsHash FOD for pcre2), build.zig, build.zig.zon (pmarreck/pcre2 zig-0.16.0 tag — copy dirtree's incantation)
- [ ] ./build ./test scripts (nix build based, per fleet build-system rules); ./build_all (5 targets)
- [ ] Debug-build stderr banner + MUTE_DEBUG_STATUS; ReleaseFast default optimize option

## Phase 1 — core (TDD: port the 30-case bash suite as the failing spec first)
- [ ] Zig core: spec parsing (n, m-n, m-, comma lists; validation semantics from prior art)
- [ ] Zig core: splitters — default whitespace mode; literal string; shell-IFS semantics; PCRE2 regex
- [ ] Zig core: field selection + joining (line correspondence, clamping, OFS)
- [ ] C FFI (cols.h) + C CLI dogfooding it; arg parsing incl. precedence rules
- [ ] CLI test suite (bash, tests/cli/) — port all 30 prior-art cases, INVERT the raw-IFS test (must now WORK), add flag/regex/precedence/JSON/UTF-8/paths-with-spaces coverage
- [ ] `./test` green natively

## Phase 2 — ship
- [ ] README.md: capabilities, examples, IFS war story, install, Garnix badge
- [ ] --about / --help / --version final; i18n groundwork only (COLS_LANG > LANG, --lang)
- [ ] All 5 cross-targets build via ./build_all
- [ ] Garnix checks (build + test) green
- [ ] `gh repo create pmarreck/cols --public`, jj git push (yolo bookmark)
- [ ] ./bm: hyperfine vs cut/gawk (ndjson log, two-sided tolerance); scaling-ratio gate on the splitter
- [ ] Report to ~/inbox/ (orchestrator) with status + benchmark numbers

## Parked / non-MVP (do not build without Peter)
- Negative column indices (`cols -1` = last field) — flag-parsing conflict to design around
- `cut -c` style char/byte ranges
- `--json` input mode (JSON-array lines in)
- Homebrew formula / nix flake app registration beyond this repo
