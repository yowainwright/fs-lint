#define _POSIX_C_SOURCE 200809L

#include "changes.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define CLI_MAX_CHANGES 100000

typedef enum { PATH_READY, PATH_END, PATH_ERROR } path_status;

typedef struct {
  FILE *error_stream;
  int output[2];
  pid_t identifier;
} git_process;

static bool fail(cli_changes *changes, const char *message) {
  snprintf(changes->error, sizeof(changes->error), "%s", message);
  return false;
}

static path_status finish_path(char *buffer, size_t length, char **path,
                               cli_changes *changes) {
  if (length == 0) {
    fail(changes, "NUL-delimited input contains an empty path");
    return PATH_ERROR;
  }
  buffer[length] = '\0';
  *path = malloc(length + 1);
  if (*path == NULL) {
    fail(changes, "could not allocate change path");
    return PATH_ERROR;
  }
  memcpy(*path, buffer, length + 1);
  return PATH_READY;
}

static path_status finish_stream(FILE *stream, size_t length, cli_changes *changes) {
  if (ferror(stream)) {
    fail(changes, "could not read NUL-delimited input");
    return PATH_ERROR;
  }
  if (length > 0) {
    fail(changes, "NUL-delimited input must end with NUL");
    return PATH_ERROR;
  }
  return PATH_END;
}

static path_status read_path(FILE *stream, char **path, cli_changes *changes) {
  char buffer[FS_LINT_MAX_PATH_LENGTH + 1];
  size_t length = 0;
  int value;
  while ((value = fgetc(stream)) != EOF) {
    if (value == '\0') {
      return finish_path(buffer, length, path, changes);
    }
    if (length == FS_LINT_MAX_PATH_LENGTH) {
      fail(changes, "change path exceeds FS_LINT_MAX_PATH_LENGTH");
      return PATH_ERROR;
    }
    buffer[length] = (char)value;
    length += 1;
  }
  return finish_stream(stream, length, changes);
}

static bool grow_changes(cli_changes *changes) {
  const size_t doubled = changes->capacity * 2;
  size_t capacity = changes->capacity == 0 ? 16 : doubled;
  capacity = capacity > CLI_MAX_CHANGES ? CLI_MAX_CHANGES : capacity;
  fs_lint_change *items = realloc(changes->items, capacity * sizeof(*items));
  if (items == NULL) {
    return fail(changes, "could not allocate changes");
  }
  changes->items = items;
  changes->capacity = capacity;
  return true;
}

static bool append_path(cli_changes *changes, char *path) {
  if (changes->count == CLI_MAX_CHANGES) {
    return fail(changes, "change count exceeds CLI_MAX_CHANGES");
  }
  const bool needs_capacity = changes->count == changes->capacity;
  if (needs_capacity && !grow_changes(changes)) {
    return false;
  }
  changes->items[changes->count] = (fs_lint_change){
      .path = path,
      .kind = FS_LINT_CHANGE_ADDED,
  };
  changes->count += 1;
  return true;
}

bool cli_changes_read_nul(FILE *stream, cli_changes *changes) {
  memset(changes, 0, sizeof(*changes));
  while (true) {
    char *path = NULL;
    const path_status status = read_path(stream, &path, changes);
    if (status == PATH_END) {
      return true;
    }
    if (status == PATH_ERROR) {
      return false;
    }
    if (!append_path(changes, path)) {
      free(path);
      return false;
    }
  }
}

static void execute_git_child(const char *root, const char *const arguments[],
                              const git_process *process) {
  close(process->output[0]);
  const bool output_failed = dup2(process->output[1], STDOUT_FILENO) == -1;
  const bool error_failed = dup2(fileno(process->error_stream), STDERR_FILENO) == -1;
  const bool directory_failed = chdir(root) == -1;
  close(process->output[1]);
  if (output_failed || error_failed || directory_failed) {
    _exit(127);
  }
  execvp(arguments[0], (char *const *)arguments);
  _exit(127);
}

static pid_t start_git(const char *root, const char *const arguments[],
                       const git_process *process) {
  const pid_t identifier = fork();
  if (identifier == 0) {
    execute_git_child(root, arguments, process);
  }
  return identifier;
}

static bool launch_git(const char *root, const char *const arguments[],
                       git_process *process, cli_changes *changes) {
  process->error_stream = tmpfile();
  if (process->error_stream == NULL) {
    return fail(changes, "could not create git error stream");
  }
  if (pipe(process->output) == -1) {
    fclose(process->error_stream);
    return fail(changes, "could not create git output stream");
  }
  process->identifier = start_git(root, arguments, process);
  close(process->output[1]);
  if (process->identifier == -1) {
    close(process->output[0]);
    fclose(process->error_stream);
    return fail(changes, "could not start git diff");
  }
  return true;
}

static bool wait_for_git(pid_t identifier, int *status, cli_changes *changes) {
  pid_t result;
  do {
    result = waitpid(identifier, status, 0);
  } while (result == -1 && errno == EINTR);
  if (result == -1) {
    return fail(changes, "could not wait for git diff");
  }
  return true;
}

static bool report_git_failure(FILE *error_stream, cli_changes *changes) {
  if (fseek(error_stream, 0, SEEK_SET) != 0) {
    return fail(changes, "git diff failed and its error output could not be read");
  }
  char detail[192];
  size_t length = fread(detail, 1, sizeof(detail) - 1, error_stream);
  if (ferror(error_stream)) {
    return fail(changes, "git diff failed and its error output could not be read");
  }
  while (length > 0 && (detail[length - 1] == '\n' || detail[length - 1] == '\r')) {
    length -= 1;
  }
  detail[length] = '\0';
  if (length == 0) {
    return fail(changes, "git diff failed");
  }
  snprintf(changes->error, sizeof(changes->error), "git diff failed: %s", detail);
  return false;
}

static bool read_git_output(int descriptor, cli_changes *changes) {
  FILE *output = fdopen(descriptor, "rb");
  if (output == NULL) {
    close(descriptor);
    return fail(changes, "could not read git diff output");
  }
  const bool parsed = cli_changes_read_nul(output, changes);
  fclose(output);
  return parsed;
}

static bool finish_git(git_process *process, bool parsed, cli_changes *changes) {
  int status = 0;
  const bool waited = wait_for_git(process->identifier, &status, changes);
  const bool exited = waited && WIFEXITED(status);
  const bool succeeded = exited && WEXITSTATUS(status) == 0;
  if (parsed && waited && !succeeded) {
    report_git_failure(process->error_stream, changes);
  }
  fclose(process->error_stream);
  return parsed && succeeded;
}

static bool read_git(const char *root, const char *const arguments[],
                     cli_changes *changes) {
  memset(changes, 0, sizeof(*changes));
  git_process process;
  if (!launch_git(root, arguments, &process, changes)) {
    return false;
  }
  const bool parsed = read_git_output(process.output[0], changes);
  return finish_git(&process, parsed, changes);
}

bool cli_changes_read_git_staged(const char *root, cli_changes *changes) {
  const char *const arguments[] = {
      "git",
      "diff",
      "--cached",
      "--name-only",
      "--diff-filter=A",
      "--no-renames",
      "--no-relative",
      "--ignore-submodules=none",
      "-z",
      "--",
      NULL,
  };
  return read_git(root, arguments, changes);
}

bool cli_changes_read_git_base(const char *root, const char *base,
                               cli_changes *changes) {
  const char *const arguments[] = {
      "git",
      "diff",
      "--merge-base",
      "--name-only",
      "--diff-filter=A",
      "--no-renames",
      "--no-relative",
      "--ignore-submodules=none",
      "-z",
      base,
      "HEAD",
      "--",
      NULL,
  };
  return read_git(root, arguments, changes);
}

void cli_changes_destroy(cli_changes *changes) {
  for (size_t index = 0; index < changes->count; index += 1) {
    free((void *)changes->items[index].path);
  }
  free(changes->items);
  memset(changes, 0, sizeof(*changes));
}
