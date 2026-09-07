#include "legibility.h"

#include "glob.h"

#include <stdbool.h>
#include <string.h>

static void report_error(const char *code, const char *path, const char *message,
                         legibility_reporter reporter, void *user_data) {
  if (reporter == NULL) {
    return;
  }
  const legibility_diagnostic diagnostic = {
      .severity = LEGIBILITY_SEVERITY_ERROR,
      .code = code,
      .path = path,
      .message = message,
  };
  reporter(&diagnostic, user_data);
}

static bool is_path_separator(char value) { return value == '/' || value == '\\'; }

static bool valid_path_segment(const char *segment, size_t length) {
  if (length == 0) {
    return false;
  }
  const bool current = length == 1 && segment[0] == '.';
  const bool parent = length == 2 && segment[0] == '.' && segment[1] == '.';
  return !current && !parent;
}

static bool valid_path_segments(const char *path) {
  const char *segment = path;
  for (const char *cursor = path;; cursor += 1) {
    const bool boundary = *cursor == '\0' || is_path_separator(*cursor);
    if (!boundary) {
      continue;
    }
    if (!valid_path_segment(segment, (size_t)(cursor - segment))) {
      return false;
    }
    if (*cursor == '\0') {
      return true;
    }
    segment = cursor + 1;
  }
}

static bool normalized_repository_path(const char *path) {
  if (path[0] == '\0' || is_path_separator(path[0])) {
    return false;
  }
  return valid_path_segments(path);
}

static const char *validate_changes(const legibility_change *changes,
                                    size_t change_count) {
  for (size_t index = 0; index < change_count; index += 1) {
    if (changes[index].path == NULL) {
      return "every change requires a path";
    }
    if (strlen(changes[index].path) > LEGIBILITY_MAX_PATH_LENGTH) {
      return "change path exceeds LEGIBILITY_MAX_PATH_LENGTH";
    }
    if (!normalized_repository_path(changes[index].path)) {
      return "change path must be normalized and repository-relative";
    }
    const bool valid_kind = changes[index].kind == LEGIBILITY_CHANGE_ADDED ||
                            changes[index].kind == LEGIBILITY_CHANGE_MODIFIED ||
                            changes[index].kind == LEGIBILITY_CHANGE_DELETED;
    if (!valid_kind) {
      return "every change requires a valid kind";
    }
  }
  return NULL;
}

static const char *validate_patterns(const legibility_config *config) {
  for (size_t index = 0; index < config->allow_pattern_count; index += 1) {
    if (config->allow_patterns[index] == NULL) {
      return "every allow pattern requires a value";
    }
    if (strlen(config->allow_patterns[index]) > LEGIBILITY_MAX_PATTERN_LENGTH) {
      return "allow pattern exceeds LEGIBILITY_MAX_PATTERN_LENGTH";
    }
  }
  return NULL;
}

static const char *validate_config(const legibility_config *config) {
  if (config == NULL) {
    return "configuration is required";
  }
  const bool valid_default = config->new_files_default == LEGIBILITY_NEW_FILES_DENY ||
                             config->new_files_default == LEGIBILITY_NEW_FILES_ALLOW;
  if (!valid_default) {
    return "new_files_default is invalid";
  }
  const bool missing_patterns =
      config->allow_pattern_count > 0 && config->allow_patterns == NULL;
  if (missing_patterns) {
    return "allow_patterns is required when allow_pattern_count is non-zero";
  }
  return validate_patterns(config);
}

static const char *validate_input(const legibility_config *config,
                                  const legibility_change *changes,
                                  size_t change_count) {
  const char *config_error = validate_config(config);
  if (config_error != NULL) {
    return config_error;
  }
  if (change_count > 0 && changes == NULL) {
    return "changes are required when change_count is non-zero";
  }
  return validate_changes(changes, change_count);
}

static legibility_glob_matcher *create_matcher(const legibility_config *config) {
  if (config->allow_pattern_count == 0) {
    return NULL;
  }
  return legibility_glob_matcher_create(config->allow_patterns,
                                        config->allow_pattern_count);
}

static bool check_changes(legibility_glob_matcher *matcher, bool default_allowed,
                          const legibility_change *changes, size_t change_count,
                          legibility_reporter reporter, void *user_data) {
  bool found_violation = false;
  for (size_t index = 0; index < change_count; index += 1) {
    const bool added = changes[index].kind == LEGIBILITY_CHANGE_ADDED;
    if (!added) {
      continue;
    }
    bool allowed = default_allowed;
    if (matcher != NULL) {
      allowed =
          legibility_glob_matcher_allows(matcher, changes[index].path, default_allowed);
    }
    if (allowed) {
      continue;
    }
    report_error("files/new", changes[index].path,
                 "new file is not allowed by configuration", reporter, user_data);
    found_violation = true;
  }
  return found_violation;
}

static legibility_status check_denied_additions(const legibility_config *config,
                                                const legibility_change *changes,
                                                size_t change_count,
                                                legibility_reporter reporter,
                                                void *user_data) {
  const bool default_allowed = config->new_files_default == LEGIBILITY_NEW_FILES_ALLOW;
  legibility_glob_matcher *matcher = create_matcher(config);
  const bool allocation_failed = config->allow_pattern_count > 0 && matcher == NULL;
  if (allocation_failed) {
    report_error("runtime/allocation", "", "could not allocate glob matcher", reporter,
                 user_data);
    return LEGIBILITY_STATUS_ERROR;
  }
  const bool found = check_changes(matcher, default_allowed, changes, change_count,
                                   reporter, user_data);
  legibility_glob_matcher_destroy(matcher);
  return found ? LEGIBILITY_STATUS_VIOLATIONS : LEGIBILITY_STATUS_OK;
}

legibility_status legibility_check(const legibility_config *config,
                                   const legibility_change *changes,
                                   size_t change_count, legibility_reporter reporter,
                                   void *user_data) {
  const char *input_error = validate_input(config, changes, change_count);
  if (input_error != NULL) {
    report_error("input/invalid", "", input_error, reporter, user_data);
    return LEGIBILITY_STATUS_ERROR;
  }
  const bool unconditional_allow =
      config->new_files_default == LEGIBILITY_NEW_FILES_ALLOW &&
      config->allow_pattern_count == 0;
  if (unconditional_allow || change_count == 0) {
    return LEGIBILITY_STATUS_OK;
  }
  return check_denied_additions(config, changes, change_count, reporter, user_data);
}
