function(write_config contents)
  file(WRITE "${TEST_ROOT}/fs-lint.json" "${contents}")
endfunction()

function(assert_command expected_status expected_output)
  execute_process(
    COMMAND "${FS_LINT}" ${ARGN}
    WORKING_DIRECTORY "${TEST_ROOT}"
    RESULT_VARIABLE status
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
  )
  if(NOT status EQUAL expected_status)
    message(FATAL_ERROR "expected status ${expected_status}, received ${status}: ${output}${error}")
  endif()
  if(NOT output STREQUAL expected_output)
    message(FATAL_ERROR "unexpected stdout: ${output}")
  endif()
  if(NOT error STREQUAL "")
    message(FATAL_ERROR "unexpected stderr: ${error}")
  endif()
endfunction()

function(assert_usage_error expected_error)
  execute_process(
    COMMAND "${FS_LINT}" ${ARGN}
    WORKING_DIRECTORY "${TEST_ROOT}"
    RESULT_VARIABLE status
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
  )
  if(NOT status EQUAL 2)
    message(FATAL_ERROR "expected usage status 2, received ${status}")
  endif()
  if(NOT output STREQUAL "")
    message(FATAL_ERROR "expected empty stdout: ${output}")
  endif()
  if(NOT error STREQUAL expected_error)
    message(FATAL_ERROR "unexpected stderr: ${error}")
  endif()
endfunction()

file(REMOVE_RECURSE "${TEST_ROOT}")
file(MAKE_DIRECTORY "${TEST_ROOT}")

string(
  CONCAT
  module_config
  "{\"version\":1,\"newFiles\":{\"default\":\"deny\","
  "\"allow\":[\"src/**/{index,utils,types,constants}.ts\"]}}"
)
write_config("${module_config}")

set(
  helper_denied
  "src/auth/helper.ts: error files/new: new file is not allowed by configuration\n"
)
assert_command(1 "${helper_denied}" check-path src/auth/helper.ts)
assert_command(1 "${helper_denied}" check src/auth/helper.ts)
assert_command(1 "${helper_denied}" check src/auth/helper.ts src/auth/index.ts)
assert_command(
  0
  ""
  check-path src/auth/helper.ts --allow "src/**/helper.ts"
)
assert_command(
  0
  ""
  check-path --allow "src/**/helper.ts" src/auth/helper.ts
)
assert_command(
  0
  ""
  check-path --allow "src/**/helper.ts" -- src/auth/helper.ts
)
assert_command(
  0
  ""
  --allow "src/**/helper.ts" check src/auth/helper.ts
)
assert_command(
  0
  ""
  check src/auth/helper.ts --allow "src/**/helper.ts"
)

string(
  CONCAT
  generated_config
  "{\"version\":1,\"newFiles\":{\"default\":\"allow\","
  "\"allow\":[\"!src/**/*.generated.ts\"]}}"
)
write_config("${generated_config}")

set(
  generated_denied
  "src/auth/schema.generated.ts: error files/new: new file is not allowed by configuration\n"
)
assert_command(1 "${generated_denied}" check-path src/auth/schema.generated.ts)
assert_command(
  0
  ""
  check-path src/auth/schema.generated.ts --allow "src/**/*.generated.ts"
)
assert_command(
  0
  ""
  --allow "src/**/*.generated.ts" check src/auth/schema.generated.ts
)

set(
  cli_denied
  "src/auth/index.ts: error files/new: new file is not allowed by configuration\n"
)
assert_command(
  1
  "${cli_denied}"
  check-path src/auth/index.ts --deny "src/auth/index.ts"
)
assert_command(
  1
  "${cli_denied}"
  --deny "src/auth/index.ts" check src/auth/index.ts
)
assert_command(
  1
  "${cli_denied}"
  check-path src/auth/index.ts --allow "src/auth/index.ts" --deny "src/auth/index.ts"
)
assert_command(
  0
  ""
  check-path src/auth/index.ts --deny "src/auth/index.ts" --allow "src/auth/index.ts"
)

write_config("{\"version\":1,\"newFiles\":{\"default\":\"deny\"}}")
string(
  CONCAT
  stdin_command
  "printf 'src/auth/helper.ts\\000' | "
  "\"$1\" check --stdin0 --root \"$2\" --allow 'src/**/helper.ts'"
)
execute_process(
  COMMAND /bin/sh -c "${stdin_command}" fs-lint-e2e "${FS_LINT}" "${TEST_ROOT}"
  RESULT_VARIABLE stdin_status
  OUTPUT_VARIABLE stdin_output
  ERROR_VARIABLE stdin_error
)
if(NOT stdin_status EQUAL 0)
  message(FATAL_ERROR "expected stdin override status 0, received ${stdin_status}")
endif()
if(NOT stdin_output STREQUAL "")
  message(FATAL_ERROR "unexpected stdin stdout: ${stdin_output}")
endif()
if(NOT stdin_error STREQUAL "")
  message(FATAL_ERROR "unexpected stdin stderr: ${stdin_error}")
endif()

assert_usage_error(
  "fs-lint: --allow patterns must not start with !\n"
  check-path src/auth/helper.ts --allow "!src/**/helper.ts"
)
assert_usage_error(
  "fs-lint: --deny patterns must not start with !\n"
  check-path src/auth/helper.ts --deny "!src/**/helper.ts"
)
