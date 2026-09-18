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

clear_git_environment() {
  git_environment="$(git rev-parse --local-env-vars)"
  while IFS= read -r variable; do
    unset "$variable"
  done <<VARIABLES
$git_environment
VARIABLES
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
  hook_lines="$(wc -l <"$hook")"
  [ "$hook_lines" -eq 4 ] || fail "pre-commit is not a small wrapper"
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

write_command_stub() {
  target="${1:?}"
  printf '#!/bin/sh\nexit 0\n' >"$target"
  chmod 755 "$target"
}

prepare_preflight_path() {
  preflight_path="$test_root/preflight-stubs"
  mkdir -p "$preflight_path"
  for command_name in cmake ctest shfmt shellcheck shellcheck-legibility clang-format; do
    write_command_stub "$preflight_path/$command_name"
  done
}

assert_missing_clang_tidy_is_reported() {
  missing_clang_tidy="$test_root/missing-clang-tidy"
  prepare_preflight_path
  setup_output="$(
    PATH="$preflight_path:$PATH" CLANG_TIDY="$missing_clang_tidy" \
      "$repo/scripts/setup.sh" pre-commit 2>&1
  )" &&
    fail "missing clang-tidy was accepted"
  printf '%s' "$setup_output" | grep -Fq 'setup: missing required command:' ||
    fail "missing clang-tidy was not reported"
  printf '%s' "$setup_output" | grep -Fq 'CLANG_TIDY' ||
    fail "missing clang-tidy did not include override hint"
  ! printf '%s' "$setup_output" | grep -Fq 'debug build' ||
    fail "missing clang-tidy was reported after the build"
}

prepare_fs_lint_stub() {
  prepare_preflight_path
  write_command_stub "$preflight_path/clang-tidy"
  mkdir -p "$repo/build-hooks-debug"
  cat >"$repo/build-hooks-debug/fs-lint" <<'SCRIPT'
#!/bin/sh
printf '%s\n' "$*" >"${FS_LINT_TEST_LOG:?}"
exit "${FS_LINT_TEST_STATUS:?}"
SCRIPT
  chmod 755 "$repo/build-hooks-debug/fs-lint"
}

assert_fs_lint_status() {
  expected_status="${1:?}"
  status=0
  setup_output="$(
    PATH="$preflight_path:$PATH" CLANG_TIDY="$preflight_path/clang-tidy" \
      FS_LINT_SKIP_HOOKS=1 \
      FS_LINT_TEST_LOG="$test_root/fs-lint.log" FS_LINT_TEST_STATUS="$expected_status" \
      "$repo/scripts/setup.sh" pre-commit 2>&1
  )" || status=$?
  [ "$status" -eq "$expected_status" ] ||
    fail "expected fs-lint status $expected_status, got $status: $setup_output"
  grep -Fxq 'check --staged --config scripts/.fs-lintrc' "$test_root/fs-lint.log" ||
    fail "staged paths were not checked with the repository config"
}

assert_fs_lint_blocks_pre_commit() {
  prepare_fs_lint_stub
  assert_fs_lint_status 1
  ! printf '%s' "$setup_output" | grep -Fq 'setup: clang-tidy' ||
    fail "checks continued after fs-lint failed"
  assert_fs_lint_status 0
  printf '%s' "$setup_output" | grep -Fq 'setup: debug tests' ||
    fail "checks stopped after fs-lint passed"
}

main() {
  clear_git_environment
  setup_repo
  assert_initial_install
  assert_repeat_setup_is_quiet
  assert_managed_hook_updates
  assert_unmanaged_hook_is_preserved
  assert_symlink_hook_is_preserved
  assert_custom_hooks_path_is_rejected
  assert_missing_clang_tidy_is_reported
  assert_fs_lint_blocks_pre_commit
  printf '%s\n' "setup test: passed"
}

main
