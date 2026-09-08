string(
  CONCAT
  expected_error
  "usage: fs-lint [--root path] [--config path] "
  "[--format text|json] [--allow pattern] "
  "[--deny pattern]\n"
  "usage: fs-lint check "
  "[--root path] [--config path] "
  "[--format text|json] [--allow pattern] "
  "[--deny pattern] [--] <path>...\n"
  "usage: fs-lint check (--stdin0|--staged|--base ref) "
  "[--root path] [--config path] "
  "[--format text|json] [--allow pattern] [--deny pattern]\n"
  "usage: fs-lint check-path "
  "[--root path] [--config path] "
  "[--format text|json] [--allow pattern] "
  "[--deny pattern] [--] <path>\n"
)

execute_process(
  COMMAND "${FS_LINT}" --help
  RESULT_VARIABLE help_status
  OUTPUT_VARIABLE help_output
  ERROR_VARIABLE help_error
)

if(NOT help_status EQUAL 0)
  message(FATAL_ERROR "expected help exit code 0, received ${help_status}")
endif()

if(NOT help_output STREQUAL expected_error)
  message(FATAL_ERROR "unexpected help output: ${help_output}")
endif()

if(NOT help_error STREQUAL "")
  message(FATAL_ERROR "expected empty help stderr: ${help_error}")
endif()

execute_process(
  COMMAND "${FS_LINT}" --version
  RESULT_VARIABLE version_status
  OUTPUT_VARIABLE version_output
  ERROR_VARIABLE version_error
)

if(NOT version_status EQUAL 0)
  message(FATAL_ERROR "expected version exit code 0, received ${version_status}")
endif()

if(NOT version_output STREQUAL "fs-lint ${FS_LINT_EXPECTED_VERSION}\n")
  message(FATAL_ERROR "unexpected version output: ${version_output}")
endif()

if(NOT version_error STREQUAL "")
  message(FATAL_ERROR "expected empty version stderr: ${version_error}")
endif()

file(REMOVE_RECURSE "${TEST_ROOT}")
file(MAKE_DIRECTORY "${TEST_ROOT}")
file(
  WRITE
  "${TEST_ROOT}/fs-lint.json"
  "{\"version\":1,\"newFiles\":{\"default\":\"deny\"}}"
)

execute_process(
  COMMAND "${FS_LINT}" --root "${TEST_ROOT}"
  RESULT_VARIABLE status
  OUTPUT_VARIABLE output
  ERROR_VARIABLE error
)

if(NOT status EQUAL 0)
  message(FATAL_ERROR "expected config validation exit code 0, received ${status}")
endif()

if(NOT output STREQUAL "")
  message(FATAL_ERROR "expected empty config-validation stdout: ${output}")
endif()

if(NOT error STREQUAL "")
  message(FATAL_ERROR "expected empty config-validation stderr: ${error}")
endif()

execute_process(
  COMMAND "${FS_LINT}" check --stdin0 --staged
  RESULT_VARIABLE sources_status
  OUTPUT_VARIABLE sources_output
  ERROR_VARIABLE sources_error
)

if(NOT sources_status EQUAL 2)
  message(FATAL_ERROR "expected conflicting sources to exit 2")
endif()

if(NOT sources_output STREQUAL "")
  message(FATAL_ERROR "expected empty conflicting-source stdout: ${sources_output}")
endif()

if(NOT sources_error STREQUAL expected_error)
  message(FATAL_ERROR "unexpected conflicting-source usage: ${sources_error}")
endif()

file(REMOVE_RECURSE "${TEST_ROOT}")
file(MAKE_DIRECTORY "${TEST_ROOT}")

execute_process(
  COMMAND "${FS_LINT}" check-path --root "${TEST_ROOT}" src/new-helper.c
  RESULT_VARIABLE config_status
  OUTPUT_VARIABLE config_output
  ERROR_VARIABLE config_error
)

string(
  CONCAT
  expected_output
  "${TEST_ROOT}"
  ": error config/invalid: "
  "no configuration file found\n"
)

if(NOT config_status EQUAL 2)
  message(FATAL_ERROR "expected missing-config exit code 2")
endif()

if(NOT config_output STREQUAL expected_output)
  message(FATAL_ERROR "unexpected missing-config stdout: ${config_output}")
endif()

if(NOT config_error STREQUAL "")
  message(FATAL_ERROR "expected empty missing-config stderr: ${config_error}")
endif()
