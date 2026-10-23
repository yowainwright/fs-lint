function(assert_invalid_config case_name filename contents expected_message)
  set(case_root "${TEST_ROOT}/${case_name}")
  file(REMOVE_RECURSE "${case_root}")
  file(MAKE_DIRECTORY "${case_root}")
  file(WRITE "${case_root}/${filename}" "${contents}")

  execute_process(
    COMMAND "${FS_LINT}" check-path src/new-helper.c
    WORKING_DIRECTORY "${case_root}"
    RESULT_VARIABLE status
    OUTPUT_VARIABLE output
  )

  if(NOT status EQUAL 2)
    message(FATAL_ERROR "expected exit code 2, received ${status}: ${output}")
  endif()
  if(NOT output MATCHES "${expected_message}")
    message(FATAL_ERROR "unexpected output: ${output}")
  endif()
endfunction()

assert_invalid_config(
  unknown
  fs-lint.json
  "{\"version\":1,\"newFiles\":{\"default\":\"deny\"},\"mystery\":true}"
  "unknown configuration key: mystery"
)

assert_invalid_config(
  duplicate
  fs-lint.json
  "{\"version\":1,\"version\":1,\"newFiles\":{\"default\":\"deny\"}}"
  "duplicate configuration key: version"
)

foreach(schema_value null 1 true "[]" "{}" "\"schema\\u0000.json\"")
  assert_invalid_config(
    invalid-schema
    fs-lint.json
    "{\"$schema\":${schema_value},\"version\":1,\"newFiles\":{}}"
    "schema must be a string without embedded NUL bytes"
  )
endforeach()

assert_invalid_config(
  duplicate-schema
  fs-lint.json
  "{\"$schema\":\"a.json\",\"$schema\":\"b.json\",\"version\":1,\"newFiles\":{}}"
  "duplicate configuration key: .schema"
)

assert_invalid_config(
  embedded-nul-default
  fs-lint.json
  "{\"version\":1,\"newFiles\":{\"default\":\"allow\\u0000junk\"}}"
  "newFiles.default must be \"allow\" or \"deny\""
)

assert_invalid_config(
  embedded-nul-pattern
  fs-lint.json
  "{\"version\":1,\"newFiles\":{\"allow\":[\"**\\u0000suffix\"]}}"
  "newFiles.allow must not contain embedded NUL bytes"
)

assert_invalid_config(
  embedded-nul-root-key
  fs-lint.json
  "{\"version\\u0000junk\":1,\"newFiles\":{\"default\":\"allow\"}}"
  "configuration key must not contain embedded NUL bytes"
)

assert_invalid_config(
  embedded-nul-new-files-key
  fs-lint.json
  "{\"version\":1,\"newFiles\":{\"default\\u0000junk\":\"allow\"}}"
  "configuration key must not contain embedded NUL bytes"
)

assert_invalid_config(
  yaml
  fs-lint.yaml
  "version = 1\n[newFiles]\ndefault = \"deny\"\n"
  "YAML configuration reader is not available yet"
)

assert_invalid_config(
  toml-unknown
  fs-lint.toml
  "version = 1\nmystery = true\n[newFiles]\ndefault = \"deny\"\n"
  "unknown configuration key: mystery"
)

assert_invalid_config(
  toml-invalid-allow
  fs-lint.toml
  "version = 1\n[newFiles]\nallow = [\"src/**\", 1]\n"
  "newFiles.allow must contain only strings"
)

string(REPEAT " " 1048577 oversized_config)
assert_invalid_config(
  oversized
  fs-lint.json
  "${oversized_config}"
  "configuration exceeds 1048576 bytes"
)

set(patterns "")
foreach(index RANGE 1 4097)
  string(APPEND patterns "\"path-${index}\",")
endforeach()
string(REGEX REPLACE ",$" "" patterns "${patterns}")
set(
  excessive_patterns
  "{\"version\":1,\"newFiles\":{\"allow\":[${patterns}]}}"
)
assert_invalid_config(
  excessive-patterns
  fs-lint.json
  "${excessive_patterns}"
  "newFiles.allow exceeds 4096 patterns"
)

string(REPEAT "a" 4096 maximum_pattern)
set(large_patterns "")
foreach(index RANGE 1 65)
  string(APPEND large_patterns "\"${maximum_pattern}\",")
endforeach()
string(REGEX REPLACE ",$" "" large_patterns "${large_patterns}")
set(
  excessive_pattern_bytes
  "{\"version\":1,\"newFiles\":{\"allow\":[${large_patterns}]}}"
)
assert_invalid_config(
  excessive-pattern-bytes
  fs-lint.json
  "${excessive_pattern_bytes}"
  "newFiles.allow exceeds 262144 bytes"
)
