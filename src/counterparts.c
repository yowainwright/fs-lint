#include "counterparts.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

static void normalize_path(char *destination, const char *path) {
  const size_t length = strlen(path);
  for (size_t index = 0; index <= length; index += 1) {
    destination[index] = path[index] == '\\' ? '/' : path[index];
  }
}

static bool valid_path(const char *path) {
  const fs_lint_config policy = {.new_files_default = FS_LINT_NEW_FILES_ALLOW};
  const fs_lint_change change = {.path = path, .kind = FS_LINT_CHANGE_ADDED};
  return fs_lint_check(&policy, &change, 1, NULL, NULL) == FS_LINT_STATUS_OK;
}

bool cli_counterpart_pattern_valid(const char *pattern) {
  const size_t length = strlen(pattern);
  if (length > FS_LINT_MAX_PATTERN_LENGTH) {
    return false;
  }
  const char *capture = strpbrk(pattern, "*?{}");
  const bool has_capture = capture != NULL && strncmp(capture, "**", 2) == 0;
  const bool single = has_capture && strpbrk(capture + 2, "*?{}") == NULL;
  if (!single) {
    return false;
  }
  char sample[FS_LINT_MAX_PATH_LENGTH + 1];
  const int prefix = (int)(capture - pattern);
  snprintf(sample, sizeof(sample), "%.*sx%s", prefix, pattern, capture + 2);
  return valid_path(sample);
}

static bool capture_path(const char *path, const char *pattern, size_t *length) {
  const char *capture = strstr(pattern, "**");
  const size_t prefix = (size_t)(capture - pattern);
  const size_t suffix = strlen(capture + 2);
  const size_t size = strlen(path);
  if (size < prefix + suffix) {
    return false;
  }
  const bool begins = strncmp(path, pattern, prefix) == 0;
  const bool ends = strcmp(path + size - suffix, capture + 2) == 0;
  *length = size - prefix - suffix;
  return begins && ends;
}

static bool map_path(char *target, const cli_counterpart *rule, const char *path,
                     size_t length) {
  const char *source_capture = strstr(rule->from, "**");
  const char *target_capture = strstr(rule->to, "**");
  const int prefix = (int)(target_capture - rule->to);
  const char *captured = path + (source_capture - rule->from);
  const int size = snprintf(target, FS_LINT_MAX_PATH_LENGTH + 1, "%.*s%.*s%s", prefix,
                            rule->to, (int)length, captured, target_capture + 2);
  const bool fits = size >= 0 && size <= FS_LINT_MAX_PATH_LENGTH;
  return fits && valid_path(target);
}

static bool snapshot_contains(const cli_changes *targets, const char *path) {
  for (size_t index = 0; index < targets->count; index += 1) {
    if (strcmp(targets->items[index].path, path) == 0) {
      return true;
    }
  }
  return false;
}

static fs_lint_status stat_target(const char *path) {
  struct stat details;
  if (stat(path, &details) == 0) {
    return S_ISREG(details.st_mode) ? FS_LINT_STATUS_OK : FS_LINT_STATUS_VIOLATIONS;
  }
  const bool missing = errno == ENOENT || errno == ENOTDIR;
  return missing ? FS_LINT_STATUS_VIOLATIONS : FS_LINT_STATUS_ERROR;
}

static fs_lint_status inspect_target(const cli_counterpart_context *context,
                                     const char *target) {
  if (context->targets != NULL) {
    const bool found = snapshot_contains(context->targets, target);
    return found ? FS_LINT_STATUS_OK : FS_LINT_STATUS_VIOLATIONS;
  }
  char path[FS_LINT_MAX_PATH_LENGTH + 1];
  const int length = snprintf(path, sizeof(path), "%s/%s", context->root, target);
  const bool truncated = length < 0 || (size_t)length >= sizeof(path);
  if (truncated) {
    return FS_LINT_STATUS_ERROR;
  }
  return stat_target(path);
}

static void report_target(const cli_counterpart_context *context, const char *path,
                          const char *target, fs_lint_status status) {
  char message[FS_LINT_MAX_PATH_LENGTH + 64];
  snprintf(message, sizeof(message), "expected counterpart file: %s", target);
  const bool error = status == FS_LINT_STATUS_ERROR;
  const char *code = error ? "io/counterpart" : "files/counterpart";
  cli_report_error(code, path, message, context->output);
}

static fs_lint_status check_rule(const cli_counterpart_context *context,
                                 const cli_counterpart *rule, const char *path,
                                 char *target) {
  size_t length = 0;
  if (!capture_path(path, rule->from, &length)) {
    return FS_LINT_STATUS_OK;
  }
  if (!map_path(target, rule, path, length)) {
    cli_report_error("input/invalid", path, "counterpart path is too long or invalid",
                     context->output);
    return FS_LINT_STATUS_ERROR;
  }
  const fs_lint_status status = inspect_target(context, target);
  if (status == FS_LINT_STATUS_ERROR) {
    report_target(context, path, target, status);
  }
  return status;
}

static void remember_target(char *missing, const char *target) {
  if (missing[0] == '\0') {
    memcpy(missing, target, strlen(target) + 1);
  }
}

static fs_lint_status check_rules(const cli_counterpart_context *context,
                                  const char *path, char *missing) {
  fs_lint_status status = FS_LINT_STATUS_OK;
  for (size_t index = 0; index < context->config->counterpart_count; index += 1) {
    const cli_counterpart *rule = &context->config->counterparts[index];
    char target[FS_LINT_MAX_PATH_LENGTH + 1] = "";
    const fs_lint_status result = check_rule(context, rule, path, target);
    const bool exists = target[0] != '\0' && result == FS_LINT_STATUS_OK;
    const bool terminal = result == FS_LINT_STATUS_ERROR || exists;
    if (terminal) {
      return result;
    }
    remember_target(missing, target);
    status = result > status ? result : status;
  }
  return status;
}

static fs_lint_status check_change(const cli_counterpart_context *context,
                                   const fs_lint_change *change) {
  if (change->kind == FS_LINT_CHANGE_DELETED) {
    return FS_LINT_STATUS_OK;
  }
  char path[FS_LINT_MAX_PATH_LENGTH + 1];
  normalize_path(path, change->path);
  char missing[FS_LINT_MAX_PATH_LENGTH + 1] = "";
  const fs_lint_status status = check_rules(context, path, missing);
  if (status == FS_LINT_STATUS_VIOLATIONS) {
    report_target(context, path, missing, status);
  }
  return status;
}

static fs_lint_status check_changes(const cli_counterpart_context *context,
                                    const fs_lint_change *changes, size_t count) {
  fs_lint_status status = FS_LINT_STATUS_OK;
  for (size_t index = 0; index < count; index += 1) {
    const fs_lint_status result = check_change(context, &changes[index]);
    if (result == FS_LINT_STATUS_ERROR) {
      return result;
    }
    status = result > status ? result : status;
  }
  return status;
}

static fs_lint_status check_snapshot(const cli_counterpart_context *context,
                                     const fs_lint_change *changes, size_t count) {
  cli_changes targets;
  if (!cli_changes_read_git_files(context->root, context->staged, &targets)) {
    cli_report_error("input/invalid", "", targets.error, context->output);
    cli_changes_destroy(&targets);
    return FS_LINT_STATUS_ERROR;
  }
  cli_counterpart_context snapshot = *context;
  snapshot.targets = &targets;
  const fs_lint_status status = check_changes(&snapshot, changes, count);
  cli_changes_destroy(&targets);
  return status;
}

fs_lint_status cli_counterparts_check(const cli_counterpart_context *context,
                                      const fs_lint_change *changes, size_t count) {
  const bool skip = count == 0 || context->config->counterpart_count == 0;
  if (skip) {
    return FS_LINT_STATUS_OK;
  }
  const bool snapshot = context->staged || context->committed;
  if (snapshot) {
    return check_snapshot(context, changes, count);
  }
  return check_changes(context, changes, count);
}
