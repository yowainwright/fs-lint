#include "cli_output.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fail(const char *message, FILE *stream) {
  fclose(stream);
  fputs(message, stderr);
  fputc('\n', stderr);
  exit(EXIT_FAILURE);
}

static void expect_null_path(cli_output_format format, const char *expected) {
  FILE *stream = tmpfile();
  if (stream == NULL) {
    fputs("could not create output stream\n", stderr);
    exit(EXIT_FAILURE);
  }
  const legibility_diagnostic diagnostic = {
      .severity = LEGIBILITY_SEVERITY_ERROR,
      .code = "config/invalid",
      .path = NULL,
      .message = "could not allocate configuration path",
  };
  cli_output output = {.format = format, .stream = stream};
  cli_report(&diagnostic, &output);
  if (fseek(stream, 0, SEEK_SET) != 0) {
    fail("could not rewind output stream", stream);
  }

  char line[256] = {0};
  if (fgets(line, sizeof(line), stream) == NULL) {
    fail("expected a diagnostic", stream);
  }
  if (strstr(line, expected) == NULL) {
    fail("expected a null path to be encoded as an empty string", stream);
  }
  fclose(stream);
}

int main(void) {
  expect_null_path(CLI_OUTPUT_JSON, "\"path\":\"\"");
  expect_null_path(CLI_OUTPUT_TEXT, ": error config/invalid");
  return EXIT_SUCCESS;
}
