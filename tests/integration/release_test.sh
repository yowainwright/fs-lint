#!/bin/sh
set -eu

source_root="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/fs-lint-release.XXXXXX")"
tap="$test_root/homebrew-tap"
bin="$test_root/bin"
command_log="$test_root/commands.log"
release_output="$test_root/release.out"
trap 'rm -rf "$test_root"' EXIT INT TERM

fail() {
  printf 'release test: %s\n' "$1" >&2
  exit 1
}

write_tap_readme() {
  cat >"$tap/README.md" <<'README'
# Homebrew Tap

<!-- formulas:start -->
README
  write_diu_readme_section
  cat >>"$tap/README.md" <<'README'
<!-- formulas:end -->
README
}

write_diu_readme_section() {
  cat >>"$tap/README.md" <<'README'
### [diu](https://github.com/yowainwright/diu)

Install [diu](Formula/diu.rb) | `Formula/diu.rb`

```bash
brew install yowainwright/tap/diu
```

Usage

```bash
diu setup
```

---
README
}

write_tap_scripts() {
  cat >"$tap/scripts/update-formula" <<'SCRIPT'
#!/bin/sh
set -eu
printf '%s\n' "${0##*/}" >>"${COMMAND_LOG:?}"
[ "$1" = "fs-lint" ] || exit 2
[ "$2" = "0.2.0" ] || exit 2
grep -Fq "### [fs-lint](https://github.com/yowainwright/fs-lint)" README.md || exit 1
mkdir -p Formula
printf "%s\n" "class FsLint < Formula" "end" >Formula/fs-lint.rb
SCRIPT
  cp "$tap/scripts/update-formula" "$tap/scripts/new-formula"
  chmod +x "$tap/scripts/new-formula" "$tap/scripts/update-formula"
}

write_brew_stub() {
  cat >"$bin/brew" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
  chmod +x "$bin/brew"
}

write_git_stub() {
  cat >"$bin/git" <<'SCRIPT'
#!/bin/sh
printf 'git %s\n' "$*" >>"${COMMAND_LOG:?}"
case "$1" in
diff) exit "${STUB_DIFF_STATUS:-1}" ;;
commit) exit "${STUB_COMMIT_STATUS:-0}" ;;
esac
exit 0
SCRIPT
  chmod +x "$bin/git"
}

write_gh_stub() {
  cat >"$bin/gh" <<'SCRIPT'
#!/bin/sh
printf 'gh %s\n' "$*" >>"${COMMAND_LOG:?}"
case "${1:-} ${2:-}" in
"pr list") printf '%s\n' "${STUB_PR_URL:-}"; exit 0 ;;
esac
printf "%s\n" "https://github.com/yowainwright/homebrew-tap/pull/1"
SCRIPT
  chmod +x "$bin/gh"
}

write_command_stubs() {
  write_brew_stub
  write_git_stub
  write_gh_stub
}

setup_tap() {
  mkdir -p "$tap/scripts" "$tap/brews" "$bin"
  write_tap_readme
  write_tap_scripts
  write_command_stubs
}

run_release() {
  : >"$command_log"
  PATH="$bin:$PATH" GH_TOKEN=test COMMAND_LOG="$command_log" \
    STUB_DIFF_STATUS="${1:?}" STUB_PR_URL="${2-}" \
    TAP_REPOSITORY=yowainwright/homebrew-tap \
    "$source_root/scripts/release.sh" homebrew-pr "$tap" v0.2.0 >"$release_output"
}

assert_release_updates_readme() {
  run_release 1 ''
  assert_command 'new-formula'
  assert_no_command 'update-formula'
  grep -Fq "### [fs-lint](https://github.com/yowainwright/fs-lint)" "$tap/README.md" ||
    fail "README section was not written"
  grep -Fq "Install [fs-lint](Formula/fs-lint.rb) | \`Formula/fs-lint.rb\`" "$tap/README.md" ||
    fail "README formula link was not written"
  assert_command 'git commit '
  assert_command 'git push '
  assert_command 'gh pr create '
}

assert_command() {
  grep -Fq "$1" "$command_log" || fail "missing command: $1"
}

assert_no_command() {
  ! grep -Fq "$1" "$command_log" || fail "unexpected command: $1"
}

assert_current_formula_stops() {
  STUB_COMMIT_STATUS=1 run_release 0 ''
  assert_command 'update-formula'
  assert_no_command 'new-formula'
  grep -Fq 'formula is already current' "$release_output" || fail 'missing current message'
  assert_no_command 'git commit '
  assert_no_command 'git push '
  assert_no_command 'gh pr '
}

assert_existing_pr_is_reused() {
  existing_url='https://github.com/yowainwright/homebrew-tap/pull/42'
  run_release 1 "$existing_url"
  grep -Fxq "$existing_url" "$release_output" || fail 'missing existing PR URL'
  assert_command 'git commit '
  assert_command 'git push '
  assert_command 'gh pr list '
  assert_no_command 'gh pr create '
}

main() {
  setup_tap
  assert_release_updates_readme
  assert_current_formula_stops
  assert_existing_pr_is_reused
  printf '%s\n' "release test: passed"
}

main
