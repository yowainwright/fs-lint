# fs-lint ✎﹏

<!-- project language and license matching CMakeLists.txt and LICENSE -->

[![C17](https://img.shields.io/badge/C-17-00599C?logo=c&logoColor=white)](./CMakeLists.txt)
[![CI](https://github.com/yowainwright/fs-lint/actions/workflows/ci.yml/badge.svg)](https://github.com/yowainwright/fs-lint/actions/workflows/ci.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](./.github/CONTRIBUTING.md)

**fs-lint** lints your project's file and folder structure. Set the allowed
paths with [glob rules](#glob-syntax) in your config.

Use it in agent lifecycle hooks to catch one-off files! It also works in Git
hooks and CI.

## How It Works

Save your rules in `fs-lint.json`:

```jsonc
{
  "version": 1,
  "newFiles": {
    "default": "deny",
    "allow": ["src/**/{index,utils,types,constants}.ts"]
  }
}
```

In the trees below, `+` means allowed and `-` means rejected. fs-lint reports
violations without changing files.

```diff
  src/
  ├── auth/
+ │   ├── index.ts
+ │   ├── utils.ts
- │   ├── helper.ts
- │   └── schema.generated.ts
  └── auth-utils/
+     └── index.ts
```

That's it!

Run `fs-lint` to validate your config:

```sh
fs-lint
```

In agent lifecycle hooks, I use `--staged` to check new paths before committing:

```diff
"Stop": [
  {
    "hooks": [
      {
        "type": "command",
+       "command": "fs-lint check --staged",
        "timeout": 120,
        "statusMessage": "Running session checks"
      }
    ]
  }
]
```

If a staged path breaks the rules, it prints an error and exits with code `1`:

```diff
- src/auth/helper.ts: error files/new: new file is not allowed by configuration
```

You can use `**/` to match zero or more directories.

```jsonc
{
  "version": 1,
  "newFiles": {
    "default": "deny",
    "allow": [
      "README.md",
      "docs/**/*.md"
    ]
  }
}
```

You can override rules for one run. Using the first config:

```sh
fs-lint check src/auth/helper.ts --allow "src/**/helper.ts"
```

```diff
  src/
  └── auth/
+     └── helper.ts
```

```sh
fs-lint check src/auth/index.ts --deny "src/auth/index.ts"
```

```diff
  src/
  └── auth/
-     └── index.ts
```

CLI patterns follow config patterns in the order supplied. [More examples below](#cli).

---

## Install

### Homebrew

```sh
brew install yowainwright/tap/fs-lint
```

### From Source

Ruby is optional. Without it, CMake skips the Homebrew release integration test.

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
ctest --test-dir build --output-on-failure
cmake --install build --prefix ./dist
```

---

## CLI

These examples use the first `fs-lint.json` config in [How It Works](#how-it-works).
The trees show proposed paths: `+` means allowed and `-` means rejected.
Successful checks are silent. Rejected paths produce an error.

### `fs-lint`

Validates your config. Searches upward from the current directory to the Git
repository root or filesystem root.

```sh
fs-lint
```

A valid config passes silently (exit `0`). Use `check` to check paths.

### `fs-lint check`

Checks one or more proposed paths. Files don't need to exist yet.

```sh
fs-lint check src/auth/index.ts src/auth/helper.ts
```

```diff
  src/
  └── auth/
+     ├── index.ts
-     └── helper.ts
```

Rejects `helper.ts` (exit `1`). Use `--` before paths that start with `-`.

### `fs-lint check --staged`

Checks staged additions and rename destinations against the staged config. Use
this in a Git hook.

```sh
fs-lint check --staged
```

If `index.ts` and `helper.ts` are staged as new files:

```diff
  src/
  └── auth/
+     ├── index.ts
-     └── helper.ts
```

Rejects `helper.ts` (exit `1`). Untracked files, unstaged additions, and edits to
existing files are skipped.

### `fs-lint check --base`

Checks your branch's committed additions and rename destinations since its
common ancestor with another Git ref. Useful in CI.

```sh
fs-lint check --base origin/main
```

If your branch added `utils.ts` and `helper.ts` since that point:

```diff
  src/
  └── auth/
+     ├── utils.ts
-     └── helper.ts
```

Rejects `helper.ts` (exit `1`). Uses your local config and excludes uncommitted
changes.

### `fs-lint check --allow`

Allows a path your config would reject, for this run. Quote globs so your shell
passes them unchanged.

```sh
fs-lint check src/auth/helper.ts --allow "src/**/helper.ts"
```

```diff
  src/
  └── auth/
+     └── helper.ts
```

Passes silently (exit `0`).

### `fs-lint check --deny`

Rejects a path your config would allow, for this run.

```sh
fs-lint check src/auth/index.ts --deny "src/auth/index.ts"
```

```diff
  src/
  └── auth/
-     └── index.ts
```

Rejects `index.ts` (exit `1`). CLI patterns follow config patterns; the last
matching pattern wins.

### `fs-lint check --stdin0`

Reads paths separated by NUL bytes (`\0`) from another command. This preserves
spaces and newlines in filenames.

```sh
printf 'src/auth/index.ts\0src/auth/helper.ts\0' | fs-lint check --stdin0
```

```diff
  src/
  └── auth/
+     ├── index.ts
-     └── helper.ts
```

Rejects `helper.ts` (exit `1`). Each supplied path counts as a new file.
Choose one input per run: explicit paths, `--stdin0`, `--staged`, or `--base`.

### `fs-lint check-path`

Checks exactly one proposed path.

```sh
fs-lint check-path src/auth/index.ts
```

```diff
  src/
  └── auth/
+     └── index.ts
```

Passes silently (exit `0`).

### `fs-lint check --root`

Starts config discovery in another directory. Here, `packages/app` contains the
opening config:

```sh
fs-lint check --root packages/app src/auth/index.ts
```

```diff
  packages/
  └── app/
      ├── fs-lint.json
      └── src/
          └── auth/
+             └── index.ts
```

Passes silently (exit `0`). The matched path is `src/auth/index.ts`; `--root`
doesn't change the supplied path.

### `fs-lint check --config`

Selects a config file. Save the opening config as `config/fs-lint.json` for this
example:

```sh
fs-lint check --config config/fs-lint.json src/auth/index.ts
```

```diff
  .
  ├── config/
  │   └── fs-lint.json
  └── src/
      └── auth/
+         └── index.ts
```

Passes silently (exit `0`). Relative config paths start at `--root`, which
defaults to the current directory.

### `fs-lint check --format json`

Prints one JSON object per diagnostic for agents and CI.

```sh
fs-lint check src/auth/index.ts src/auth/helper.ts --format json
```

```diff
  src/
  └── auth/
+     ├── index.ts
-     └── helper.ts
```

Prints this diagnostic on one line (exit `1`):

```jsonc
{"severity":"error","code":"files/new","path":"src/auth/helper.ts","message":"new file is not allowed by configuration"}
```

### `fs-lint --help`

Prints the available commands and options.

```sh
fs-lint --help
```

Exits with code `0`. Use `fs-lint --version` to print the installed version.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Config is valid and all supplied paths are allowed |
| `1` | One or more paths are rejected |
| `2` | Usage, configuration, or input error |

---

## Configuration

Use `.fs-lintrc` or `fs-lint.json` for JSON:

```jsonc
{
  "version": 1,
  "newFiles": {
    "default": "deny",
    "allow": [
      "README.md",
      "docs/**/*.md",
      "src/**/*.{js,ts,tsx}",
      "cmd/**/*.go",
      "crates/**/*.rs",
      "native/**/*.{c,h,cpp}",
      "!**/*.generated.*"
    ]
  }
}
```

Use `fs-lint.toml` for TOML:

```toml
version = 1

[newFiles]
default = "deny"
allow = [
  "README.md",
  "docs/**/*.md",
  "src/**/*.{js,ts,tsx}",
  "cmd/**/*.go",
  "crates/**/*.rs",
  "native/**/*.{c,h,cpp}",
  "!**/*.generated.*",
]
```

`newFiles.default` defaults to `"deny"` when omitted.
Allow patterns are evaluated in order. Positive patterns allow a path. Patterns
that start with `!` deny it again.

---

## Glob Syntax

Patterns match the complete path.

| Pattern | Meaning |
| --- | --- |
| `?` | One non-separator character |
| `*` | Zero or more characters within one path segment |
| `**` | Zero or more characters across path segments |
| `**/` | Zero or more complete directories |
| `{a,b}` | One of the comma-separated alternatives |
| `!` | Deny a matching path after earlier allows |

Forward and backward slashes are treated as path separators.

---

## Library

Source installs include `include/legibility.h`, `liblegibility.a`, and CMake
package files. The C API is in preview until `1.0`.

```cmake
find_package(legibility 0.2 CONFIG REQUIRED)
target_link_libraries(your-target PRIVATE legibility::legibility)
```

```c
const legibility_config config = {
    .new_files_default = LEGIBILITY_NEW_FILES_DENY,
};
const legibility_change change = {
    .path = "src/auth/helper.ts",
    .kind = LEGIBILITY_CHANGE_ADDED,
};

legibility_status status =
    legibility_check(&config, &change, 1, report_diagnostic, context);
```

Configuration parsing, Git integration, and agent hooks stay outside the core
library.

## Roadmap

- Agent integrations that pass proposed file paths before files are written.
- Clearer reports for added files, rename destinations, and ignored changes.
- More examples for standard glob allowlists and ordered `!` denials.
- Release and Homebrew automation that stays reproducible from a version tag.

## Development

```sh
./scripts/setup.sh
```

Installs a managed pre-commit hook that runs shell checks, `clang-format`,
`clang-tidy`, and debug tests. Both C tools are required; see
[development setup](.github/CONTRIBUTING.md#development-setup).

## Release

A tag matching the compiled version, such as `v0.2.0`, publishes source and
binary assets to GitHub. The release workflow also opens a Homebrew tap PR for
`yowainwright/tap/fs-lint`.

Release assets use the `fs-lint-*` prefix. Each asset includes a SHA-256 file;
binary assets also include Sigstore attestations.

## License

MIT. See [LICENSE](./LICENSE). Release archives also include the bundled
[yyjson](https://github.com/ibireme/yyjson) and
[tomlc17](https://github.com/cktan/tomlc17) MIT licenses.
