execute_process(
  COMMAND git rev-parse --local-env-vars
  RESULT_VARIABLE status OUTPUT_VARIABLE local_environment
)
if(NOT status EQUAL 0)
  message(FATAL_ERROR "could not read Git's local environment variables")
endif()
string(REPLACE "\n" ";" local_environment "${local_environment}")
foreach(variable IN LISTS local_environment)
  if(NOT variable STREQUAL "")
    unset(ENV{${variable}})
  endif()
endforeach()
set(ENV{GIT_CONFIG_NOSYSTEM} "1")
set(ENV{GIT_CONFIG_GLOBAL} "${TEST_ROOT}/gitconfig")
set(ENV{GIT_TEMPLATE_DIR} "${TEST_ROOT}/git-template")

file(REMOVE_RECURSE "${TEST_ROOT}")
file(MAKE_DIRECTORY "${TEST_ROOT}/git-template" "${TEST_ROOT}/git-hooks")
file(WRITE "${TEST_ROOT}/gitconfig" "")
set(caller "${TEST_ROOT}/caller")
set(target "${TEST_ROOT}/target")

function(run_git root)
  execute_process(
    COMMAND git -C "${root}" -c commit.gpgsign=false
      -c "core.hooksPath=${TEST_ROOT}/git-hooks"
      -c user.name=fs-lint -c user.email=fs-lint@example.test ${ARGN}
    RESULT_VARIABLE status OUTPUT_VARIABLE output ERROR_VARIABLE error
  )
  if(NOT status EQUAL 0)
    message(FATAL_ERROR "git fixture failed: ${output}${error}")
  endif()
endfunction()

foreach(root IN ITEMS "${caller}" "${target}")
  file(MAKE_DIRECTORY "${root}/src")
  file(WRITE "${root}/fs-lint.json" "{\"version\":1,\"newFiles\":{}}")
  run_git("${root}" -c init.defaultBranch=main init -q)
  run_git("${root}" add fs-lint.json)
  run_git("${root}" commit -qm initial)
endforeach()

file(WRITE "${caller}/src/caller.c" "caller\n")
run_git("${caller}" add src/caller.c)
run_git("${caller}" commit -qm caller)
file(WRITE "${caller}/src/caller-staged.c" "caller staged\n")
run_git("${caller}" add src/caller-staged.c)

file(WRITE "${target}/src/target-committed.c" "target committed\n")
run_git("${target}" add src/target-committed.c)
run_git("${target}" commit -qm target)
file(WRITE "${target}/src/allowed.c" "allowed\n")
file(WRITE "${target}/fs-lint.json"
  "{\"version\":1,\"newFiles\":{\"allow\":[\"src/allowed.c\"]}}")
run_git("${target}" add fs-lint.json src/allowed.c)
configure_file("${target}/.git/index" "${target}/.git/alternate-index" COPYONLY)
file(WRITE "${target}/src/target-staged.c" "target staged\n")
run_git("${target}" add src/target-staged.c)
# Staged checks must use the target index's policy, not this worktree policy.
file(WRITE "${target}/fs-lint.json" "{\"version\":1,\"newFiles\":{}}")

function(check_from_caller root mode path)
  execute_process(
    COMMAND "${FS_LINT}" check ${mode} --root "${root}"
    WORKING_DIRECTORY "${caller}"
    RESULT_VARIABLE status OUTPUT_VARIABLE output ERROR_VARIABLE error
  )
  set(expected "${path}: error files/new: new file is not allowed by configuration\n")
  if(NOT status EQUAL 1 OR NOT output STREQUAL expected OR NOT error STREQUAL "")
    message(FATAL_ERROR "${mode} read the wrong repository or policy (${status}): ${output}${error}")
  endif()
endfunction()

foreach(variable IN ITEMS GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY)
  set(value "${caller}/.git")
  if(variable STREQUAL "GIT_WORK_TREE")
    set(value "${caller}")
  elseif(variable STREQUAL "GIT_INDEX_FILE")
    set(value "${caller}/.git/index")
  elseif(variable STREQUAL "GIT_OBJECT_DIRECTORY")
    set(value "${caller}/.git/objects")
  endif()
  set(ENV{${variable}} "${value}")
  check_from_caller("${target}" "--staged" "src/target-staged.c")
  check_from_caller("${target}/src" "--base;HEAD~1" "src/target-committed.c")
  unset(ENV{${variable}})
endforeach()

set(ENV{GIT_DIR} ".git")
set(ENV{GIT_WORK_TREE} ".")
set(ENV{GIT_INDEX_FILE} ".git/index")
check_from_caller("../target" "--staged" "src/target-staged.c")
check_from_caller("../target/src" "--base;HEAD~1" "src/target-committed.c")

set(non_repo "${TEST_ROOT}/not-repo")
file(MAKE_DIRECTORY "${non_repo}")
set(ENV{GIT_CEILING_DIRECTORIES} "${TEST_ROOT}")
execute_process(
  COMMAND "${FS_LINT}" check --staged --root "${non_repo}"
  WORKING_DIRECTORY "${caller}"
  RESULT_VARIABLE status OUTPUT_VARIABLE output ERROR_VARIABLE error
)
if(NOT status EQUAL 2 OR NOT output MATCHES "error input/invalid: git diff failed")
  message(FATAL_ERROR "foreign environment hid a non-repository root: ${output}${error}")
endif()
unset(ENV{GIT_CEILING_DIRECTORIES})

# A same-repository hook must retain its alternate index, including relative paths.
set(ENV{GIT_INDEX_FILE} ".git/alternate-index")
file(CREATE_LINK "${target}" "${TEST_ROOT}/target-link" SYMBOLIC)
foreach(root IN ITEMS "." "${target}" "${target}/src" "${TEST_ROOT}/target-link")
  execute_process(
    COMMAND "${FS_LINT}" check --staged --root "${root}"
    WORKING_DIRECTORY "${target}"
    RESULT_VARIABLE status OUTPUT_VARIABLE output ERROR_VARIABLE error
  )
  if(NOT status EQUAL 0 OR NOT output STREQUAL "" OR NOT error STREQUAL "")
    message(FATAL_ERROR "same-repository alternate index was lost: ${output}${error}")
  endif()
endforeach()

unset(ENV{GIT_DIR})
unset(ENV{GIT_WORK_TREE})
unset(ENV{GIT_INDEX_FILE})
set(worktree "${TEST_ROOT}/worktree")
run_git("${target}" worktree add --detach "${worktree}")
file(WRITE "${worktree}/src/worktree-staged.c" "worktree staged\n")
run_git("${worktree}" add src/worktree-staged.c)
# Linked worktrees share objects, but must keep their indexes and policies separate.
set(ENV{GIT_DIR} "${target}/.git")
set(ENV{GIT_WORK_TREE} "${target}")
set(ENV{GIT_INDEX_FILE} "${target}/.git/alternate-index")
check_from_caller("${worktree}" "--staged" "src/worktree-staged.c")
