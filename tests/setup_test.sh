#!/bin/sh
set -eu

source_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/fs-lint-setup.XXXXXX")"
repo="$test_root/repo"
trap 'rm -rf "$test_root"' EXIT INT TERM

fail() {
  printf 'setup test: %s\n' "$1" >&2
  exit 1
}

run_setup() {
  label="${1:?}"
  setup_output="$("$repo/scripts/setup.sh" 2>&1)" ||
    fail "$label failed: $setup_output"
}

reject_setup() {
  label="${1:?}"
  setup_output="$("$repo/scripts/setup.sh" 2>&1)" &&
    fail "$label was accepted"
  return 0
}

setup_repo() {
  mkdir -p "$repo/scripts"
  cp "$source_root/scripts/setup.sh" "$repo/scripts/setup.sh"
  git -C "$repo" init -q
  marker="# fs-lint managed hook"
  legacy_marker="# fs-lint-legibility managed hook"
}

assert_initial_install() {
  printf '#!/bin/sh\n%s\nexit 0\n' "$legacy_marker" >"$repo/.git/hooks/post-merge"
  printf '#!/bin/sh\n%s\nexit 0\n' "$marker" >"$repo/.git/hooks/pre-push"
  run_setup "initial setup"
  [ ! -e "$repo/.git/hooks/post-merge" ] ||
    fail "obsolete managed hook was not removed"
  [ ! -e "$repo/.git/hooks/pre-push" ] ||
    fail "pre-push hook was not removed"
  hook="$repo/.git/hooks/pre-commit"
  [ -x "$hook" ] || fail "pre-commit is not executable"
  [ "$(wc -l <"$hook")" -eq 4 ] || fail "pre-commit is not a small wrapper"
}

assert_repeat_setup_is_quiet() {
  run_setup "repeat setup"
  [ -z "$setup_output" ] || fail "repeat setup is not quiet"
}

assert_managed_hook_updates() {
  printf '#!/bin/sh\n%s\nexit 1\n' "$marker" >"$repo/.git/hooks/pre-commit"
  run_setup "managed hook update"
  grep -Fq 'scripts/setup.sh" "pre-commit"' "$repo/.git/hooks/pre-commit" ||
    fail "managed hook was not updated"
}

assert_unmanaged_hook_is_preserved() {
  printf '#!/bin/sh\nexit 0\n' >"$repo/.git/hooks/pre-commit"
  reject_setup "unmanaged hook"
  grep -Fq 'exit 0' "$repo/.git/hooks/pre-commit" ||
    fail "unmanaged hook was changed"
}

assert_symlink_hook_is_preserved() {
  external="$test_root/external-hook"
  printf '%s\n' "$marker" >"$external"
  rm "$repo/.git/hooks/pre-commit"
  ln -s "$external" "$repo/.git/hooks/pre-commit"
  reject_setup "symlink hook"
  [ -L "$repo/.git/hooks/pre-commit" ] || fail "symlink hook was replaced"
}

assert_custom_hooks_path_is_rejected() {
  git -C "$repo" config core.hooksPath custom-hooks
  reject_setup "custom hook path"
}

assert_missing_clang_tidy_is_reported() {
  missing_clang_tidy="$test_root/missing-clang-tidy"
  setup_output="$(CLANG_TIDY="$missing_clang_tidy" "$repo/scripts/setup.sh" pre-commit 2>&1)" &&
    fail "missing clang-tidy was accepted"
  printf '%s' "$setup_output" | grep -Fq 'setup: missing required command:' ||
    fail "missing clang-tidy was not reported"
  printf '%s' "$setup_output" | grep -Fq 'CLANG_TIDY' ||
    fail "missing clang-tidy did not include override hint"
  ! printf '%s' "$setup_output" | grep -Fq 'debug build' ||
    fail "missing clang-tidy was reported after the build"
}

main() {
  setup_repo
  assert_initial_install
  assert_repeat_setup_is_quiet
  assert_managed_hook_updates
  assert_unmanaged_hook_is_preserved
  assert_symlink_hook_is_preserved
  assert_custom_hooks_path_is_rejected
  assert_missing_clang_tidy_is_reported
  printf '%s\n' "setup test: passed"
}

main
