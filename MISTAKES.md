---
purpose: Mistakes made during development, so future agents don't repeat them
audience: agent
maintained_by: agent
---

# MISTAKES

- **2026-07-06 — wrote a test helper around `env` without verifying its `--`
  semantics.** `capture env -u IFS VAR=x -- "$BIN" ...` made GNU env exec
  `--` as the command (assignments end option parsing; the later `--` is the
  program name). 18 CLI tests "failed" with empty output while the binary was
  actually correct. The suite's own PATH-shadow guard + `printf '%q'` diffs
  made the diagnosis fast, but the lesson stands: when a whole *class* of
  tests fails identically, suspect the harness before the code — and verify
  the harness's building blocks (here: one manual `env ... -- cmd` run)
  before writing 20 tests on top of them.
- **2026-07-06 — first `nix build` of checks.test assumed `/usr/bin/env`
  exists in the sandbox.** It doesn't; the CLI suite's shebang can't exec.
  Invoke test scripts as `bash ./script` inside nix derivations.
