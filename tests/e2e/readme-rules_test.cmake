function(write_config contents)
  file(WRITE "${TEST_ROOT}/fs-lint.json" "${contents}")
endfunction()

function(assert_path path expected_status expected_output)
  execute_process(
    COMMAND "${FS_LINT}" check-path --root "${TEST_ROOT}" "${path}"
    RESULT_VARIABLE status
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
  )
  if(NOT status EQUAL expected_status)
    message(FATAL_ERROR "unexpected status for ${path}: ${status}: ${output}${error}")
  endif()
  if(NOT output STREQUAL expected_output)
    message(FATAL_ERROR "unexpected output for ${path}: ${output}")
  endif()
  if(NOT error STREQUAL "")
    message(FATAL_ERROR "unexpected stderr for ${path}: ${error}")
  endif()
endfunction()

file(REMOVE_RECURSE "${TEST_ROOT}")
file(MAKE_DIRECTORY "${TEST_ROOT}")

write_config("{\"version\":1,\"newFiles\":{}}")
set(
  denied
  "src/new-helper.c: error files/new: new file is not allowed by configuration\n"
)
assert_path(src/new-helper.c 1 "${denied}")

write_config("{\"version\":1,\"newFiles\":{\"default\":\"allow\"}}")
assert_path(src/new-helper.c 0 "")

write_config([=[
{"version":1,"newFiles":{"default":"deny","allow":["src/**/{index,utils,types,constants}.ts"]}}
]=])
assert_path(src/index.ts 0 "")
assert_path(src/auth/index.ts 0 "")
assert_path(src/auth/utils.ts 0 "")
assert_path(src/auth-utils/index.ts 0 "")
foreach(path src/auth/helper.ts src/auth/schema.generated.ts src/myindex.ts src/auth/notutils.ts)
  assert_path("${path}" 1 "${path}: error files/new: new file is not allowed by configuration\n")
endforeach()

string(
  CONCAT
  readme_config
  "{\"version\":1,\"newFiles\":{\"default\":\"deny\","
  "\"allow\":[\"README.md\",\"docs/**/*.md\",\"src/**/*.{js,ts,tsx}\","
  "\"cmd/**/*.go\",\"crates/**/*.rs\",\"native/**/*.{c,h,cpp}\","
  "\"!**/*.generated.*\"]}}"
)
write_config("${readme_config}")
assert_path(README.md 0 "")
assert_path(docs/setup.md 0 "")
assert_path(src/index.js 0 "")
assert_path(src/ui/index.ts 0 "")
assert_path(src/ui/Button.tsx 0 "")
assert_path(cmd/fs-lint/main.go 0 "")
assert_path(crates/fs/src/lib.rs 0 "")
assert_path(native/main.c 0 "")
assert_path(native/main.h 0 "")
assert_path(native/main.cpp 0 "")

set(
  readme_denied
  "tools/new-helper.py: error files/new: new file is not allowed by configuration\n"
)
assert_path(tools/new-helper.py 1 "${readme_denied}")

set(
  readme_generated_denied
  "src/schema.generated.ts: error files/new: new file is not allowed by configuration\n"
)
assert_path(src/schema.generated.ts 1 "${readme_generated_denied}")

string(
  CONCAT
  glob_config
  "{\"version\":1,\"newFiles\":{\"allow\":["
  "\"src/?.c\",\"src/*.h\",\"docs/**\",\"lib/**/index.c\"]}}"
)
write_config("${glob_config}")
assert_path(src/a.c 0 "")
assert_path(src/main.h 0 "")
assert_path(docs/api/http.md 0 "")
assert_path(lib/index.c 0 "")
assert_path(lib/ui/index.c 0 "")
assert_path("lib\\ui\\index.c" 0 "")

set(
  question_denied
  "src/ab.c: error files/new: new file is not allowed by configuration\n"
)
assert_path(src/ab.c 1 "${question_denied}")

set(
  segment_denied
  "src/nested/main.h: error files/new: new file is not allowed by configuration\n"
)
assert_path(src/nested/main.h 1 "${segment_denied}")

string(
  CONCAT
  language_config
  "{\"version\":1,\"newFiles\":{\"allow\":["
  "\"native/**/*.{c,cpp}\",\"crates/**/*.rs\","
  "\"cmd/**/*.go\",\"packages/*/{src,tests}/**/*.{js,ts,tsx}\","
  "\"tools/**/*.py\",\"!**/*.generated.*\"]}}"
)
write_config("${language_config}")
assert_path(native/main.c 0 "")
assert_path(native/main.cpp 0 "")
assert_path(crates/fs/src/lib.rs 0 "")
assert_path(cmd/fs-lint/main.go 0 "")
assert_path(packages/cli/src/index.js 0 "")
assert_path(packages/cli/tests/index.test.ts 0 "")
assert_path(packages/ui/src/Button.tsx 0 "")
assert_path(tools/release.py 0 "")

set(
  generated_denied
  "packages/cli/src/schema.generated.ts: error files/new: new file is not allowed by configuration\n"
)
assert_path(packages/cli/src/schema.generated.ts 1 "${generated_denied}")
