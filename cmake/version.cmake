function(fs_lint_git_version output)
  set(${output} "0.0.0-unknown" PARENT_SCOPE)
  if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/.git")
    return()
  endif()
  find_package(Git QUIET)
  if(NOT GIT_FOUND)
    return()
  endif()
  execute_process(
    COMMAND "${GIT_EXECUTABLE}" describe --tags --long --always --dirty
      --match "v[0-9]*.[0-9]*.[0-9]*"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    RESULT_VARIABLE status OUTPUT_VARIABLE version
    OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET
  )
  if(status EQUAL 0)
    set(${output} "${version}" PARENT_SCOPE)
  endif()
endfunction()

function(fs_lint_source_version output)
  set(version_file "${CMAKE_CURRENT_SOURCE_DIR}/VERSION")
  if(EXISTS "${version_file}")
    file(READ "${version_file}" version)
    string(STRIP "${version}" version)
  else()
    fs_lint_git_version(version)
    string(REGEX REPLACE "^v" "" version "${version}")
    string(REGEX REPLACE "-0-g[0-9a-f]+$" "" version "${version}")
    if(version MATCHES "^[0-9a-f]+(-dirty)?$")
      set(version "0.0.0-g${version}")
    endif()
  endif()
  set(${output} "${version}" PARENT_SCOPE)
endfunction()

if(NOT DEFINED FS_LINT_VERSION)
  fs_lint_source_version(FS_LINT_VERSION)
endif()
if(NOT FS_LINT_VERSION MATCHES "^([0-9]+\\.[0-9]+\\.[0-9]+)(-[0-9A-Za-z.-]+)?$")
  message(FATAL_ERROR "Invalid fs-lint version: ${FS_LINT_VERSION}")
endif()
set(FS_LINT_PROJECT_VERSION "${CMAKE_MATCH_1}")
