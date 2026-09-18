#ifndef FS_LINT_H
#define FS_LINT_H

#include <stddef.h>

#define FS_LINT_MAX_PATH_LENGTH 4096
#define FS_LINT_MAX_PATTERN_LENGTH 4096

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
  FS_LINT_STATUS_OK = 0,
  FS_LINT_STATUS_VIOLATIONS = 1,
  FS_LINT_STATUS_ERROR = 2
} fs_lint_status;

typedef enum {
  FS_LINT_CHANGE_ADDED,
  FS_LINT_CHANGE_MODIFIED,
  FS_LINT_CHANGE_DELETED
} fs_lint_change_kind;

typedef enum { FS_LINT_SEVERITY_WARNING, FS_LINT_SEVERITY_ERROR } fs_lint_severity;

typedef struct {
  const char *path;
  fs_lint_change_kind kind;
} fs_lint_change;

typedef enum {
  FS_LINT_NEW_FILES_DENY,
  FS_LINT_NEW_FILES_ALLOW
} fs_lint_new_files_default;

typedef struct {
  fs_lint_new_files_default new_files_default;
  const char *const *allow_patterns;
  size_t allow_pattern_count;
} fs_lint_config;

typedef struct {
  fs_lint_severity severity;
  const char *code;
  const char *path;
  const char *message;
} fs_lint_diagnostic;

typedef void (*fs_lint_reporter)(const fs_lint_diagnostic *diagnostic, void *user_data);

fs_lint_status fs_lint_check(const fs_lint_config *config,
                             const fs_lint_change *changes, size_t change_count,
                             fs_lint_reporter reporter, void *user_data);

#ifdef __cplusplus
}
#endif

#endif
