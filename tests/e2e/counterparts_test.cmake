function(check expected_status)
  execute_process(
    COMMAND "${FS_LINT}" check --root "${TEST_ROOT}" ${ARGN}
    RESULT_VARIABLE status OUTPUT_VARIABLE output ERROR_VARIABLE error
  )
  if(NOT status EQUAL expected_status OR NOT error STREQUAL "")
    message(FATAL_ERROR "expected ${expected_status}, got ${status}: ${output}${error}")
  endif()
  set(CHECK_OUTPUT "${output}" PARENT_SCOPE)
endfunction()

file(REMOVE_RECURSE "${TEST_ROOT}")
file(MAKE_DIRECTORY "${TEST_ROOT}/src/core" "${TEST_ROOT}/src/cli/init")
get_filename_component(test_parent "${TEST_ROOT}" DIRECTORY)
set(ENV{GIT_CEILING_DIRECTORIES} "${test_parent}")
set(config [=[
{"version":1,"newFiles":{"default":"allow"},"counterparts":[
  {"from":"tests/unit/**.test.ts","to":"src/**.ts"}
]}
]=])
file(WRITE "${TEST_ROOT}/fs-lint.json" "${config}")
file(WRITE "${TEST_ROOT}/src/core/patches.ts" "export {};\n")
file(WRITE "${TEST_ROOT}/src/cli/init/index.ts" "export {};\n")
check(0 tests/unit/core/patches.test.ts tests/unit/cli/init/index.test.ts)
if(NOT CHECK_OUTPUT STREQUAL "")
  message(FATAL_ERROR "valid counterparts must be silent: ${CHECK_OUTPUT}")
endif()
check(0 "tests\\unit\\core\\patches.test.ts" other/example.test.ts)

file(WRITE "${TEST_ROOT}/src/core/view.tsx" "export {};\n")
file(WRITE "${TEST_ROOT}/fs-lint.json" [=[
{"version":1,"newFiles":{"default":"allow"},"counterparts":[
  {"from":"tests/unit/**.test.ts","to":"src/**.ts"},
  {"from":"tests/unit/**.test.ts","to":"src/**.tsx"}
]}
]=])
check(0 tests/unit/core/view.test.ts tests/unit/core/patches.test.ts)
check(1 tests/unit/core/missing.test.ts)
file(MAKE_DIRECTORY "${TEST_ROOT}/scripts")
file(WRITE "${TEST_ROOT}/scripts/task.sh" "exit 0\n")
file(WRITE "${TEST_ROOT}/fs-lint.json" [=[
{"version":1,"newFiles":{"default":"allow"},"counterparts":[
  {"from":"tests/unit/**.test.ts","to":"src/**.ts"},
  {"from":"tests/unit/scripts/**.test.ts","to":"scripts/**.sh"}
]}
]=])
check(0 tests/unit/scripts/task.test.ts)
check(1 tests/unit/scripts/missing.test.ts)
file(WRITE "${TEST_ROOT}/fs-lint.json" "${config}")

foreach(path core/patches-pnpm cli/onboarding-flow)
  check(1 "tests/unit/${path}.test.ts")
  set(expected "tests/unit/${path}.test.ts: error files/counterpart: expected counterpart file: src/${path}.ts\n")
  if(NOT CHECK_OUTPUT STREQUAL expected)
    message(FATAL_ERROR "unexpected counterpart diagnostic: ${CHECK_OUTPUT}")
  endif()
endforeach()

file(MAKE_DIRECTORY "${TEST_ROOT}/src/core/directory.ts")
check(1 tests/unit/core/directory.test.ts)
check(1 --format json tests/unit/core/missing.test.ts)
string(JSON code GET "${CHECK_OUTPUT}" code)
string(JSON severity GET "${CHECK_OUTPUT}" severity)
if(NOT code STREQUAL "files/counterpart" OR NOT severity STREQUAL "error")
  message(FATAL_ERROR "expected JSON counterpart error: ${CHECK_OUTPUT}")
endif()

set(input "${TEST_ROOT}/paths")
execute_process(
  COMMAND printf "%s\\000" "tests/unit/core/missing.test.ts"
  OUTPUT_FILE "${input}" COMMAND_ERROR_IS_FATAL ANY
)
execute_process(
  COMMAND "${FS_LINT}" check --root "${TEST_ROOT}" --stdin0
  INPUT_FILE "${input}" RESULT_VARIABLE status OUTPUT_VARIABLE output
)
if(NOT status EQUAL 1 OR NOT output MATCHES "files/counterpart")
  message(FATAL_ERROR "NUL input must enforce counterparts: ${output}")
endif()

file(WRITE "${TEST_ROOT}/fs-lint.toml" [=[
version = 1
[newFiles]
default = "allow"
[[counterparts]]
from = "tests/unit/**.test.ts"
to = "src/**.ts"
]=])
check(0 --config fs-lint.toml tests/unit/core/patches.test.ts)
check(1 --config fs-lint.toml tests/unit/core/patches-pnpm.test.ts)

foreach(target "123" "\"../src/**.ts\"" "[\"src/**.ts\"]")
  file(WRITE "${TEST_ROOT}/fs-lint.toml" "version=1\n[newFiles]\ndefault=\"allow\"\n[[counterparts]]\nfrom=\"tests/unit/**.test.ts\"\nto=${target}\n")
  check(2 --config fs-lint.toml tests/unit/core/patches.test.ts)
endforeach()

file(CREATE_LINK "loop.ts" "${TEST_ROOT}/src/core/loop.ts" SYMBOLIC)
check(2 --config fs-lint.json tests/unit/core/loop.test.ts)
if(NOT CHECK_OUTPUT MATCHES "io/counterpart")
  message(FATAL_ERROR "unexpected counterpart I/O diagnostic: ${CHECK_OUTPUT}")
endif()

file(WRITE "${TEST_ROOT}/fs-lint.json" [=[
{"version":1,"newFiles":{"default":"allow"},"counterparts":[
  {"from":"tests\\unit\\**.test.ts","to":"src\\**.ts"}
]}
]=])
check(0 --config fs-lint.json tests/unit/core/patches.test.ts)

set(invalid_rules
  "{}" "[{}]" "[{\"from\":123,\"to\":\"src/**.ts\"}]"
  "[{\"from\":\"tests/*.test.ts\",\"to\":\"src/**.ts\"}]"
  "[{\"from\":\"tests/**.test.ts\",\"to\":\"../src/**.ts\"}]"
  "[{\"from\":\"tests/**/**.test.ts\",\"to\":\"src/**.ts\"}]"
  "[{\"from\":\"tests/**.test.ts\",\"to\":\"/src/**.ts\"}]"
  "[{\"from\":\"tests/**.test.ts\",\"to\":\"src/**.ts\",\"extra\":true}]"
  "[{\"from\":\"tests/**.test.ts\",\"from\":\"x/**\",\"to\":\"src/**.ts\"}]"
  "[{\"from\":\"tests/**.test.ts\",\"to\":\"src/**.ts\\u0000hidden\"}]"
)
foreach(rules IN LISTS invalid_rules)
  file(WRITE "${TEST_ROOT}/fs-lint.json" "{\"version\":1,\"newFiles\":{},\"counterparts\":${rules}}")
  check(2 --config fs-lint.json tests/unit/example.test.ts)
  if(NOT CHECK_OUTPUT MATCHES "config/invalid")
    message(FATAL_ERROR "expected invalid mapping config: ${CHECK_OUTPUT}")
  endif()
endforeach()

file(WRITE "${TEST_ROOT}/fs-lint.json" [=[
{"version":1,"newFiles":{"default":"allow"},"counterparts":[{"from":"t**t","to":"**"}]}
]=])
check(2 --config fs-lint.json t..t)
if(NOT CHECK_OUTPUT MATCHES "input/invalid")
  message(FATAL_ERROR "captured paths must not escape the root: ${CHECK_OUTPUT}")
endif()

string(REPEAT "a" 4090 prefix)
file(WRITE "${TEST_ROOT}/fs-lint.json" "{\"version\":1,\"newFiles\":{\"default\":\"allow\"},\"counterparts\":[{\"from\":\"tests/unit/**.test.ts\",\"to\":\"${prefix}**.ts\"}]}")
check(2 --config fs-lint.json tests/unit/long-name.test.ts)

string(REPEAT "{\"from\":\"tests/**\",\"to\":\"src/**\"}," 128 rules)
file(WRITE "${TEST_ROOT}/fs-lint.json" "{\"version\":1,\"newFiles\":{},\"counterparts\":[${rules}{\"from\":\"tests/**\",\"to\":\"src/**\"}]}")
check(2 --config fs-lint.json tests/example.test.ts)

file(WRITE "${TEST_ROOT}/fs-lint.json" "${config}")
file(REMOVE "${TEST_ROOT}/fs-lint.toml")

function(git)
  execute_process(
    COMMAND git -C "${TEST_ROOT}" ${ARGN}
    RESULT_VARIABLE status OUTPUT_VARIABLE output ERROR_VARIABLE error
  )
  if(NOT status EQUAL 0)
    message(FATAL_ERROR "fixture Git failure: ${output}${error}")
  endif()
  string(STRIP "${output}" output)
  set(GIT_OUTPUT "${output}" PARENT_SCOPE)
endfunction()

git(init)
git(config user.name "fs-lint fixture")
git(config user.email "fixture@example.invalid")
git(add fs-lint.json src/core/patches.ts src/cli/init/index.ts)
check(0 --staged)
git(commit -m baseline)
git(rev-parse HEAD)
set(base "${GIT_OUTPUT}")

file(MAKE_DIRECTORY "${TEST_ROOT}/tests/unit/cli" "${TEST_ROOT}/tests/unit/core")
check(0 --root "${TEST_ROOT}/tests" tests/unit/core/patches.test.ts)
check(1 --root "${TEST_ROOT}/tests" tests/unit/core/missing.test.ts)
execute_process(
  COMMAND "${FS_LINT}" check tests/unit/core/patches.test.ts
  WORKING_DIRECTORY "${TEST_ROOT}/tests"
  RESULT_VARIABLE status OUTPUT_VARIABLE output ERROR_VARIABLE error
)
if(NOT status EQUAL 0 OR NOT output STREQUAL "" OR NOT error STREQUAL "")
  message(FATAL_ERROR "subdirectory invocation must find repository counterparts: ${output}${error}")
endif()
execute_process(
  COMMAND printf "%s\\000" "tests/unit/core/patches.test.ts"
  OUTPUT_FILE "${input}" COMMAND_ERROR_IS_FATAL ANY
)
execute_process(
  COMMAND "${FS_LINT}" check --root "${TEST_ROOT}/tests" --stdin0
  INPUT_FILE "${input}" RESULT_VARIABLE status OUTPUT_VARIABLE output ERROR_VARIABLE error
)
if(NOT status EQUAL 0 OR NOT output STREQUAL "" OR NOT error STREQUAL "")
  message(FATAL_ERROR "subdirectory stdin must find repository counterparts: ${output}${error}")
endif()
file(WRITE "${TEST_ROOT}/tests/unit/cli/pending.test.ts" "export {};\n")
file(WRITE "${TEST_ROOT}/src/cli/pending.ts" "export {};\n")
git(add tests/unit/cli/pending.test.ts)
check(1 --staged)
if(NOT CHECK_OUTPUT MATCHES "files/counterpart")
  message(FATAL_ERROR "untracked source must not satisfy staged test: ${CHECK_OUTPUT}")
endif()

git(add -N src/cli/pending.ts)
check(1 --staged)
file(REMOVE "${TEST_ROOT}/src/cli/pending.ts")
check(1 --staged)
file(WRITE "${TEST_ROOT}/src/cli/pending.ts" "")
git(add src/cli/pending.ts)
file(REMOVE "${TEST_ROOT}/src/cli/pending.ts")
check(0 --staged)
check(0 --staged --root "${TEST_ROOT}/tests")
git(commit -m mapped)
check(0 --base "${base}")

file(WRITE "${TEST_ROOT}/tests/unit/core/orphan.test.ts" "export {};\n")
file(WRITE "${TEST_ROOT}/src/core/orphan.ts" "export {};\n")
git(add tests/unit/core/orphan.test.ts)
git(commit -m orphan)
check(1 --base "${base}")
if(NOT CHECK_OUTPUT MATCHES "core/orphan.test.ts.*files/counterpart")
  message(FATAL_ERROR "untracked source must not satisfy HEAD test: ${CHECK_OUTPUT}")
endif()

file(WRITE "${TEST_ROOT}/src/core/large.ts" "export {};\n")
git(add src/core/orphan.ts src/core/large.ts)
git(rev-parse HEAD:src/core/patches.ts)
set(bulk_object "${GIT_OUTPUT}")
set(index_entries "${TEST_ROOT}/bulk-index")
execute_process(
  COMMAND awk -v "object=${bulk_object}" [=[BEGIN {
    for (i = 0; i <= 100000; i++)
      printf "100644 %s\tbulk/%06d.ts\n", object, i
  }]=]
  OUTPUT_FILE "${index_entries}" COMMAND_ERROR_IS_FATAL ANY
)
execute_process(
  COMMAND git -C "${TEST_ROOT}" update-index --index-info
  INPUT_FILE "${index_entries}" COMMAND_ERROR_IS_FATAL ANY
)
git(commit -m large-baseline)
git(rev-parse HEAD)
set(large_base "${GIT_OUTPUT}")
file(WRITE "${TEST_ROOT}/tests/unit/core/large.test.ts" "export {};\n")
git(add tests/unit/core/large.test.ts)
check(0 --staged)
git(commit -m large-counterpart)
check(0 --base "${large_base}")

file(WRITE "${TEST_ROOT}/fs-lint.json" [=[
{"version":1,"newFiles":{"default":"allow"},"counterparts":[
  {"from":"tests/unit/bulk/**.test.ts","to":"bulk/**.ts"}
]}
]=])
git(add fs-lint.json)
execute_process(
  COMMAND awk -v "object=${bulk_object}" [=[BEGIN {
    for (i = 90001; i <= 100000; i++)
      printf "100644 %s\ttests/unit/bulk/%06d.test.ts\n", object, i
  }]=]
  OUTPUT_FILE "${index_entries}" COMMAND_ERROR_IS_FATAL ANY
)
execute_process(
  COMMAND git -C "${TEST_ROOT}" update-index --index-info
  INPUT_FILE "${index_entries}" COMMAND_ERROR_IS_FATAL ANY
)
check(0 --staged)

set(sha256_root "${TEST_ROOT}/sha256")
file(MAKE_DIRECTORY "${sha256_root}/src" "${sha256_root}/tests/unit")
file(WRITE "${sha256_root}/fs-lint.json" "${config}")
file(WRITE "${sha256_root}/src/example.ts" "")
git(-C "${sha256_root}" init --object-format=sha256)
git(-C "${sha256_root}" config user.name "fs-lint fixture")
git(-C "${sha256_root}" config user.email "fixture@example.invalid")
git(-C "${sha256_root}" add fs-lint.json src/example.ts)
check(0 --staged --root "${sha256_root}")
git(-C "${sha256_root}" commit -m baseline)
git(-C "${sha256_root}" rev-parse HEAD)
set(sha256_base "${GIT_OUTPUT}")
file(WRITE "${sha256_root}/tests/unit/example.test.ts" "")
git(-C "${sha256_root}" add tests/unit/example.test.ts)
check(0 --staged --root "${sha256_root}")
git(-C "${sha256_root}" commit -m mapped)
check(0 --base "${sha256_base}" --root "${sha256_root}")
