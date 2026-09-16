#ifndef FS_LINT_CLI_OUTPUT_H
#define FS_LINT_CLI_OUTPUT_H

#include "fs-lint.h"

#include <stdio.h>

typedef enum { CLI_OUTPUT_TEXT, CLI_OUTPUT_JSON } cli_output_format;

typedef struct {
  cli_output_format format;
  FILE *stream;
} cli_output;

void cli_report(const fs_lint_diagnostic *diagnostic, void *user_data);

#endif
