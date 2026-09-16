#include "cli_output.h"

#include <stdbool.h>
#include <string.h>

static const char *safe_string(const char *value) { return value == NULL ? "" : value; }

static const char *severity_name(fs_lint_severity severity) {
  return severity == FS_LINT_SEVERITY_WARNING ? "warning" : "error";
}

static bool is_continuation(unsigned char value) {
  return value >= 0x80 && value <= 0xbf;
}

static bool valid_three_byte_sequence(const unsigned char *value) {
  if (!is_continuation(value[1]) || !is_continuation(value[2])) {
    return false;
  }
  if (value[0] == 0xe0) {
    return value[1] >= 0xa0;
  }
  if (value[0] == 0xed) {
    return value[1] <= 0x9f;
  }
  return true;
}

static bool valid_four_byte_sequence(const unsigned char *value) {
  const bool continuations = is_continuation(value[1]) && is_continuation(value[2]) &&
                             is_continuation(value[3]);
  if (!continuations) {
    return false;
  }
  if (value[0] == 0xf0) {
    return value[1] >= 0x90;
  }
  if (value[0] == 0xf4) {
    return value[1] <= 0x8f;
  }
  return true;
}

static size_t utf8_sequence_length(const unsigned char *value, size_t remaining) {
  if (value[0] < 0x80) {
    return 1;
  }
  const bool valid_two = remaining >= 2 && value[0] >= 0xc2 && value[0] <= 0xdf &&
                         is_continuation(value[1]);
  if (valid_two) {
    return 2;
  }
  const bool valid_three = remaining >= 3 && value[0] >= 0xe0 && value[0] <= 0xef &&
                           valid_three_byte_sequence(value);
  if (valid_three) {
    return 3;
  }
  const bool valid_four = remaining >= 4 && value[0] >= 0xf0 && value[0] <= 0xf4 &&
                          valid_four_byte_sequence(value);
  return valid_four ? 4 : 0;
}

static void write_control_character(FILE *stream, unsigned char value) {
  switch (value) {
  case '\b':
    fputs("\\b", stream);
    return;
  case '\f':
    fputs("\\f", stream);
    return;
  case '\n':
    fputs("\\n", stream);
    return;
  case '\r':
    fputs("\\r", stream);
    return;
  case '\t':
    fputs("\\t", stream);
    return;
  default:
    fprintf(stream, "\\u%04x", (unsigned int)value);
  }
}

static void write_nonquote_character(FILE *stream, unsigned char value) {
  if (value < 0x20) {
    write_control_character(stream, value);
    return;
  }
  fputc(value, stream);
}

static void write_json_character(FILE *stream, unsigned char value) {
  const int needs_escape = value == '"' || value == '\\';
  if (needs_escape) {
    fputc('\\', stream);
    fputc(value, stream);
    return;
  }
  write_nonquote_character(stream, value);
}

typedef void (*byte_writer)(FILE *stream, unsigned char value);

static void write_single_byte(FILE *stream, unsigned char value, bool valid,
                              byte_writer write_ascii, byte_writer write_invalid) {
  if (valid) {
    write_ascii(stream, value);
    return;
  }
  write_invalid(stream, value);
}

static void write_utf8_string(FILE *stream, const char *value, byte_writer write_ascii,
                              byte_writer write_invalid) {
  const unsigned char *bytes = (const unsigned char *)safe_string(value);
  size_t remaining = strlen((const char *)bytes);
  while (remaining > 0) {
    size_t length = utf8_sequence_length(bytes, remaining);
    const bool valid_multibyte = length > 1 && length <= remaining;
    if (valid_multibyte) {
      fwrite(bytes, 1, length, stream);
    } else {
      const bool valid = length == 1;
      write_single_byte(stream, bytes[0], valid, write_ascii, write_invalid);
      length = 1;
    }
    bytes += length;
    remaining -= length;
  }
}

static void write_invalid_json_byte(FILE *stream, unsigned char value) {
  fprintf(stream, "\\u%04x", (unsigned int)value);
}

static void write_json_string(FILE *stream, const char *value) {
  fputc('"', stream);
  write_utf8_string(stream, value, write_json_character, write_invalid_json_byte);
  fputc('"', stream);
}

static void report_json(const fs_lint_diagnostic *diagnostic, FILE *stream) {
  fputs("{\"severity\":", stream);
  write_json_string(stream, severity_name(diagnostic->severity));
  fputs(",\"code\":", stream);
  write_json_string(stream, diagnostic->code);
  fputs(",\"path\":", stream);
  write_json_string(stream, diagnostic->path);
  fputs(",\"message\":", stream);
  write_json_string(stream, diagnostic->message);
  fputs("}\n", stream);
}

static void write_text_character(FILE *stream, unsigned char value) {
  if (value == '\\') {
    fputs("\\\\", stream);
    return;
  }
  if (value < 0x20 || value == 0x7f) {
    write_control_character(stream, value);
    return;
  }
  fputc(value, stream);
}

static void write_invalid_text_byte(FILE *stream, unsigned char value) {
  fprintf(stream, "\\x%02x", (unsigned int)value);
}

static void write_text_string(FILE *stream, const char *value) {
  write_utf8_string(stream, value, write_text_character, write_invalid_text_byte);
}

static void report_text(const fs_lint_diagnostic *diagnostic, FILE *stream) {
  write_text_string(stream, diagnostic->path);
  fprintf(stream, ": %s ", severity_name(diagnostic->severity));
  write_text_string(stream, diagnostic->code);
  fputs(": ", stream);
  write_text_string(stream, diagnostic->message);
  fputc('\n', stream);
}

void cli_report(const fs_lint_diagnostic *diagnostic, void *user_data) {
  cli_output *output = user_data;
  if (output->format == CLI_OUTPUT_JSON) {
    report_json(diagnostic, output->stream);
    return;
  }
  report_text(diagnostic, output->stream);
}
