#include "changes.h"
#include "cli_output.h"
#include "config.h"
#include "legibility.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum { CLI_CONFIG, CLI_CHECK_PATH, CLI_CHECK } cli_command;

typedef struct {
  const char *root;
  const char *config_path;
  const char *base;
  cli_output_format format;
  cli_command command;
  const char **paths;
  size_t path_count;
  size_t path_capacity;
  char **override_patterns;
  size_t override_pattern_count;
  size_t override_pattern_capacity;
  bool stdin0;
  bool staged;
  char error[128];
} cli_arguments;

static void print_usage(FILE *stream) {
  fputs("usage: fs-lint [--root path] [--config path] [--format text|json] "
        "[--allow pattern] [--deny pattern]\n",
        stream);
  fputs("usage: fs-lint check [--root path] [--config path] [--format text|json] "
        "[--allow pattern] [--deny pattern] [--] <path>...\n",
        stream);
  fputs("usage: fs-lint check (--stdin0|--staged|--base ref) [--root path] "
        "[--config path] [--format text|json] [--allow pattern] [--deny pattern]\n",
        stream);
  fputs("usage: fs-lint check-path [--root path] [--config path] "
        "[--format text|json] [--allow pattern] [--deny pattern] [--] <path>\n",
        stream);
}

static int usage(const cli_arguments *arguments) {
  if (arguments->error[0] != '\0') {
    fprintf(stderr, "fs-lint: %s\n", arguments->error);
    return LEGIBILITY_STATUS_ERROR;
  }
  print_usage(stderr);
  return LEGIBILITY_STATUS_ERROR;
}

static bool wants_help(int argc, char **argv) {
  if (argc != 2) {
    return false;
  }
  return strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0;
}

static bool wants_version(int argc, char **argv) {
  return argc == 2 && strcmp(argv[1], "--version") == 0;
}

static void initialize_arguments(cli_arguments *arguments) {
  *arguments = (cli_arguments){
      .root = ".",
      .format = CLI_OUTPUT_TEXT,
  };
}

static void destroy_arguments(cli_arguments *arguments) {
  for (size_t index = 0; index < arguments->override_pattern_count; index += 1) {
    free(arguments->override_patterns[index]);
  }
  free(arguments->override_patterns);
  free(arguments->paths);
  memset(arguments, 0, sizeof(*arguments));
}

static bool read_command(const char *value, cli_arguments *arguments) {
  if (strcmp(value, "check-path") == 0) {
    arguments->command = CLI_CHECK_PATH;
    return true;
  }
  if (strcmp(value, "check") == 0) {
    arguments->command = CLI_CHECK;
    return true;
  }
  return false;
}

static const char *next_value(int argc, char **argv, size_t *index) {
  *index += 1;
  if (*index >= (size_t)argc) {
    return NULL;
  }
  const char *value = argv[*index];
  *index += 1;
  return value;
}

static bool read_format(int argc, char **argv, size_t *index,
                        cli_arguments *arguments) {
  const char *value = next_value(argc, argv, index);
  if (value == NULL) {
    return false;
  }
  if (strcmp(value, "json") == 0) {
    arguments->format = CLI_OUTPUT_JSON;
    return true;
  }
  if (strcmp(value, "text") == 0) {
    arguments->format = CLI_OUTPUT_TEXT;
    return true;
  }
  return false;
}

static bool read_string_option(int argc, char **argv, size_t *index,
                               const char **destination) {
  const char *value = next_value(argc, argv, index);
  if (value == NULL) {
    return false;
  }
  *destination = value;
  return true;
}

static bool set_parse_error(cli_arguments *arguments, const char *message) {
  snprintf(arguments->error, sizeof(arguments->error), "%s", message);
  return false;
}

static char *copy_pattern_override(const char *value, bool denied) {
  const size_t prefix = denied ? 1U : 0U;
  const size_t size = strlen(value) + prefix + 1U;
  char *pattern = malloc(size);
  if (pattern == NULL) {
    return NULL;
  }
  if (denied) {
    pattern[0] = '!';
  }
  memcpy(pattern + prefix, value, size - prefix);
  return pattern;
}

static bool grow_override_patterns(cli_arguments *arguments) {
  const size_t doubled = arguments->override_pattern_capacity * 2U;
  const size_t capacity = arguments->override_pattern_capacity == 0 ? 4U : doubled;
  char **patterns = realloc(arguments->override_patterns,
                            capacity * sizeof(*arguments->override_patterns));
  if (patterns == NULL) {
    return set_parse_error(arguments, "could not allocate CLI patterns");
  }
  arguments->override_patterns = patterns;
  arguments->override_pattern_capacity = capacity;
  return true;
}

static bool append_pattern_override(cli_arguments *arguments, const char *value,
                                    bool denied) {
  if (value[0] == '!') {
    const char *option = denied ? "--deny" : "--allow";
    snprintf(arguments->error, sizeof(arguments->error),
             "%s patterns must not start with !", option);
    return false;
  }
  const bool needs_capacity =
      arguments->override_pattern_count == arguments->override_pattern_capacity;
  if (needs_capacity && !grow_override_patterns(arguments)) {
    return false;
  }
  char *pattern = copy_pattern_override(value, denied);
  if (pattern == NULL) {
    return set_parse_error(arguments, "could not allocate CLI pattern");
  }
  arguments->override_patterns[arguments->override_pattern_count] = pattern;
  arguments->override_pattern_count += 1;
  return true;
}

static bool read_pattern_option(int argc, char **argv, size_t *index,
                                cli_arguments *arguments, bool denied) {
  const char *value = next_value(argc, argv, index);
  if (value == NULL) {
    return false;
  }
  return append_pattern_override(arguments, value, denied);
}

static bool read_flag(size_t *index, bool *destination) {
  if (*destination) {
    return false;
  }
  *destination = true;
  *index += 1;
  return true;
}

static bool read_source_option(int argc, char **argv, const char *option, size_t *index,
                               cli_arguments *arguments) {
  if (strcmp(option, "--stdin0") == 0) {
    return read_flag(index, &arguments->stdin0);
  }
  if (strcmp(option, "--staged") == 0) {
    return read_flag(index, &arguments->staged);
  }
  if (strcmp(option, "--base") == 0 && arguments->base == NULL) {
    return read_string_option(argc, argv, index, &arguments->base);
  }
  return false;
}

static bool parse_option(int argc, char **argv, size_t *index,
                         cli_arguments *arguments) {
  const char *option = argv[*index];
  if (strcmp(option, "--root") == 0) {
    return read_string_option(argc, argv, index, &arguments->root);
  }
  if (strcmp(option, "--config") == 0) {
    return read_string_option(argc, argv, index, &arguments->config_path);
  }
  if (strcmp(option, "--format") == 0) {
    return read_format(argc, argv, index, arguments);
  }
  if (strcmp(option, "--allow") == 0) {
    return read_pattern_option(argc, argv, index, arguments, false);
  }
  if (strcmp(option, "--deny") == 0) {
    return read_pattern_option(argc, argv, index, arguments, true);
  }
  return read_source_option(argc, argv, option, index, arguments);
}

static bool grow_paths(cli_arguments *arguments) {
  const size_t doubled = arguments->path_capacity * 2U;
  const size_t capacity = arguments->path_capacity == 0 ? 4U : doubled;
  const char **paths = realloc(arguments->paths, capacity * sizeof(*paths));
  if (paths == NULL) {
    return set_parse_error(arguments, "could not allocate paths");
  }
  arguments->paths = paths;
  arguments->path_capacity = capacity;
  return true;
}

static bool append_path(const char *path, size_t *index, cli_arguments *arguments) {
  const bool needs_capacity = arguments->path_count == arguments->path_capacity;
  if (needs_capacity && !grow_paths(arguments)) {
    return false;
  }
  arguments->paths[arguments->path_count] = path;
  arguments->path_count += 1;
  *index += 1;
  return true;
}

static bool read_subcommand(const char *token, size_t *index,
                            cli_arguments *arguments) {
  if (arguments->command != CLI_CONFIG) {
    return false;
  }
  if (!read_command(token, arguments)) {
    return false;
  }
  *index += 1;
  return true;
}

static bool parse_token(int argc, char **argv, size_t *index, bool *options_ended,
                        cli_arguments *arguments) {
  if (*options_ended) {
    return append_path(argv[*index], index, arguments);
  }
  if (strcmp(argv[*index], "--") == 0) {
    *options_ended = true;
    *index += 1;
    return true;
  }
  if (read_subcommand(argv[*index], index, arguments)) {
    return true;
  }
  const bool is_option = argv[*index][0] == '-';
  if (is_option) {
    return parse_option(argc, argv, index, arguments);
  }
  return append_path(argv[*index], index, arguments);
}

static size_t count_sources(const cli_arguments *arguments) {
  const size_t stdin_count = arguments->stdin0 ? 1U : 0U;
  const size_t staged_count = arguments->staged ? 1U : 0U;
  const size_t base_count = arguments->base != NULL ? 1U : 0U;
  return stdin_count + staged_count + base_count;
}

static bool valid_base(const cli_arguments *arguments) {
  const bool absent = arguments->base == NULL;
  if (absent) {
    return true;
  }
  const bool nonempty = arguments->base[0] != '\0';
  const bool not_option = arguments->base[0] != '-';
  return nonempty && not_option;
}

static bool valid_arguments(const cli_arguments *arguments) {
  if (arguments->command == CLI_CONFIG) {
    const bool no_paths = arguments->path_count == 0;
    const bool no_sources = count_sources(arguments) == 0;
    return no_paths && no_sources;
  }
  if (arguments->command == CLI_CHECK_PATH) {
    const bool no_source = count_sources(arguments) == 0;
    return arguments->path_count == 1 && no_source;
  }
  const bool path_check = arguments->path_count > 0 && count_sources(arguments) == 0;
  const bool source_check = arguments->path_count == 0 && count_sources(arguments) == 1;
  const bool one_source = path_check || source_check;
  const bool valid_source = one_source && valid_base(arguments);
  return arguments->command == CLI_CHECK && valid_source;
}

static bool parse_arguments(int argc, char **argv, cli_arguments *arguments) {
  initialize_arguments(arguments);
  size_t index = 1;
  bool options_ended = false;
  while (index < (size_t)argc) {
    if (!parse_token(argc, argv, &index, &options_ended, arguments)) {
      return false;
    }
  }
  return valid_arguments(arguments);
}

static void report_cli_error(const char *code, const char *path, const char *message,
                             cli_output *output) {
  const legibility_diagnostic diagnostic = {
      .severity = LEGIBILITY_SEVERITY_ERROR,
      .code = code,
      .path = path,
      .message = message,
  };
  cli_report(&diagnostic, output);
}

static int run_checks(const cli_arguments *arguments, const legibility_change *changes,
                      size_t change_count) {
  cli_output output = {.format = arguments->format, .stream = stdout};
  cli_config config;
  const bool loaded =
      arguments->staged
          ? cli_config_load_staged(arguments->root, arguments->config_path, &config)
          : cli_config_load(arguments->root, arguments->config_path, &config);
  if (!loaded) {
    report_cli_error("config/invalid", config.source_path, config.error, &output);
    cli_config_destroy(&config);
    return LEGIBILITY_STATUS_ERROR;
  }
  const bool appended = cli_config_append_patterns(
      &config, (const char *const *)arguments->override_patterns,
      arguments->override_pattern_count);
  if (!appended) {
    report_cli_error("config/invalid", config.source_path, config.error, &output);
    cli_config_destroy(&config);
    return LEGIBILITY_STATUS_ERROR;
  }
  const legibility_status status =
      legibility_check(&config.policy, changes, change_count, cli_report, &output);
  cli_config_destroy(&config);
  return (int)status;
}

static int validate_config(const cli_arguments *arguments) {
  return run_checks(arguments, NULL, 0);
}

static int check_paths(const cli_arguments *arguments) {
  legibility_change *changes = calloc(arguments->path_count, sizeof(*changes));
  if (changes == NULL) {
    fputs("fs-lint: could not allocate paths\n", stderr);
    return LEGIBILITY_STATUS_ERROR;
  }
  for (size_t index = 0; index < arguments->path_count; index += 1) {
    changes[index] = (legibility_change){
        .path = arguments->paths[index],
        .kind = LEGIBILITY_CHANGE_ADDED,
    };
  }
  const int status = run_checks(arguments, changes, arguments->path_count);
  free(changes);
  return status;
}

static bool load_batch_changes(const cli_arguments *arguments, cli_changes *changes) {
  if (arguments->stdin0) {
    return cli_changes_read_nul(stdin, changes);
  }
  if (arguments->staged) {
    return cli_changes_read_git_staged(arguments->root, changes);
  }
  return cli_changes_read_git_base(arguments->root, arguments->base, changes);
}

static int check_batch(const cli_arguments *arguments) {
  cli_changes changes;
  const bool loaded = load_batch_changes(arguments, &changes);
  if (!loaded) {
    cli_output output = {.format = arguments->format, .stream = stdout};
    report_cli_error("input/invalid", "", changes.error, &output);
    cli_changes_destroy(&changes);
    return LEGIBILITY_STATUS_ERROR;
  }
  const int status = run_checks(arguments, changes.items, changes.count);
  cli_changes_destroy(&changes);
  return status;
}

int main(int argc, char **argv) {
  cli_arguments arguments;
  initialize_arguments(&arguments);
  if (wants_help(argc, argv)) {
    print_usage(stdout);
    return LEGIBILITY_STATUS_OK;
  }
  if (wants_version(argc, argv)) {
    printf("fs-lint %s\n", FS_LINT_VERSION);
    return LEGIBILITY_STATUS_OK;
  }
  if (!parse_arguments(argc, argv, &arguments)) {
    const int status = usage(&arguments);
    destroy_arguments(&arguments);
    return status;
  }
  int status = LEGIBILITY_STATUS_ERROR;
  if (arguments.command == CLI_CONFIG) {
    status = validate_config(&arguments);
  } else if (arguments.path_count > 0) {
    status = check_paths(&arguments);
  } else {
    status = check_batch(&arguments);
  }
  destroy_arguments(&arguments);
  return status;
}
