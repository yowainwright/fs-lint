unset(ENV{GIT_DIR})
unset(ENV{GIT_WORK_TREE})
unset(ENV{GIT_INDEX_FILE})
set(ENV{GIT_CONFIG_NOSYSTEM} "1")
set(ENV{GIT_CONFIG_GLOBAL} "${TEST_ROOT}/gitconfig")
set(ENV{GIT_TEMPLATE_DIR} "${TEST_ROOT}/git-template")

file(REMOVE_RECURSE "${TEST_ROOT}")
file(MAKE_DIRECTORY "${TEST_ROOT}/git-template" "${TEST_ROOT}/git-hooks")
file(WRITE "${TEST_ROOT}/gitconfig" "")
set(source "${TEST_ROOT}/checkout")
file(MAKE_DIRECTORY "${source}")
configure_file("${PROJECT_SOURCE_ROOT}/cmake/version.cmake" "${source}/version.cmake" COPYONLY)
file(WRITE "${source}/CMakeLists.txt" [=[
cmake_minimum_required(VERSION 3.20)
include(version.cmake)
project(version_fixture VERSION ${FS_LINT_PROJECT_VERSION} LANGUAGES NONE)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/resolved-version"
  "${FS_LINT_VERSION}|${PROJECT_VERSION}")
]=])

function(run_git)
  execute_process(
    COMMAND git -C "${source}" -c commit.gpgsign=false -c tag.gpgsign=false
      -c "core.hooksPath=${TEST_ROOT}/git-hooks"
      -c user.name=fs-lint -c user.email=fs-lint@example.test ${ARGN}
    RESULT_VARIABLE status OUTPUT_VARIABLE output ERROR_VARIABLE error
  )
  if(NOT status EQUAL 0)
    message(FATAL_ERROR "git fixture failed: ${output}${error}")
  endif()
endfunction()

function(assert_version root expected)
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -S "${root}" -B "${root}/build"
      -UFS_LINT_VERSION ${ARGN}
    RESULT_VARIABLE status OUTPUT_VARIABLE output ERROR_VARIABLE error
  )
  if(NOT status EQUAL 0)
    message(FATAL_ERROR "version configure failed: ${output}${error}")
  endif()
  file(READ "${root}/build/resolved-version" version)
  if(NOT version MATCHES "^${expected}$")
    message(FATAL_ERROR "expected ${expected}, received ${version}")
  endif()
endfunction()

# A source directory inside another checkout must not inherit its parent's tags.
assert_version("${source}" "0.0.0-unknown\\|0.0.0")
run_git(-c init.defaultBranch=main init -q)
run_git(add CMakeLists.txt version.cmake)
run_git(commit -qm initial)
assert_version("${source}" "0.0.0-g[0-9a-f]+\\|0.0.0")

run_git(tag v3.4.5)
assert_version("${source}" "3.4.5\\|3.4.5")
file(WRITE "${source}/change" "development\n")
run_git(add change)
run_git(commit -qm development)
assert_version("${source}" "3.4.5-1-g[0-9a-f]+\\|3.4.5")
file(APPEND "${source}/change" "dirty\n")
assert_version("${source}" "3.4.5-1-g[0-9a-f]+-dirty\\|3.4.5")
run_git(add change)
run_git(commit -qm next-release)
run_git(tag -a v3.4.6 -m release)
assert_version("${source}" "3.4.6\\|3.4.6")

# The workflow's explicit tag version takes precedence over checkout metadata.
assert_version("${source}" "4.5.6\\|4.5.6" -DFS_LINT_VERSION=4.5.6)
assert_version("${source}" "3.4.6\\|3.4.6")

# Use the same Git archive option as the release workflow; no Git metadata ships.
run_git(archive --format=tar --prefix=source/
  --add-virtual-file=source/VERSION:3.4.6 -o "${TEST_ROOT}/source.tar" HEAD)
file(MAKE_DIRECTORY "${TEST_ROOT}/archive")
execute_process(
  COMMAND "${CMAKE_COMMAND}" -E tar xf "${TEST_ROOT}/source.tar"
  WORKING_DIRECTORY "${TEST_ROOT}/archive" RESULT_VARIABLE status
)
if(NOT status EQUAL 0)
  message(FATAL_ERROR "could not extract source archive")
endif()
assert_version("${TEST_ROOT}/archive/source" "3.4.6\\|3.4.6"
  -DCMAKE_DISABLE_FIND_PACKAGE_Git=TRUE)

foreach(version IN ITEMS "" "v3.4.6" "3.4" "3.4.6\"bad")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -S "${source}" -B "${source}/invalid"
      "-DFS_LINT_VERSION=${version}"
    RESULT_VARIABLE status OUTPUT_VARIABLE output ERROR_VARIABLE error
  )
  if(status EQUAL 0 OR NOT error MATCHES "Invalid fs-lint version")
    message(FATAL_ERROR "invalid version was not rejected: ${version}: ${output}${error}")
  endif()
endforeach()
