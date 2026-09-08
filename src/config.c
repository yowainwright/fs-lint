#include "config.h"

#include "discover.h"
#include "tomlc17.h"
#include "yyjson.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define CLI_MAX_CONFIG_BYTES 1048576
#define CLI_MAX_ALLOW_PATTERNS 4096
#define CLI_MAX_ALLOW_PATTERN_BYTES 262144

typedef struct {
  const char *name;
  bool seen;
} expected_key;

typedef struct {
  char *data;
  size_t length;
  size_t capacity;
} captured_output;

static char *copy_string(const char *value) {
  const size_t size = strlen(value) + 1;
  char *copy = malloc(size);
  if (copy != NULL) {
    memcpy(copy, value, size);
  }
  return copy;
}

static char *join_path(const char *root, const char *name) {
  const size_t size = strlen(root) + strlen(name) + 2;
  char *path = malloc(size);
  if (path != NULL) {
    snprintf(path, size, "%s/%s", root, name);
  }
  return path;
}

static char *resolve_config_path(const char *root, const char *config_path) {
  if (config_path[0] == '/') {
    return copy_string(config_path);
  }
  return join_path(root, config_path);
}

static bool has_suffix(const char *value, const char *suffix) {
  const size_t value_length = strlen(value);
  const size_t suffix_length = strlen(suffix);
  const bool long_enough = value_length >= suffix_length;
  return long_enough && strcmp(value + value_length - suffix_length, suffix) == 0;
}

static const char *base_name(const char *path) {
  const char *separator = strrchr(path, '/');
  return separator == NULL ? path : separator + 1;
}

static const char *format_error(const char *path) {
  const bool yaml = has_suffix(path, ".yaml") || has_suffix(path, ".yml");
  if (yaml) {
    return "YAML configuration reader is not available yet";
  }
  const bool supported = has_suffix(path, ".json") || has_suffix(path, ".toml") ||
                         strcmp(base_name(path), ".fs-lintrc") == 0;
  if (!supported) {
    return "configuration must use .fs-lintrc, fs-lint.json, or fs-lint.toml";
  }
  return NULL;
}

static bool is_toml_path(const char *path) { return has_suffix(path, ".toml"); }

static bool fail(cli_config *config, const char *message) {
  snprintf(config->error, sizeof(config->error), "%s", message);
  return false;
}

static bool grow_output(captured_output *output, size_t needed, cli_config *config) {
  size_t capacity = output->capacity == 0 ? 4096 : output->capacity;
  while (capacity < needed) {
    if (capacity > CLI_MAX_CONFIG_BYTES / 2) {
      return fail(config, "configuration exceeds 1048576 bytes");
    }
    capacity *= 2;
  }
  char *data = realloc(output->data, capacity);
  if (data == NULL) {
    return fail(config, "could not allocate configuration");
  }
  output->data = data;
  output->capacity = capacity;
  return true;
}

static bool append_output(captured_output *output, const char *data, size_t length,
                          cli_config *config) {
  if (length > CLI_MAX_CONFIG_BYTES - output->length - 1) {
    return fail(config, "configuration exceeds 1048576 bytes");
  }
  const size_t needed = output->length + length + 1;
  const bool needs_allocation = output->data == NULL;
  const bool needs_growth = needed > output->capacity;
  if ((needs_allocation || needs_growth) && !grow_output(output, needed, config)) {
    return false;
  }
  if (length > 0) {
    memcpy(output->data + output->length, data, length);
  }
  output->length += length;
  output->data[output->length] = '\0';
  return true;
}

static bool read_git_descriptor(int descriptor, captured_output *output,
                                cli_config *config) {
  char buffer[4096];
  ssize_t length;
  while ((length = read(descriptor, buffer, sizeof(buffer))) > 0) {
    if (!append_output(output, buffer, (size_t)length, config)) {
      close(descriptor);
      return false;
    }
  }
  close(descriptor);
  if (length < 0) {
    return fail(config, "could not read staged configuration");
  }
  return true;
}

static void quiet_git_stderr(void) {
  const int null = open("/dev/null", O_WRONLY);
  if (null == -1) {
    return;
  }
  dup2(null, STDERR_FILENO);
  close(null);
}

static void execute_git_child(const char *root, const char *const arguments[],
                              int output) {
  const bool output_failed = dup2(output, STDOUT_FILENO) == -1;
  close(output);
  quiet_git_stderr();
  const bool directory_failed = chdir(root) == -1;
  if (output_failed || directory_failed) {
    _exit(127);
  }
  execvp(arguments[0], (char *const *)arguments);
  _exit(127);
}

static bool wait_for_git(pid_t identifier, int *status, cli_config *config) {
  pid_t result;
  do {
    result = waitpid(identifier, status, 0);
  } while (result == -1 && errno == EINTR);
  if (result == -1) {
    return fail(config, "could not wait for staged configuration");
  }
  return true;
}

static pid_t start_git(const char *root, const char *const arguments[], int output) {
  const pid_t identifier = fork();
  if (identifier == 0) {
    execute_git_child(root, arguments, output);
  }
  return identifier;
}

static bool git_succeeded(pid_t identifier, cli_config *config) {
  int status = 0;
  const bool waited = wait_for_git(identifier, &status, config);
  const bool exited = waited && WIFEXITED(status);
  return exited && WEXITSTATUS(status) == 0;
}

static bool capture_git(const char *root, const char *const arguments[],
                        captured_output *output, cli_config *config) {
  int descriptors[2];
  if (pipe(descriptors) == -1) {
    return fail(config, "could not read staged configuration");
  }
  const pid_t identifier = start_git(root, arguments, descriptors[1]);
  close(descriptors[1]);
  if (identifier == -1) {
    close(descriptors[0]);
    return fail(config, "could not read staged configuration");
  }
  bool read_output = read_git_descriptor(descriptors[0], output, config);
  if (read_output && output->data == NULL) {
    read_output = append_output(output, "", 0, config);
  }
  const bool git_output = git_succeeded(identifier, config);
  return read_output && git_output;
}

static bool measure_config(FILE *stream, size_t *length, cli_config *config) {
  if (fseek(stream, 0, SEEK_END) != 0) {
    return fail(config, "could not read configuration");
  }
  const long position = ftell(stream);
  if (position < 0) {
    return fail(config, "could not read configuration");
  }
  if ((unsigned long)position > CLI_MAX_CONFIG_BYTES) {
    return fail(config, "configuration exceeds 1048576 bytes");
  }
  *length = (size_t)position;
  if (fseek(stream, 0, SEEK_SET) != 0) {
    return fail(config, "could not read configuration");
  }
  return true;
}

static bool read_config_data(FILE *stream, char *data, size_t length,
                             cli_config *config) {
  const size_t read = fread(data, 1, length, stream);
  if (read != length || ferror(stream)) {
    return fail(config, "configuration changed while reading");
  }
  const int extra = feof(stream) ? EOF : fgetc(stream);
  if (extra != EOF || ferror(stream)) {
    return fail(config, "configuration changed while reading");
  }
  data[length] = '\0';
  return true;
}

static char *load_config_data(const char *path, size_t *length, cli_config *config) {
  FILE *stream = fopen(path, "rb");
  if (stream == NULL) {
    fail(config, "could not open configuration");
    return NULL;
  }
  const bool measured = measure_config(stream, length, config);
  char *data = measured ? malloc(*length + 1) : NULL;
  if (measured && data == NULL) {
    fail(config, "could not allocate configuration");
  }
  const bool loaded = data != NULL && read_config_data(stream, data, *length, config);
  fclose(stream);
  if (loaded) {
    return data;
  }
  free(data);
  return NULL;
}

static yyjson_doc *load_document(const char *path, cli_config *config) {
  size_t length = 0;
  char *data = load_config_data(path, &length, config);
  if (data == NULL) {
    return NULL;
  }
  yyjson_read_err error;
  yyjson_doc *document = yyjson_read_opts(data, length, 0, NULL, &error);
  free(data);
  if (document == NULL) {
    fail(config, error.msg);
  }
  return document;
}

static yyjson_doc *load_document_data(const char *data, size_t length,
                                      cli_config *config) {
  yyjson_read_err error;
  yyjson_doc *document = yyjson_read_opts((char *)data, length, 0, NULL, &error);
  if (document == NULL) {
    fail(config, error.msg);
  }
  return document;
}

static size_t find_key(const char *name, const expected_key *keys, size_t key_count) {
  for (size_t index = 0; index < key_count; index += 1) {
    if (strcmp(name, keys[index].name) == 0) {
      return index;
    }
  }
  return key_count;
}

static bool record_key(const char *name, expected_key *keys, size_t key_count,
                       cli_config *config) {
  const size_t index = find_key(name, keys, key_count);
  if (index == key_count) {
    snprintf(config->error, sizeof(config->error), "unknown configuration key: %s",
             name);
    return false;
  }
  if (keys[index].seen) {
    snprintf(config->error, sizeof(config->error), "duplicate configuration key: %s",
             name);
    return false;
  }
  keys[index].seen = true;
  return true;
}

static bool has_embedded_nul(yyjson_val *value) {
  const char *string = yyjson_get_str(value);
  const size_t length = yyjson_get_len(value);
  return string != NULL && memchr(string, '\0', length) != NULL;
}

static bool has_embedded_nul_bytes(const char *value, size_t length) {
  return value != NULL && memchr(value, '\0', length) != NULL;
}

static bool validate_keys(yyjson_val *object, expected_key *keys, size_t key_count,
                          cli_config *config) {
  size_t index;
  size_t maximum;
  yyjson_val *key;
  yyjson_val *value;
  yyjson_obj_foreach(object, index, maximum, key, value) {
    (void)value;
    if (has_embedded_nul(key)) {
      return fail(config, "configuration key must not contain embedded NUL bytes");
    }
    if (!record_key(yyjson_get_str(key), keys, key_count, config)) {
      return false;
    }
  }
  return true;
}

static bool validate_root_keys(yyjson_val *root, cli_config *config) {
  expected_key keys[] = {{"version", false}, {"newFiles", false}};
  return validate_keys(root, keys, 2, config);
}

static bool validate_new_file_keys(yyjson_val *new_files, cli_config *config) {
  expected_key keys[] = {{"default", false}, {"allow", false}};
  return validate_keys(new_files, keys, 2, config);
}

static bool read_version(yyjson_val *root, cli_config *config) {
  yyjson_val *version = yyjson_obj_get(root, "version");
  const bool supported = yyjson_is_uint(version) && yyjson_get_uint(version) == 1;
  if (!supported) {
    return fail(config, "version must be 1");
  }
  return true;
}

static bool read_default(yyjson_val *new_files, cli_config *config) {
  yyjson_val *value = yyjson_obj_get(new_files, "default");
  if (value == NULL) {
    return true;
  }
  const char *setting = yyjson_get_str(value);
  if (setting == NULL || has_embedded_nul(value)) {
    return fail(config, "newFiles.default must be \"allow\" or \"deny\"");
  }
  if (strcmp(setting, "deny") == 0) {
    config->policy.new_files_default = LEGIBILITY_NEW_FILES_DENY;
    return true;
  }
  if (strcmp(setting, "allow") == 0) {
    config->policy.new_files_default = LEGIBILITY_NEW_FILES_ALLOW;
    return true;
  }
  return fail(config, "newFiles.default must be \"allow\" or \"deny\"");
}

static bool allocate_patterns(size_t count, cli_config *config) {
  if (count == 0) {
    return true;
  }
  config->owned_allow_patterns = calloc(count, sizeof(*config->owned_allow_patterns));
  if (config->owned_allow_patterns == NULL) {
    return fail(config, "could not allocate allow patterns");
  }
  config->policy.allow_patterns = (const char *const *)config->owned_allow_patterns;
  config->policy.allow_pattern_count = count;
  return true;
}

static size_t current_pattern_bytes(const cli_config *config) {
  size_t total = 0;
  for (size_t index = 0; index < config->policy.allow_pattern_count; index += 1) {
    total += strlen(config->owned_allow_patterns[index]);
  }
  return total;
}

static bool valid_extra_pattern_count(size_t current, size_t extra,
                                      cli_config *config) {
  if (extra > CLI_MAX_ALLOW_PATTERNS - current) {
    return fail(config, "newFiles.allow exceeds 4096 patterns");
  }
  return true;
}

static bool grow_patterns(cli_config *config, size_t pattern_count) {
  char **patterns = realloc(config->owned_allow_patterns,
                            pattern_count * sizeof(*config->owned_allow_patterns));
  if (patterns == NULL) {
    return fail(config, "could not allocate allow patterns");
  }
  config->owned_allow_patterns = patterns;
  config->policy.allow_patterns = (const char *const *)patterns;
  return true;
}

static bool add_pattern_size(const char *pattern, size_t *total, cli_config *config) {
  const size_t length = strlen(pattern);
  if (length > LEGIBILITY_MAX_PATTERN_LENGTH) {
    return fail(config, "allow pattern exceeds LEGIBILITY_MAX_PATTERN_LENGTH");
  }
  if (length > CLI_MAX_ALLOW_PATTERN_BYTES - *total) {
    return fail(config, "newFiles.allow exceeds 262144 bytes");
  }
  *total += length;
  return true;
}

static bool copy_pattern(yyjson_val *value, size_t index, size_t *total,
                         cli_config *config) {
  const char *pattern = yyjson_get_str(value);
  if (pattern == NULL) {
    return fail(config, "newFiles.allow must contain only strings");
  }
  if (has_embedded_nul(value)) {
    return fail(config, "newFiles.allow must not contain embedded NUL bytes");
  }
  if (!add_pattern_size(pattern, total, config)) {
    return false;
  }
  config->owned_allow_patterns[index] = copy_string(pattern);
  if (config->owned_allow_patterns[index] == NULL) {
    return fail(config, "could not allocate allow pattern");
  }
  return true;
}

static bool read_allow(yyjson_val *new_files, cli_config *config) {
  yyjson_val *allow = yyjson_obj_get(new_files, "allow");
  if (allow == NULL) {
    return true;
  }
  if (!yyjson_is_arr(allow)) {
    return fail(config, "newFiles.allow must be an array of strings");
  }
  const size_t count = yyjson_arr_size(allow);
  if (count > CLI_MAX_ALLOW_PATTERNS) {
    return fail(config, "newFiles.allow exceeds 4096 patterns");
  }
  if (!allocate_patterns(count, config)) {
    return false;
  }

  size_t index;
  size_t maximum;
  size_t total = 0;
  yyjson_val *value;
  yyjson_arr_foreach(allow, index, maximum, value) {
    if (!copy_pattern(value, index, &total, config)) {
      return false;
    }
  }
  return true;
}

static bool read_new_files(yyjson_val *root, cli_config *config) {
  yyjson_val *new_files = yyjson_obj_get(root, "newFiles");
  if (!yyjson_is_obj(new_files)) {
    return fail(config, "newFiles must be an object");
  }
  if (!validate_new_file_keys(new_files, config)) {
    return false;
  }
  return read_default(new_files, config) && read_allow(new_files, config);
}

static bool parse_json_document(yyjson_doc *document, cli_config *config) {
  yyjson_val *root = yyjson_doc_get_root(document);
  if (!yyjson_is_obj(root)) {
    return fail(config, "configuration must be an object");
  }
  if (!validate_root_keys(root, config)) {
    return false;
  }
  return read_version(root, config) && read_new_files(root, config);
}

static bool validate_toml_keys(toml_datum_t table, expected_key *keys, size_t key_count,
                               cli_config *config) {
  if (table.type != TOML_TABLE) {
    return fail(config, "configuration must be an object");
  }
  for (int32_t index = 0; index < table.u.tab.size; index += 1) {
    const char *key = table.u.tab.key[index];
    const int key_length = table.u.tab.len[index];
    if (key_length < 0 || has_embedded_nul_bytes(key, (size_t)key_length)) {
      return fail(config, "configuration key must not contain embedded NUL bytes");
    }
    if (!record_key(key, keys, key_count, config)) {
      return false;
    }
  }
  return true;
}

static bool validate_toml_root_keys(toml_datum_t root, cli_config *config) {
  expected_key keys[] = {{"version", false}, {"newFiles", false}};
  return validate_toml_keys(root, keys, 2, config);
}

static bool validate_toml_new_file_keys(toml_datum_t new_files, cli_config *config) {
  expected_key keys[] = {{"default", false}, {"allow", false}};
  return validate_toml_keys(new_files, keys, 2, config);
}

static bool read_toml_version(toml_datum_t root, cli_config *config) {
  const toml_datum_t version = toml_get(root, "version");
  const bool supported = version.type == TOML_INT64 && version.u.int64 == 1;
  if (!supported) {
    return fail(config, "version must be 1");
  }
  return true;
}

static bool read_toml_default(toml_datum_t new_files, cli_config *config) {
  const toml_datum_t value = toml_get(new_files, "default");
  if (value.type == TOML_UNKNOWN) {
    return true;
  }
  if (value.type != TOML_STRING ||
      has_embedded_nul_bytes(value.u.str.ptr, (size_t)value.u.str.len)) {
    return fail(config, "newFiles.default must be \"allow\" or \"deny\"");
  }
  if (strcmp(value.u.s, "deny") == 0) {
    config->policy.new_files_default = LEGIBILITY_NEW_FILES_DENY;
    return true;
  }
  if (strcmp(value.u.s, "allow") == 0) {
    config->policy.new_files_default = LEGIBILITY_NEW_FILES_ALLOW;
    return true;
  }
  return fail(config, "newFiles.default must be \"allow\" or \"deny\"");
}

static bool copy_toml_pattern(toml_datum_t value, size_t index, size_t *total,
                              cli_config *config) {
  if (value.type != TOML_STRING) {
    return fail(config, "newFiles.allow must contain only strings");
  }
  if (has_embedded_nul_bytes(value.u.str.ptr, (size_t)value.u.str.len)) {
    return fail(config, "newFiles.allow must not contain embedded NUL bytes");
  }
  if (!add_pattern_size(value.u.s, total, config)) {
    return false;
  }
  config->owned_allow_patterns[index] = copy_string(value.u.s);
  if (config->owned_allow_patterns[index] == NULL) {
    return fail(config, "could not allocate allow pattern");
  }
  return true;
}

static bool read_toml_allow(toml_datum_t new_files, cli_config *config) {
  const toml_datum_t allow = toml_get(new_files, "allow");
  if (allow.type == TOML_UNKNOWN) {
    return true;
  }
  if (allow.type != TOML_ARRAY) {
    return fail(config, "newFiles.allow must be an array of strings");
  }
  if (allow.u.arr.size < 0 || (size_t)allow.u.arr.size > CLI_MAX_ALLOW_PATTERNS) {
    return fail(config, "newFiles.allow exceeds 4096 patterns");
  }
  const size_t count = (size_t)allow.u.arr.size;
  if (!allocate_patterns(count, config)) {
    return false;
  }

  size_t total = 0;
  for (size_t index = 0; index < count; index += 1) {
    if (!copy_toml_pattern(allow.u.arr.elem[index], index, &total, config)) {
      return false;
    }
  }
  return true;
}

static bool read_toml_new_files(toml_datum_t root, cli_config *config) {
  const toml_datum_t new_files = toml_get(root, "newFiles");
  if (new_files.type != TOML_TABLE) {
    return fail(config, "newFiles must be an object");
  }
  if (!validate_toml_new_file_keys(new_files, config)) {
    return false;
  }
  return read_toml_default(new_files, config) && read_toml_allow(new_files, config);
}

static bool parse_toml_document(const char *path, cli_config *config) {
  size_t length = 0;
  char *data = load_config_data(path, &length, config);
  if (data == NULL) {
    return false;
  }

  toml_result_t document = toml_parse_named(data, (int)length, path);
  free(data);
  if (!document.ok) {
    const bool valid = fail(config, document.errmsg);
    toml_free(document);
    return valid;
  }
  bool valid = validate_toml_root_keys(document.toptab, config);
  if (valid) {
    valid = read_toml_version(document.toptab, config) &&
            read_toml_new_files(document.toptab, config);
  }
  toml_free(document);
  return valid;
}

static bool parse_json_path(const char *path, cli_config *config) {
  yyjson_doc *document = load_document(path, config);
  if (document == NULL) {
    return false;
  }
  const bool valid = parse_json_document(document, config);
  yyjson_doc_free(document);
  return valid;
}

static bool parse_json_data(const char *data, size_t length, cli_config *config) {
  yyjson_doc *document = load_document_data(data, length, config);
  if (document == NULL) {
    return false;
  }
  const bool valid = parse_json_document(document, config);
  yyjson_doc_free(document);
  return valid;
}

static bool parse_toml_data(const char *path, const char *data, size_t length,
                            cli_config *config) {
  toml_result_t document = toml_parse_named(data, (int)length, path);
  if (!document.ok) {
    const bool valid = fail(config, document.errmsg);
    toml_free(document);
    return valid;
  }
  bool valid = validate_toml_root_keys(document.toptab, config);
  if (valid) {
    valid = read_toml_version(document.toptab, config) &&
            read_toml_new_files(document.toptab, config);
  }
  toml_free(document);
  return valid;
}

static bool parse_config_data(const char *path, const char *data, size_t length,
                              cli_config *config) {
  if (is_toml_path(path)) {
    return parse_toml_data(path, data, length, config);
  }
  return parse_json_data(data, length, config);
}

static bool parse_config_path(const char *path, cli_config *config) {
  if (is_toml_path(path)) {
    return parse_toml_document(path, config);
  }
  return parse_json_path(path, config);
}

static bool handle_missing_path(const char *root, cli_config *config) {
  if (config->error[0] == '\0') {
    return fail(config, "could not allocate configuration path");
  }
  config->source_path = copy_string(root);
  return false;
}

static char *locate_config(const char *root, const char *config_path,
                           cli_config *config) {
  if (config_path != NULL) {
    return resolve_config_path(root, config_path);
  }
  return legibility_discover_config(root, config->error, sizeof(config->error));
}

bool cli_config_load(const char *root, const char *config_path, cli_config *config) {
  memset(config, 0, sizeof(*config));
  config->source_path = locate_config(root, config_path, config);
  if (config->source_path == NULL) {
    return handle_missing_path(root, config);
  }

  const char *unsupported_format = format_error(config->source_path);
  if (unsupported_format != NULL) {
    return fail(config, unsupported_format);
  }

  return parse_config_path(config->source_path, config);
}

static char *copy_index_path(const captured_output *output) {
  if (output->length == 0) {
    return NULL;
  }
  size_t length = 0;
  while (length < output->length && output->data[length] != '\n') {
    length += 1;
  }
  char *path = malloc(length + 1);
  if (path == NULL) {
    return NULL;
  }
  memcpy(path, output->data, length);
  path[length] = '\0';
  return path;
}

static char *git_index_path(const char *root, const char *source_path,
                            cli_config *config) {
  captured_output output = {0};
  const char *const arguments[] = {
      "git", "ls-files", "--full-name", "--", source_path, NULL,
  };
  const bool captured = capture_git(root, arguments, &output, config);
  char *path = captured ? copy_index_path(&output) : NULL;
  free(output.data);
  return path;
}

static char *git_show_spec(const char *path) {
  const size_t size = strlen(path) + 2;
  char *spec = malloc(size);
  if (spec != NULL) {
    snprintf(spec, size, ":%s", path);
  }
  return spec;
}

static bool load_staged_config_data(const char *root, const char *path,
                                    captured_output *output, cli_config *config) {
  char *spec = git_show_spec(path);
  if (spec == NULL) {
    return fail(config, "could not allocate configuration path");
  }
  const char *const arguments[] = {"git", "show", spec, NULL};
  const bool captured = capture_git(root, arguments, output, config);
  free(spec);
  return captured;
}

static bool parse_staged_config(const char *root, cli_config *config) {
  char *path = git_index_path(root, config->source_path, config);
  if (path == NULL) {
    return fail(config, "no configuration file found");
  }
  captured_output output = {0};
  const bool loaded = load_staged_config_data(root, path, &output, config);
  free(path);
  if (!loaded) {
    free(output.data);
    return false;
  }
  const bool parsed =
      parse_config_data(config->source_path, output.data, output.length, config);
  free(output.data);
  return parsed;
}

bool cli_config_load_staged(const char *root, const char *config_path,
                            cli_config *config) {
  memset(config, 0, sizeof(*config));
  config->source_path = locate_config(root, config_path, config);
  if (config->source_path == NULL) {
    return handle_missing_path(root, config);
  }

  const char *unsupported_format = format_error(config->source_path);
  if (unsupported_format != NULL) {
    return fail(config, unsupported_format);
  }

  return parse_staged_config(root, config);
}

bool cli_config_append_patterns(cli_config *config, const char *const *patterns,
                                size_t pattern_count) {
  const size_t current = config->policy.allow_pattern_count;
  if (pattern_count == 0) {
    return true;
  }
  if (!valid_extra_pattern_count(current, pattern_count, config)) {
    return false;
  }
  if (!grow_patterns(config, current + pattern_count)) {
    return false;
  }

  size_t total = current_pattern_bytes(config);
  for (size_t index = 0; index < pattern_count; index += 1) {
    if (!add_pattern_size(patterns[index], &total, config)) {
      return false;
    }
    config->owned_allow_patterns[current + index] = copy_string(patterns[index]);
    if (config->owned_allow_patterns[current + index] == NULL) {
      return fail(config, "could not allocate allow pattern");
    }
    config->policy.allow_pattern_count += 1;
  }
  return true;
}

void cli_config_destroy(cli_config *config) {
  for (size_t index = 0; index < config->policy.allow_pattern_count; index += 1) {
    free(config->owned_allow_patterns[index]);
  }
  free(config->owned_allow_patterns);
  free(config->source_path);
  memset(config, 0, sizeof(*config));
}
