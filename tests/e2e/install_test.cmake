file(REMOVE_RECURSE "${TEST_ROOT}")

set(install_root "${TEST_ROOT}/install")
set(consumer_root "${TEST_ROOT}/consumer")
set(consumer_build "${TEST_ROOT}/build")

execute_process(
  COMMAND
    "${CMAKE_COMMAND}" --install "${PROJECT_BUILD_DIR}" --prefix "${install_root}"
  RESULT_VARIABLE install_status
  OUTPUT_VARIABLE install_output
  ERROR_VARIABLE install_error
)

if(NOT install_status EQUAL 0)
  message(FATAL_ERROR "install failed: ${install_output}${install_error}")
endif()

file(GLOB installed_licenses "${install_root}/share/doc/*/*LICENSE")
list(LENGTH installed_licenses license_count)
if(NOT license_count EQUAL 3)
  message(FATAL_ERROR "expected three installed licenses, found ${license_count}")
endif()

file(MAKE_DIRECTORY "${consumer_root}")
file(
  WRITE "${consumer_root}/CMakeLists.txt"
  [=[cmake_minimum_required(VERSION 3.20)
project(fs-lint-consumer LANGUAGES C)

find_package(fs-lint CONFIG REQUIRED)

add_executable(fs-lint-consumer main.c)
target_link_libraries(fs-lint-consumer PRIVATE fs-lint::fs-lint)
]=]
)
file(APPEND "${consumer_root}/CMakeLists.txt"
  "\nif(NOT fs-lint_VERSION VERSION_EQUAL \"${FS_LINT_EXPECTED_PROJECT_VERSION}\")\n"
  "  message(FATAL_ERROR \"Installed package version does not match the build\")\n"
  "endif()\n"
)
file(
  WRITE "${consumer_root}/main.c"
  [=[#include <fs-lint.h>

int main(void) {
  const fs_lint_config config = {
      .new_files_default = FS_LINT_NEW_FILES_ALLOW,
  };
  const fs_lint_status status = fs_lint_check(&config, NULL, 0, NULL, NULL);
  return status == FS_LINT_STATUS_OK ? 0 : 1;
}
]=]
)

execute_process(
  COMMAND
    "${CMAKE_COMMAND}"
    -S "${consumer_root}"
    -B "${consumer_build}"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_PREFIX_PATH=${install_root}
  RESULT_VARIABLE configure_status
  OUTPUT_VARIABLE configure_output
  ERROR_VARIABLE configure_error
)

if(NOT configure_status EQUAL 0)
  message(FATAL_ERROR "consumer configure failed: ${configure_output}${configure_error}")
endif()

execute_process(
  COMMAND "${CMAKE_COMMAND}" --build "${consumer_build}" --config Release
  RESULT_VARIABLE build_status
  OUTPUT_VARIABLE build_output
  ERROR_VARIABLE build_error
)

if(NOT build_status EQUAL 0)
  message(FATAL_ERROR "consumer build failed: ${build_output}${build_error}")
endif()

execute_process(
  COMMAND "${consumer_build}/fs-lint-consumer"
  RESULT_VARIABLE run_status
)

if(NOT run_status EQUAL 0)
  message(FATAL_ERROR "installed library consumer failed: ${run_status}")
endif()
