# fs-lint

<!-- project language and license matching CMakeLists.txt and LICENSE -->

[![C17](https://img.shields.io/badge/C-17-00599C?logo=c&logoColor=white)](./CMakeLists.txt)
[![CI](https://github.com/yowainwright/fs-lint/actions/workflows/ci.yml/badge.svg)](https://github.com/yowainwright/fs-lint/actions/workflows/ci.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](./.github/CONTRIBUTING.md)

`fs-lint` lints your project's file and folder structure. It checks proposed
paths against glob rules in your config.

Use it in agent lifecycle hooks to stop one-off files before they enter the
tree! It also works in Git hooks and CI.

## How It Works

`fs-lint` checks new files against a config:

```json
{
  "version": 1,
  "newFiles": {
    "default": "deny",
    "allow": ["src/**/{index,utils,types,constants}.ts"]
  }
}
```

It allows or errors based on that config:

```diff
  src/
    auth/
+     index.ts
+     utils.ts
-     helper.ts
-     schema.generated.ts
    auth-utils/
+     index.ts
```

That's it!

`fs-lint` has a small CLI:

```sh
fs-lint
fs-lint --allow "src/**/helper.ts"
fs-lint --deny "src/**/*.generated.ts"
```

In agent lifecycle hooks, I use it to keep file creation in bounds.

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

If an agent goes out of bounds:

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
      "docs/**/*.md",
    ]
  }
}
```

You can also use CLI patterns to test or override config.

```sh
fs-lint check src/auth/helper.ts --allow "src/**/helper.ts"
```

```diff
  src/
    auth/
+     helper.ts
```

```sh
fs-lint check src/auth/schema.generated.ts --deny "src/**/*.generated.ts"
```

```diff
  src/
    auth/
-     schema.generated.ts
```

CLI patterns are appended after config patterns, in the order provided.

---

## Install

### Homebrew

```sh
brew install yowainwright/tap/fs-lint
```

### From Source

The Homebrew release integration test requires Ruby on your `PATH`. CMake
omits that test when Ruby is unavailable.

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
ctest --test-dir build --output-on-failure
cmake --install build --prefix ./dist
```

---

## CLI API

```sh
fs-lint [--root path] [--config path] [--format text|json] \
  [--allow pattern] [--deny pattern]

fs-lint check [--root path] [--config path] [--format text|json] \
  [--allow pattern] [--deny pattern] [--] <path>...

fs-lint check (--stdin0|--staged|--base ref) [--root path] [--config path] \
  [--format text|json] [--allow pattern] [--deny pattern]

fs-lint check-path [--root path] [--config path] [--format text|json] \
  [--allow pattern] [--deny pattern] [--] <path>
```

Examples:

```sh
fs-lint
fs-lint --allow "src/**/helper.ts"
fs-lint check src/auth/helper.ts src/auth/index.ts
fs-lint check --staged
fs-lint check --base origin/main
git diff --name-only --diff-filter=A --no-renames -z | fs-lint check --stdin0
```

With no subcommand, `fs-lint` validates the discovered config. `check` accepts
explicit paths or exactly one source. `--stdin0` treats each NUL-delimited path
as added. `--staged` checks added paths and staged config in the Git index.
`--base` checks added paths on `HEAD` since its merge base with a Git ref.

Exit code `0` means allowed, `1` means policy violations, and `2` means usage
or configuration error.

---

## Configuration

Use `.fs-lintrc` or `fs-lint.json` for JSON:

```json
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
package files. The C library is available for early integrations, but its API
is preview until `1.0`.

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

The hook setup installs a managed pre-commit hook. It runs shell checks,
`clang-format`, `clang-tidy`, and debug tests. Both C tools are required; see
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
