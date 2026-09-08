#!/bin/sh
set -eu

usage() {
  printf 'usage: scripts/release.sh homebrew-pr <tap-dir> <tag>\n' >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'release: missing command: %s\n' "$1" >&2
    exit 1
  }
}

require_gh_token() {
  [ -n "${GH_TOKEN:-}" ] || {
    printf 'release: GH_TOKEN is required\n' >&2
    exit 1
  }
}

require_version_tag() {
  tag="${1:?}"
  version="${tag#v}"

  [ "$version" != "$tag" ] || {
    printf 'release: tag must start with v: %s\n' "$tag" >&2
    exit 1
  }
}

require_release_commands() {
  require_command brew
  require_command gh
  require_command git
  require_command ruby
}

require_tap_dir() {
  tap_dir="${1:?}"

  [ -d "$tap_dir" ] || {
    printf 'release: missing tap directory: %s\n' "$tap_dir" >&2
    exit 1
  }
}

require_tap_script() {
  tap_dir="${1:?}"
  script="${2:?}"

  [ -x "$tap_dir/$script" ] || {
    printf 'release: missing tap script: %s\n' "$script" >&2
    exit 1
  }
}

require_tap_scripts() {
  tap_dir="${1:?}"

  require_tap_script "$tap_dir" scripts/update-formula
  require_tap_script "$tap_dir" scripts/new-formula
}

canonical_dir() {
  path="${1:?}"

  CDPATH='' cd -- "$path" && pwd
}

script_dir() {
  CDPATH='' cd -- "$(dirname -- "$0")" && pwd
}

write_package() {
  tap_dir="${1:?}"
  version="${2:?}"
  package_path="$tap_dir/brews/fs-lint.json"

  package_metadata_json "$version" >"$package_path"
}

write_readme_section() {
  printf '%s\n' \
    '### [fs-lint](https://github.com/yowainwright/fs-lint)' \
    '' \
    'Enforce project file and folder structure.' \
    '' \
    "Install [fs-lint](Formula/fs-lint.rb) | \`Formula/fs-lint.rb\`" \
    '' \
    '```bash' \
    'brew install yowainwright/tap/fs-lint' \
    '```' \
    '' \
    'Usage' \
    '' \
    '```bash' \
    'fs-lint check --staged' \
    '```' \
    '' \
    '---'
}

fail_update_readme() {
  section_file="${1:?}"
  temp="${2:?}"

  rm -f "$section_file" "$temp"
  printf 'release: README.md missing formulas markers\n' >&2
  exit 1
}

finish_update_readme() {
  section_file="${1:?}"
  temp="${2:?}"
  readme="${3:?}"

  rm -f "$section_file"
  mv "$temp" "$readme"
}

update_readme() {
  tap_dir="${1:?}"
  readme="$tap_dir/README.md"
  section_file="$(mktemp "$readme.section.XXXXXX")"
  temp="$(mktemp "$readme.tmp.XXXXXX")"
  update_script="$(script_dir)/update-tap-readme"

  write_readme_section >"$section_file"
  "$update_script" "$readme" "$section_file" "$temp" ||
    fail_update_readme "$section_file" "$temp"
  finish_update_readme "$section_file" "$temp" "$readme"
}

json_true() {
  printf 'true'
}

package_metadata_json() {
  version="${1:?}"
  is_managed="$(json_true)"
  show_in_readme="$(json_true)"

  printf '%s\n' \
    '{' \
    '  "name": "fs-lint",' \
    '  "class_name": "FsLint",' \
    '  "command": "fs-lint",' \
    '  "repo": "yowainwright/fs-lint",' \
    '  "desc": "Enforce project file and folder structure",' \
    '  "homepage": "https://github.com/yowainwright/fs-lint",' \
    '  "license": "MIT",' \
    "  \"version\": \"$version\"," \
    '  "asset_prefix": "fs-lint",' \
    "  \"managed\": $is_managed," \
    "  \"readme\": $show_in_readme" \
    '}'
}

update_formula() {
  tap_dir="${1:?}"
  version="${2:?}"

  cd "$tap_dir"
  formula_script=scripts/new-formula
  [ -f Formula/fs-lint.rb ] && formula_script=scripts/update-formula
  "$formula_script" fs-lint "$version"
}

validate_formula() {
  tap_dir="${1:?}"

  cd "$tap_dir"
  brew tap yowainwright/tap "$PWD"
  installed_formula_dir="$(brew --repository yowainwright/tap)/Formula"
  mkdir -p "$installed_formula_dir"
  cp Formula/fs-lint.rb "$installed_formula_dir/fs-lint.rb"
  brew audit --strict --online yowainwright/tap/fs-lint
  brew install yowainwright/tap/fs-lint
  brew test yowainwright/tap/fs-lint
}

open_pull_request() {
  tap_dir="${1:?}"
  tag="${2:?}"
  tap_repository="${TAP_REPOSITORY:-yowainwright/homebrew-tap}"
  branch="fs-lint-$tag"

  cd "$tap_dir"
  prepare_pr_branch "$branch"
  stage_release_files
  git diff --cached --quiet && return_current_formula && return 0
  publish_pr_branch "$branch" "$tag"
  open_or_show_pr "$tap_repository" "$branch" "$tag"
}

prepare_pr_branch() {
  branch="${1:?}"

  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git checkout -B "$branch"
}

stage_release_files() {
  git add \
    Formula/fs-lint.rb \
    brews/fs-lint.json \
    README.md
}

return_current_formula() {
  printf 'release: formula is already current\n'
  return 0
}

publish_pr_branch() {
  branch="${1:?}"
  tag="${2:?}"

  git commit -m "fs-lint $tag"
  git push --force-with-lease origin "$branch"
}

open_or_show_pr() {
  tap_repository="${1:?}"
  branch="${2:?}"
  tag="${3:?}"

  pr_url="$(
    gh pr list \
      --repo "$tap_repository" \
      --head "yowainwright:$branch" \
      --state open \
      --json url \
      --jq '.[0].url // ""'
  )"

  [ -n "$pr_url" ] && return_existing_pr "$pr_url" && return 0

  create_pull_request "$tap_repository" "$branch" "$tag"
}

return_existing_pr() {
  pr_url="${1:?}"

  printf '%s\n' "$pr_url"
  return 0
}

create_pull_request() {
  tap_repository="${1:?}"
  branch="${2:?}"
  tag="${3:?}"
  pr_body="Updates fs-lint to $tag from the published binary archives."

  gh pr create \
    --repo "$tap_repository" \
    --base main \
    --head "yowainwright:$branch" \
    --title "fs-lint $tag" \
    --body "$pr_body"
}

run_homebrew_pr() {
  tap_dir="${1:?}"
  tag="${2:?}"
  version="${tag#v}"

  require_version_tag "$tag"
  require_gh_token
  require_release_commands
  require_tap_dir "$tap_dir"
  tap_dir="$(canonical_dir "$tap_dir")"
  require_tap_scripts "$tap_dir"

  write_package "$tap_dir" "$version"
  update_readme "$tap_dir"
  update_formula "$tap_dir" "$version"
  validate_formula "$tap_dir"
  open_pull_request "$tap_dir" "$tag"
}

main() {
  [ "$#" -eq 3 ] || usage

  case "$1" in
  homebrew-pr) run_homebrew_pr "$2" "$3" ;;
  *) usage ;;
  esac
}

main "$@"
