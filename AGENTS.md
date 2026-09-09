# Agent Rules

fs-lint provides a C17 CLI and policy library for linting file and folder structure. Follow established C17, POSIX, CMake, and Git APIs. Custom code needs evidence and source links.

- Check existing files, code, issues, pull requests, and git history before creating or editing artifacts.
- Do not stage or commit unless explicitly asked. External publishing also requires an active matching Greploop permission window.
- Keep architecture notes in `tmp/*.md` aligned before commit-ready work.
- Keep checkouts, verification copies, and build work inside this workspace. Ask before modifying another repository.
- No snowflakes. Reuse the project's tools and patterns; do not introduce new architecture.

## Communication Style

- Teach before acting: give a small amount of context with cited evidence.
- Be terse. No preamble, request-parroting, sign-offs, or obvious next steps.
- State uncertainty plainly. Do not fake confidence.
- Before editing, name the exact source, file, tool, API, or pattern being used.
- If the default path is unclear, ask one precise question instead of listing options.
- If the user pushes back, use `grill-me`: at most two focused questions, one at a time, with a recommended answer.

## Core Defaults

- Use C17 and CMake 3.20 or newer, as configured in [CMakeLists.txt](CMakeLists.txt). Build outside the source directories with `cmake -S . -B build` and `cmake --build build --parallel`.
- Keep `liblegibility` dependency-free. Keep Git, configuration parsing, filesystem access, and process execution in the CLI, following the [contributing guide](.github/CONTRIBUTING.md#changes).
- Reuse the vendored yyjson and tomlc17 parsers for JSON and TOML configuration. Follow the Vendor Policy below.
- Use CTest with the existing C tests, CMake e2e fixtures, and shell/Ruby integration tests in `tests/`. Run `ctest --test-dir build --output-on-failure`; prefer e2e proof for CLI and filesystem behavior.
- Use clang-format and clang-tidy with [scripts/.clang-format](scripts/.clang-format) and [scripts/.clang-tidy](scripts/.clang-tidy). Pass configuration paths explicitly, as [scripts/setup.sh](scripts/setup.sh) and CI do.
- Use POSIX `sh` for shell scripts. Run the configured shfmt, ShellCheck, and shellcheck-legibility checks through `./scripts/setup.sh shell-check`.
- Keep functions single-purpose and under 20 lines. Prefer `const` values, early returns, and named conditions over nesting.
- Keep generated `build/`, `build-*/`, `dist/`, and CMake artifacts out of source edits. Update `CMakeLists.txt` and the relevant sources in `include/`, `src/`, `scripts/`, and `cmake/`.
- Read [CMakeLists.txt](CMakeLists.txt), the [contributing guide](.github/CONTRIBUTING.md), and [CI](.github/workflows/ci.yml) for build and validation commands. `./scripts/setup.sh pre-commit` runs format, lint, and debug tests. Run relevant checks and one focused cleanup pass after non-trivial edits.

## Stop Conditions

- Before editing, name the exact default tool, API, or pattern being used.
- If you cannot name it, do not edit.
- Ask: "I'm at `<file>`, implementing `<specific behavior>`. Which `<specific default API or pattern>` should I use?"
- Ask one buffer question only after the default path is exhausted.
- Do not invent wrappers, bespoke infrastructure, or new architecture.

## Filesystem Linting Design

- Use standard linter/tester glob selection for proposed files.
- Keep `newFiles.allow` as the path allowlist; support `*`, `**`, `?`,
  `{a,b}`, and ordered leading `!` negation.
- Do not add `regex:` or an `ls` tree unless the work is specifically filename
  naming rules, not file selection.
- Keep proposed-change linting as the first product boundary. Added files and
  rename destinations are checked; existing repository-wide violations are not
  the first target.
- No snowflake design. KISS.
- Treat file length as a structural signal only for explicitly scoped canonical
  files, such as `index.ts` or `utils.ts`. Do not add line-length formatting
  rules.

## Proof Standard

- Prefer e2e proof for filesystem behavior.
- When matching changes, cover matcher tests, README-rule e2e, and full `ctest`.
- Slow is smooth, smooth is fast.

## Vendor Policy

- Treat files under `vendor/` as read-only third-party source by default.
- Do not edit vendored source unless the user explicitly approves the patch.
- Prefer upstream updates, build-system isolation, or replacing the dependency
  over carrying private vendor patches.
- If a vendor patch is approved, document why it exists and how it will be
  removed or upstreamed.

Reference behavior:

- https://jestjs.io/docs/configuration#testmatch-arraystring
- https://vitest.dev/config/#include
- https://ls-lint.org/2.2/configuration/the-rules.html
