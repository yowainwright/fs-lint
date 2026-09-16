cmake_minimum_required(VERSION 3.20)

include(cmake/version.cmake)
project(fs-lint VERSION ${FS_LINT_PROJECT_VERSION} LANGUAGES C)

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

function(fs_lint_enable_warnings target)
  if(CMAKE_C_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(
      ${target}
      PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow
    )
  endif()
endfunction()

add_library(yyjson STATIC vendor/yyjson/yyjson.c)
target_include_directories(yyjson PUBLIC vendor/yyjson)

add_library(tomlc17 STATIC vendor/tomlc17/tomlc17.c)
target_include_directories(tomlc17 PUBLIC vendor/tomlc17)
if(CMAKE_C_COMPILER_ID MATCHES "Clang")
  target_compile_options(
    tomlc17 PRIVATE
    "-fsanitize-ignorelist=${CMAKE_CURRENT_SOURCE_DIR}/cmake/tomlc17-sanitizer-ignorelist.txt"
  )
endif()

add_library(fs_lint STATIC src/glob.c src/fs-lint.c)
set_target_properties(fs_lint PROPERTIES OUTPUT_NAME fs-lint EXPORT_NAME fs-lint)
target_include_directories(
  fs_lint
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
  PRIVATE src
)

fs_lint_enable_warnings(fs_lint)

add_executable(
  fs-lint
  src/changes.c
  src/cli_output.c
  src/config.c
  src/discover.c
  src/git_environment.c
  src/main.c
)
target_include_directories(fs-lint PRIVATE src)
set_target_properties(fs-lint PROPERTIES EXPORT_NAME cli)
target_link_libraries(fs-lint PRIVATE fs_lint yyjson tomlc17)
target_compile_definitions(fs-lint PRIVATE FS_LINT_VERSION="${FS_LINT_VERSION}")
fs_lint_enable_warnings(fs-lint)

install(
  TARGETS fs_lint fs-lint
  EXPORT fs-lint-targets
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)
install(FILES include/fs-lint.h DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(FILES LICENSE DESTINATION ${CMAKE_INSTALL_DOCDIR})
install(
  FILES vendor/yyjson/LICENSE
  DESTINATION ${CMAKE_INSTALL_DOCDIR}
  RENAME yyjson-LICENSE
)
install(
  FILES vendor/tomlc17/LICENSE
  DESTINATION ${CMAKE_INSTALL_DOCDIR}
  RENAME tomlc17-LICENSE
)
configure_package_config_file(
  cmake/fs-lint-config.cmake.in
  ${CMAKE_CURRENT_BINARY_DIR}/fs-lint-config.cmake
  INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/fs-lint
)
write_basic_package_version_file(
  ${CMAKE_CURRENT_BINARY_DIR}/fs-lint-config-version.cmake
  VERSION ${PROJECT_VERSION}
  COMPATIBILITY SameMajorVersion
)
install(
  EXPORT fs-lint-targets
  FILE fs-lint-targets.cmake
  NAMESPACE fs-lint::
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/fs-lint
)
install(
  FILES
    ${CMAKE_CURRENT_BINARY_DIR}/fs-lint-config.cmake
    ${CMAKE_CURRENT_BINARY_DIR}/fs-lint-config-version.cmake
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/fs-lint
)

include(CTest)

if(BUILD_TESTING)
  file(MAKE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/test-data)
  add_executable(fs-lint-test tests/fs-lint_test.c)
  target_link_libraries(fs-lint-test PRIVATE fs_lint)
  fs_lint_enable_warnings(fs-lint-test)
  add_test(NAME core-policy COMMAND fs-lint-test)
  add_executable(allocation-test tests/allocation_test.c src/glob.c src/fs-lint.c)
  target_include_directories(allocation-test PRIVATE include src)
  target_compile_definitions(
    allocation-test PRIVATE malloc=test_malloc calloc=test_calloc free=test_free
  )
  fs_lint_enable_warnings(allocation-test)
  add_test(NAME allocation-failures COMMAND allocation-test)
  add_executable(cli-output-test tests/cli_output_test.c src/cli_output.c)
  target_include_directories(cli-output-test PRIVATE src)
  target_link_libraries(cli-output-test PRIVATE fs_lint)
  fs_lint_enable_warnings(cli-output-test)
  add_test(NAME cli-output COMMAND cli-output-test)
  add_test(NAME setup-hooks COMMAND sh ${CMAKE_CURRENT_SOURCE_DIR}/tests/setup_test.sh)
  set_tests_properties(setup-hooks PROPERTIES LABELS "scripts")
  find_program(FS_LINT_RUBY ruby)
  if(FS_LINT_RUBY)
    add_test(
      NAME integration-release-homebrew-readme
      COMMAND sh ${CMAKE_CURRENT_SOURCE_DIR}/tests/integration/release_test.sh
    )
    set_tests_properties(integration-release-homebrew-readme PROPERTIES LABELS "integration;scripts")
  else()
    message(STATUS "Ruby not found; skipping the Homebrew release integration test")
  endif()

  function(add_fs_lint_e2e name)
    set(test_name e2e-${name})
    set(test_root ${CMAKE_CURRENT_BINARY_DIR}/test-data/e2e/${name})
    set(test_script ${CMAKE_CURRENT_SOURCE_DIR}/tests/e2e/${name}_test.cmake)
    add_test(
      NAME ${test_name}
      COMMAND
        ${CMAKE_COMMAND}
        -DFS_LINT=$<TARGET_FILE:fs-lint>
        -DFS_LINT_EXPECTED_VERSION=${FS_LINT_VERSION}
        -DFS_LINT_EXPECTED_PROJECT_VERSION=${PROJECT_VERSION}
        -DPROJECT_SOURCE_ROOT=${CMAKE_CURRENT_SOURCE_DIR}
        -DTEST_ROOT=${test_root}
        -DPROJECT_BUILD_DIR=${CMAKE_CURRENT_BINARY_DIR}
        -P ${test_script}
    )
    set_tests_properties(${test_name} PROPERTIES LABELS "e2e;binary")
  endfunction()

  add_fs_lint_e2e(discovery)
  add_fs_lint_e2e(explicit-config)
  add_fs_lint_e2e(cli-overrides)
  add_fs_lint_e2e(git-staged)
  add_fs_lint_e2e(git-root-env)
  add_fs_lint_e2e(invalid-config)
  add_fs_lint_e2e(install)
  add_fs_lint_e2e(json-output)
  add_fs_lint_e2e(policy)
  add_fs_lint_e2e(readme-rules)
  add_fs_lint_e2e(stdin0)
  add_fs_lint_e2e(toml-config)
  add_fs_lint_e2e(usage)
  add_fs_lint_e2e(version)

  add_custom_target(
    e2e
    COMMAND ${CMAKE_CTEST_COMMAND} --output-on-failure -L e2e
    DEPENDS fs-lint
    USES_TERMINAL
  )
endif()
