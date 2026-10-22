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

static inline void cli_report_error(const char *code, const char *path,
                                    const char *message, cli_output *output) {
  const fs_lint_diagnostic diagnostic = {
      .severity = FS_LINT_SEVERITY_ERROR,
      .code = code,
      .path = path,
      .message = message,
  };
  cli_report(&diagnostic, output);
}

#endif
