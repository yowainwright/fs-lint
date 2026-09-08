unset(ENV{GIT_DIR})
unset(ENV{GIT_WORK_TREE})
unset(ENV{GIT_INDEX_FILE})
set(ENV{GIT_CONFIG_NOSYSTEM} "1")
set(ENV{GIT_CONFIG_GLOBAL} "${TEST_ROOT}/gitconfig")
set(ENV{GIT_TEMPLATE_DIR} "${TEST_ROOT}/git-template")

function(run_git)
  execute_process(
    COMMAND
      git
      -c commit.gpgsign=false
      -c "core.hooksPath=${TEST_ROOT}/git-hooks"
      ${ARGN}
    WORKING_DIRECTORY "${TEST_ROOT}"
    RESULT_VARIABLE status
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
  )
  if(NOT status EQUAL 0)
    message(FATAL_ERROR "git command failed: ${output}${error}")
  endif()
endfunction()

file(REMOVE_RECURSE "${TEST_ROOT}")
file(
  MAKE_DIRECTORY
  "${TEST_ROOT}/src"
  "${TEST_ROOT}/git-hooks"
  "${TEST_ROOT}/git-template"
)
file(WRITE "${TEST_ROOT}/gitconfig" "")
file(
  WRITE
  "${TEST_ROOT}/fs-lint.json"
  "{\"version\":1,\"newFiles\":{}}"
)
file(WRITE "${TEST_ROOT}/src/existing.c" "int existing(void) { return 1; }\n")
file(WRITE "${TEST_ROOT}/src/removable.c" "int removable(void) { return 1; }\n")

run_git(-c init.defaultBranch=main init -q)
run_git(add .)
run_git(-c user.name=fs-lint -c user.email=fs-lint@example.test commit -qm initial)

file(WRITE "${TEST_ROOT}/src/existing.c" "int existing(void) { return 2; }\n")
run_git(add src/existing.c)
run_git(rm -q src/removable.c)

execute_process(
  COMMAND "${FS_LINT}" check --staged --root "${TEST_ROOT}"
  RESULT_VARIABLE unchanged_status
  OUTPUT_VARIABLE unchanged_output
  ERROR_VARIABLE unchanged_error
)

if(NOT unchanged_status EQUAL 0)
  message(FATAL_ERROR "expected modified and deleted paths to pass: ${unchanged_error}")
endif()

if(NOT unchanged_output STREQUAL "" OR NOT unchanged_error STREQUAL "")
  message(FATAL_ERROR "expected no diagnostic for modified and deleted paths")
endif()

run_git(-c user.name=fs-lint -c user.email=fs-lint@example.test commit -qam maintenance)

file(WRITE "${TEST_ROOT}/src/new-helper.c" "int helper(void) { return 1; }\n")
run_git(add src/new-helper.c)

execute_process(
  COMMAND "${FS_LINT}" check --staged --root "${TEST_ROOT}"
  RESULT_VARIABLE status
  OUTPUT_VARIABLE output
  ERROR_VARIABLE error
)

set(
  expected
  "src/new-helper.c: error files/new: new file is not allowed by configuration\n"
)

if(NOT status EQUAL 1)
  message(FATAL_ERROR "expected staged violation exit code 1: ${error}")
endif()

if(NOT output STREQUAL expected)
  message(FATAL_ERROR "unexpected staged output: ${output}")
endif()

if(NOT error STREQUAL "")
  message(FATAL_ERROR "expected empty staged stderr: ${error}")
endif()

run_git(-c user.name=fs-lint -c user.email=fs-lint@example.test commit -qm addition)

execute_process(
  COMMAND "${FS_LINT}" check --base HEAD~1 --root "${TEST_ROOT}"
  RESULT_VARIABLE base_status
  OUTPUT_VARIABLE base_output
  ERROR_VARIABLE base_error
)

if(NOT base_status EQUAL 1)
  message(FATAL_ERROR "expected base violation exit code 1: ${base_error}")
endif()

if(NOT base_output STREQUAL expected)
  message(FATAL_ERROR "unexpected base output: ${base_output}")
endif()

if(NOT base_error STREQUAL "")
  message(FATAL_ERROR "expected empty base stderr: ${base_error}")
endif()

run_git(branch comparison HEAD~1)
run_git(checkout -q comparison)
run_git(rm -q src/existing.c)
run_git(-c user.name=fs-lint -c user.email=fs-lint@example.test commit -qm deletion)
run_git(checkout -q main)

execute_process(
  COMMAND "${FS_LINT}" check --base comparison --root "${TEST_ROOT}"
  RESULT_VARIABLE diverged_status
  OUTPUT_VARIABLE diverged_output
  ERROR_VARIABLE diverged_error
)

if(NOT diverged_status EQUAL 1)
  message(FATAL_ERROR "expected diverged-base violation: ${diverged_error}")
endif()

if(NOT diverged_output STREQUAL expected)
  message(FATAL_ERROR "unexpected diverged-base output: ${diverged_output}")
endif()

if(NOT diverged_error STREQUAL "")
  message(FATAL_ERROR "expected empty diverged-base stderr: ${diverged_error}")
endif()

run_git(mv src/existing.c src/renamed.c)

execute_process(
  COMMAND "${FS_LINT}" check --staged --root "${TEST_ROOT}"
  RESULT_VARIABLE rename_status
  OUTPUT_VARIABLE rename_output
  ERROR_VARIABLE rename_error
)

set(
  expected_rename
  "src/renamed.c: error files/new: new file is not allowed by configuration\n"
)

if(NOT rename_status EQUAL 1)
  message(FATAL_ERROR "expected renamed path violation: ${rename_error}")
endif()

if(NOT rename_output STREQUAL expected_rename)
  message(FATAL_ERROR "unexpected renamed path output: ${rename_output}")
endif()

if(NOT rename_error STREQUAL "")
  message(FATAL_ERROR "expected empty renamed path stderr: ${rename_error}")
endif()

run_git(-c user.name=fs-lint -c user.email=fs-lint@example.test commit -qm rename)
run_git(config diff.relative true)
file(WRITE "${TEST_ROOT}/outside-root.c" "int outside(void) { return 1; }\n")
run_git(add outside-root.c)

execute_process(
  COMMAND "${FS_LINT}" check --staged --root "${TEST_ROOT}/src"
  RESULT_VARIABLE relative_status
  OUTPUT_VARIABLE relative_output
  ERROR_VARIABLE relative_error
)

set(
  expected_relative
  "outside-root.c: error files/new: new file is not allowed by configuration\n"
)

if(NOT relative_status EQUAL 1)
  message(FATAL_ERROR "expected repository-wide staged violation: ${relative_error}")
endif()

if(NOT relative_output STREQUAL expected_relative)
  message(FATAL_ERROR "unexpected repository-relative output: ${relative_output}")
endif()

if(NOT relative_error STREQUAL "")
  message(FATAL_ERROR "expected empty repository-relative stderr: ${relative_error}")
endif()

run_git(-c user.name=fs-lint -c user.email=fs-lint@example.test commit -qm outside)

execute_process(
  COMMAND "${FS_LINT}" check --base HEAD~1 --root "${TEST_ROOT}/src"
  RESULT_VARIABLE relative_base_status
  OUTPUT_VARIABLE relative_base_output
  ERROR_VARIABLE relative_base_error
)

if(NOT relative_base_status EQUAL 1)
  message(FATAL_ERROR "expected repository-wide base violation: ${relative_base_error}")
endif()

if(NOT relative_base_output STREQUAL expected_relative)
  message(FATAL_ERROR "unexpected base repository-relative output: ${relative_base_output}")
endif()

if(NOT relative_base_error STREQUAL "")
  message(FATAL_ERROR "expected empty base repository-relative stderr")
endif()

set(submodule_source "${TEST_ROOT}-submodule-source")
file(REMOVE_RECURSE "${submodule_source}")
file(MAKE_DIRECTORY "${submodule_source}")
run_git(-C "${submodule_source}" -c init.defaultBranch=main init -q)
file(WRITE "${submodule_source}/library.c" "int library(void) { return 1; }\n")
run_git(-C "${submodule_source}" add library.c)
run_git(
  -C "${submodule_source}"
  -c user.name=fs-lint
  -c user.email=fs-lint@example.test
  commit -qm initial
)

run_git(
  -c protocol.file.allow=always
  submodule add -q "${submodule_source}" deps/existing
)
run_git(-c user.name=fs-lint -c user.email=fs-lint@example.test commit -qam submodule)
run_git(config diff.ignoreSubmodules all)
run_git(
  -c protocol.file.allow=always
  submodule add -q "${submodule_source}" deps/new-module
)

execute_process(
  COMMAND "${FS_LINT}" check --staged --root "${TEST_ROOT}"
  RESULT_VARIABLE submodule_status
  OUTPUT_VARIABLE submodule_output
  ERROR_VARIABLE submodule_error
)

set(
  expected_submodule
  "deps/new-module: error files/new: new file is not allowed by configuration\n"
)

if(NOT submodule_status EQUAL 1)
  message(FATAL_ERROR "expected staged submodule violation: ${submodule_error}")
endif()

if(NOT submodule_output STREQUAL expected_submodule)
  message(FATAL_ERROR "unexpected staged submodule output: ${submodule_output}")
endif()

if(NOT submodule_error STREQUAL "")
  message(FATAL_ERROR "expected empty staged submodule stderr: ${submodule_error}")
endif()

run_git(-c user.name=fs-lint -c user.email=fs-lint@example.test commit -qam addition)

execute_process(
  COMMAND "${FS_LINT}" check --base HEAD~1 --root "${TEST_ROOT}"
  RESULT_VARIABLE submodule_base_status
  OUTPUT_VARIABLE submodule_base_output
  ERROR_VARIABLE submodule_base_error
)

if(NOT submodule_base_status EQUAL 1)
  message(FATAL_ERROR "expected base submodule violation: ${submodule_base_error}")
endif()

if(NOT submodule_base_output STREQUAL expected_submodule)
  message(FATAL_ERROR "unexpected base submodule output: ${submodule_base_output}")
endif()

if(NOT submodule_base_error STREQUAL "")
  message(FATAL_ERROR "expected empty base submodule stderr: ${submodule_base_error}")
endif()

file(WRITE "${TEST_ROOT}/src/staged-helper.c" "int staged_helper(void) { return 1; }\n")
run_git(add src/staged-helper.c)
file(
  WRITE
  "${TEST_ROOT}/fs-lint.json"
  "{\"version\":1,\"newFiles\":{\"default\":\"deny\",\"allow\":[\"src/**/*.c\"]}}"
)
run_git(add fs-lint.json)
file(
  WRITE
  "${TEST_ROOT}/fs-lint.json"
  "{\"version\":1,\"newFiles\":{\"default\":\"deny\"}}"
)

execute_process(
  COMMAND "${FS_LINT}" check --staged --root "${TEST_ROOT}"
  RESULT_VARIABLE staged_config_status
  OUTPUT_VARIABLE staged_config_output
  ERROR_VARIABLE staged_config_error
)

if(NOT staged_config_status EQUAL 0)
  message(FATAL_ERROR "expected staged config to allow staged path: ${staged_config_error}")
endif()

if(NOT staged_config_output STREQUAL "" OR NOT staged_config_error STREQUAL "")
  message(FATAL_ERROR "expected no diagnostic for staged config")
endif()

set(non_repo "${TEST_ROOT}-not-repo")
get_filename_component(non_repo_parent "${non_repo}" DIRECTORY)
file(REMOVE_RECURSE "${non_repo}")
file(MAKE_DIRECTORY "${non_repo}")
file(
  WRITE
  "${non_repo}/fs-lint.json"
  "{\"version\":1,\"newFiles\":{}}"
)

execute_process(
  COMMAND
    "${CMAKE_COMMAND}"
    -E env
    "GIT_CEILING_DIRECTORIES=${non_repo_parent}"
    "${FS_LINT}"
    check
    --staged
    --root
    "${non_repo}"
  RESULT_VARIABLE git_error_status
  OUTPUT_VARIABLE git_error_output
  ERROR_VARIABLE git_error
)

if(NOT git_error_status EQUAL 2)
  message(FATAL_ERROR "expected non-repository exit code 2")
endif()

if(NOT git_error_output MATCHES "error input/invalid: git diff failed")
  message(FATAL_ERROR "unexpected non-repository output: ${git_error_output}")
endif()

if(NOT git_error STREQUAL "")
  message(FATAL_ERROR "expected empty non-repository stderr: ${git_error}")
endif()
