---
purpose: Environment/tooling facts learned while building cols, for future agents
audience: agent
maintained_by: agent
---

# LEARNINGS

- **GNU `env` and `--`:** `env -u VAR -- cmd` works, but `env -u VAR NAME=val -- cmd`
  does NOT — once NAME=VALUE assignments appear, a following `--` is taken as the
  command name ("env: '--': No such file or directory"). Omit `--` when passing
  assignments. Cost us 18 phantom CLI-test failures (the binary was fine).
- **Nix sandbox has no `/usr/bin/env`:** a `#!/usr/bin/env bash` test script cannot
  exec inside `checks.*` derivations — invoke it as `bash ./path/to/script`.
- **`@cImport` still works on Zig 0.16** (deprecated, not removed) — dirtree's
  pcre2 incantation (`b.dependency` → `artifact("pcre2-8")` → `addIncludePath(
  getEmittedIncludeTree())` + `linkLibrary`) transplanted cleanly.
- **zigDepsHash is dep-tree-addressed:** cols got the exact same FOD hash as
  dirtree (`sha256-CZYaUzlhZdEIT0Wep+...`) because both have the identical single
  pcre2 dependency — a useful sanity signal.
- **`zig build test` prints nothing on full success** — silence is green; use
  `--summary all` to see counts.
- **PCRE2_MATCH_INVALID_UTF** (compile option) lets UTF-mode patterns match over
  arbitrary byte streams without match-time UTF errors — essential for a filter
  that must not crash on non-UTF-8 input.
