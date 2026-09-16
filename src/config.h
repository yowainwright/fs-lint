#ifndef FS_LINT_CONFIG_H
#define FS_LINT_CONFIG_H

#include "fs-lint.h"

#include <stdbool.h>
#include <stddef.h>

typedef struct {
  fs_lint_config policy;
  char **owned_allow_patterns;
  char *source_path;
  char error[256];
} cli_config;

bool cli_config_load(const char *root, const char *config_path, cli_config *config);

bool cli_config_load_staged(const char *root, const char *config_path,
                            cli_config *config);

bool cli_config_append_patterns(cli_config *config, const char *const *patterns,
                                size_t pattern_count);

void cli_config_destroy(cli_config *config);

#endif
