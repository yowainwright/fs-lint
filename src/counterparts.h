#ifndef FS_LINT_COUNTERPARTS_H
#define FS_LINT_COUNTERPARTS_H

#include "changes.h"
#include "cli_output.h"
#include "config.h"

typedef struct {
  const cli_config *config;
  const char *root;
  const cli_changes *targets;
  cli_output *output;
  bool staged;
  bool committed;
} cli_counterpart_context;

bool cli_counterpart_pattern_valid(const char *pattern);

fs_lint_status cli_counterparts_check(const cli_counterpart_context *context,
                                      const fs_lint_change *changes, size_t count);

#endif
