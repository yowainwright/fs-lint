#!/bin/sh
set -eu

run_suite() {
  name="${1:?}"
  build_type="${2:?}"
  build_dir="$root/build-hooks-$name"
  prepare_build_dir "$build_dir"
  printf 'setup: %s build\n' "$name"
  cmake -S "$root" -B "$build_dir" -DCMAKE_BUILD_TYPE="$build_type" \
    -DCMAKE_C_FLAGS=-Werror -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
  cmake --build "$build_dir" --parallel
  run_clang_tidy
  printf 'setup: %s tests\n' "$name"
  ctest --test-dir "$build_dir" --output-on-failure
}

run_clang_tidy() {
  printf 'setup: clang-tidy\n'
  set -- -p "$build_dir" src/*.c tests/*.c
  case "$(uname -s)" in
  Darwin)
    sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
    set -- "$@" --extra-arg=-isysroot "--extra-arg=$sdk_path"
    ;;
  esac
  "$clang_tidy" "$@"
}

require_command() {
  command_name="${1:?}"
  hint="${2:-}"
  command -v "$command_name" >/dev/null 2>&1 && return 0
  printf 'setup: missing required command: %s\n' "$command_name" >&2
  [ -z "$hint" ] || printf 'setup: %s\n' "$hint" >&2
  exit 1
}

require_pre_commit_commands() {
  require_command git
  require_command cmake
  require_command ctest
  require_command shfmt
  require_command shellcheck
  require_command shellcheck-legibility
  require_command clang-format
  require_command "$clang_tidy" \
    "install clang-tidy or set CLANG_TIDY to its executable path"
}

resolve_homebrew_clang_tidy() {
  command -v brew >/dev/null 2>&1 || return 1
  llvm_prefix="$(brew --prefix llvm 2>/dev/null || true)"
  [ -n "$llvm_prefix" ] || return 1
  candidate="$llvm_prefix/bin/clang-tidy"
  [ -x "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

resolve_env_clang_tidy() {
  [ -n "${CLANG_TIDY:-}" ] || return 1
  printf '%s\n' "$CLANG_TIDY"
}

resolve_path_clang_tidy() {
  command -v clang-tidy >/dev/null 2>&1 || return 1
  printf '%s\n' "clang-tidy"
}

print_clang_tidy_if_set() {
  clang_tidy_candidate="${1:-}"
  [ -n "$clang_tidy_candidate" ] || return 1
  printf '%s\n' "$clang_tidy_candidate"
}

resolve_clang_tidy() {
  resolved_clang_tidy="$(resolve_env_clang_tidy || true)"
  print_clang_tidy_if_set "$resolved_clang_tidy" && return 0
  resolved_clang_tidy="$(resolve_path_clang_tidy || true)"
  print_clang_tidy_if_set "$resolved_clang_tidy" && return 0
  resolved_clang_tidy="$(resolve_homebrew_clang_tidy || true)"
  print_clang_tidy_if_set "$resolved_clang_tidy" && return 0
  printf '%s\n' "clang-tidy"
}

prepare_build_dir() {
  build_dir="${1:?}"
  cache="$build_dir/CMakeCache.txt"
  [ -f "$cache" ] || return 0
  grep -Fxq "CMAKE_HOME_DIRECTORY:INTERNAL=$root" "$cache" || rm -rf "$build_dir"
}

skip_hooks() {
  [ "${FS_LINT_SKIP_HOOKS:-0}" = "1" ]
}

run_pre_commit() {
  skip_hooks && return 0
  cd "$root"
  require_pre_commit_commands
  printf 'setup: staged diff check\n'
  git --no-pager diff --cached --check
  run_shell_checks
  printf 'setup: C format check\n'
  clang-format --dry-run --Werror include/*.h src/*.c src/*.h tests/*.c
  run_suite debug Debug
}

run_shell_checks() {
  cd "$root"
  set -- scripts/*.sh tests/*.sh tests/integration/*.sh
  printf 'setup: shell format check\n'
  shfmt -d -i 2 "$@"
  printf 'setup: shellcheck\n'
  shellcheck "$@"
  printf 'setup: shellcheck-legibility\n'
  shellcheck-legibility check "$@"
}

run_pre_push() {
  printf 'setup: pre-push hook retired; run ./scripts/setup.sh to remove it\n'
}

resolve_hooks_dir() {
  hooks_dir="$(git -C "$root" rev-parse --git-path hooks)"
  case "$hooks_dir" in
  /*) ;;
  *) hooks_dir="$root/$hooks_dir" ;;
  esac
}

is_unmanaged_hook() {
  target="${1:?}"
  [ -L "$target" ] && return 0
  [ -e "$target" ] || return 1
  is_managed_hook "$target" && return 1
  return 0
}

is_managed_hook() {
  target="${1:?}"
  grep -Fxq "$marker" "$target" && return 0
  grep -Fxq "$legacy_marker" "$target"
}

check_hook_target() {
  target="${1:?}"
  is_unmanaged_hook "$target" || return 0
  printf 'setup: refusing to overwrite unmanaged hook: %s\n' "$target" >&2
  exit 1
}

check_hook_targets() {
  check_hook_target "$hooks_dir/pre-commit"
}

remove_managed_hook() {
  obsolete="$hooks_dir/${1:?}"
  [ -f "$obsolete" ] || return 0
  [ -L "$obsolete" ] && return 0
  is_managed_hook "$obsolete" || return 0
  rm "$obsolete"
}

remove_obsolete_hooks() {
  remove_managed_hook post-merge
  remove_managed_hook pre-push
}

write_hook() {
  name="${1:?}"
  target="$hooks_dir/$name"
  temp="$(mktemp "$target.tmp.XXXXXX")"
  cat >"$temp" <<HOOK
#!/bin/sh
$marker
set -eu
exec "\$(git rev-parse --show-toplevel)/scripts/setup.sh" "$name"
HOOK
  hook_is_current "$target" "$temp" && remove_hook_temp "$temp" && return 0
  install_hook "$target" "$temp"
}

remove_hook_temp() {
  temp="${1:?}"
  rm "$temp"
}

install_hook() {
  target="${1:?}"
  temp="${2:?}"
  chmod 755 "$temp"
  mv "$temp" "$target"
  printf 'setup: installed %s\n' "$target"
}

hook_is_current() {
  target="${1:?}"
  temp="${2:?}"
  [ -x "$target" ] || return 1
  cmp -s "$temp" "$target"
}

write_hooks() {
  write_hook pre-commit
}

run_install() {
  configured="$(git -C "$root" config --get core.hooksPath || true)"
  [ -z "$configured" ] || fail_configured_hooks_path "$configured"

  resolve_hooks_dir
  mkdir -p "$hooks_dir"
  check_hook_targets
  remove_obsolete_hooks
  write_hooks
}

fail_configured_hooks_path() {
  configured="${1:?}"
  printf 'setup: core.hooksPath is already set to %s\n' "$configured" >&2
  exit 1
}

dispatch() {
  mode="${1:?}"
  case "$mode" in
  pre-commit) run_pre_commit ;;
  pre-push) run_pre_push ;;
  shell-check) run_shell_checks ;;
  install) run_install ;;
  *)
    printf 'usage: scripts/setup.sh [install|pre-commit|pre-push|shell-check]\n' >&2
    exit 1
    ;;
  esac
}

main() {
  marker="# fs-lint managed hook"
  legacy_marker="# fs-lint-legibility managed hook"
  script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
  root="$(git -C "$script_dir/.." rev-parse --show-toplevel)"
  clang_tidy="$(resolve_clang_tidy)"
  mode="${1:-install}"
  [ "$#" -le 1 ] || mode="invalid"
  dispatch "$mode"
}

main "$@"
