# Repository Guidelines

## Project Structure & Modules
- `sigils/`: Core library modules (e.g., `agents.nim`, `signals.nim`, `threads.nim`). Public entry is `sigils.nim` which re-exports key modules.
- `tests/`: Unit tests using Nim's `unittest` plus a `config.nims` that enables ARC/threads and debug flags.
- Root files: `sigils.nimble` (package manifest), `README.md` (usage), `CHANGES.md` (history).

## Build, Test, and Development
- Install deps (atlas workspace): `atlas install` (ensure `atlas` is installed and configured for your environment).
- Run all tests: `nim test` (uses the `test` task in `config.nims` to compile and run every `tests/*.nim`).
- Run a single test locally:
  - `nim c -r tests/treactiveSigil.nim`
- Helpful flags: `-d:sigilsDebug` for verbose names; define `tsan` to enable ThreadSanitizer per `tests/config.nims`.

## Coding Style & Naming
- Indentation: 2 spaces; no tabs.
- Nim style: Types in `PascalCase`, procs/vars in `camelCase`, modules in `lowercase` or concise `lowerCamel` (e.g., `threadAsyncs.nim`).
- Prefer explicit exports via `export` in `sigils.nim` or module-level as needed.
- Formatting: run `nimpretty --backup:off sigils/*.nim` and format any touched test files.

## Testing Guidelines
- Framework: `unittest` with descriptive `suite` and `test` names.
- Location: add new tests under `tests/`, mirroring module names (e.g., `tslots.nim` for `slots.nim`).
- Run all: `nim test`. Run one: `nim c -r tests/tslots.nim`.
- Concurrency: tests run with `--threads:on` (see `tests/config.nims`). Use `when defined(sigilsDebug)` to gate extra diagnostics.

## Commit & Pull Requests
- Commits: short, imperative mood (e.g., "add isRunning"), optionally reference PR/issue like `(#21)`.
- PRs: include a clear description, linked issues, summary of changes, any threading or GC considerations, and test coverage notes. Attach logs or minimal repros if fixing concurrency.
- Requirements: CI (`nimble test`) must pass; include tests for new behavior and update `README.md`/`CHANGES.md` as needed.

## Security & Configuration Tips
- GC: library requires ARC/ORC (`--gc:arc` or `--gc:orc`); enforced in `sigils.nim`.
- Threads: prefer `AgentProxy` and provided helpers for cross-thread signaling; avoid manual ref cycles. Consider `-d:tsan` locally when touching threading code.
