#define _XOPEN_SOURCE 700

#include "git_environment.h"

#include "legibility.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define GIT_ENV_CAPACITY 64

typedef struct {
  char names[4096];
  const char *variables[GIT_ENV_CAPACITY];
  size_t count;
} git_environment;

static bool clear_environment(const git_environment *environment) {
  for (size_t index = 0; index < environment->count; index += 1) {
    if (unsetenv(environment->variables[index]) != 0) {
      return false;
    }
  }
  return true;
}

static void query_child(const char *root, const char *command, const char *option,
                        const git_environment *environment, FILE *output) {
  const bool cleared = environment == NULL || clear_environment(environment);
  const bool directory_ready = chdir(root) == 0;
  const bool output_ready = dup2(fileno(output), STDOUT_FILENO) != -1;
  close(STDERR_FILENO);
  if (!cleared || !directory_ready || !output_ready) {
    _exit(127);
  }
  execlp("git", "git", command, option, (char *)NULL);
  _exit(127);
}

static bool query_succeeded(pid_t identifier) {
  int status = 0;
  pid_t result;
  do {
    result = waitpid(identifier, &status, 0);
  } while (result == -1 && errno == EINTR);
  return result == identifier && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static FILE *query_git(const char *root, const char *command, const char *option,
                       const git_environment *environment) {
  FILE *output = tmpfile();
  if (output == NULL) {
    return NULL;
  }
  const pid_t identifier = fork();
  if (identifier == 0) {
    query_child(root, command, option, environment, output);
  }
  const bool succeeded = identifier > 0 && query_succeeded(identifier);
  if (!succeeded || fseek(output, 0, SEEK_SET) != 0) {
    fclose(output);
    return NULL;
  }
  return output;
}

static bool rev_parse(const char *root, const char *option,
                      const git_environment *environment, char *buffer,
                      size_t capacity) {
  FILE *output = query_git(root, "rev-parse", option, environment);
  if (output == NULL) {
    return false;
  }
  const size_t length = fread(buffer, 1, capacity - 1, output);
  buffer[length] = '\0';
  const bool captured = !ferror(output) && length < capacity - 1;
  fclose(output);
  return captured;
}

static bool remember_variable(git_environment *environment, const char *name) {
  if (getenv(name) == NULL) {
    return true;
  }
  if (environment->count == GIT_ENV_CAPACITY) {
    return false;
  }
  environment->variables[environment->count++] = name;
  return true;
}

static bool read_environment(git_environment *environment) {
  if (!rev_parse(".", "--local-env-vars", NULL, environment->names,
                 sizeof(environment->names))) {
    return false;
  }
  char *cursor = NULL;
  char *name = strtok_r(environment->names, "\n", &cursor);
  while (name != NULL) {
    if (!remember_variable(environment, name)) {
      return false;
    }
    name = strtok_r(NULL, "\n", &cursor);
  }
  return true;
}

static bool same_repository(const char *root, const git_environment *environment) {
  char current[LEGIBILITY_MAX_PATH_LENGTH + 2];
  char target[LEGIBILITY_MAX_PATH_LENGTH + 2];
  const bool current_found =
      rev_parse(".", "--absolute-git-dir", NULL, current, sizeof(current));
  const bool target_found =
      rev_parse(root, "--absolute-git-dir", environment, target, sizeof(target));
  return current_found && target_found && strcmp(current, target) == 0;
}

static bool make_absolute(const char *name, const char *directory) {
  const char *value = getenv(name);
  if (value == NULL || value[0] == '\0' || value[0] == '/') {
    return true;
  }
  const size_t size = strlen(directory) + strlen(value) + 2;
  char *path = malloc(size);
  if (path == NULL) {
    return false;
  }
  snprintf(path, size, "%s/%s", directory, value);
  const bool stored = setenv(name, path, 1) == 0;
  free(path);
  return stored;
}

static bool preserve_relative_paths(const char *directory) {
  const char *const names[] = {
      "GIT_DIR",          "GIT_WORK_TREE",        "GIT_COMMON_DIR",
      "GIT_INDEX_FILE",   "GIT_OBJECT_DIRECTORY", "GIT_GRAFT_FILE",
      "GIT_SHALLOW_FILE", "GIT_CONFIG",
  };
  for (size_t index = 0; index < sizeof(names) / sizeof(*names); index += 1) {
    if (!make_absolute(names[index], directory)) {
      return false;
    }
  }
  return true;
}

static bool write_alternate(FILE *output, char *line) {
  const char prefix[] = "alternate: ";
  if (strncmp(line, prefix, sizeof(prefix) - 1) != 0) {
    return true;
  }
  line[strcspn(line, "\n")] = '\0';
  const char *path = line + sizeof(prefix) - 1;
  const long position = ftell(output);
  const char *separator = position == 0 ? "" : ":";
  // Git's C-quoted paths are valid environment entries; quote other paths for ':'.
  const char *quote = path[0] == '"' ? "" : "\"";
  return position >= 0 &&
         fprintf(output, "%s%s%s%s", separator, quote, path, quote) >= 0;
}

static bool copy_alternates(FILE *input, FILE *output) {
  char *line = NULL;
  size_t capacity = 0;
  bool copied = true;
  while (copied && getline(&line, &capacity, input) != -1) {
    copied = write_alternate(output, line);
  }
  free(line);
  return copied && feof(input) && !ferror(input);
}

static bool store_alternates(FILE *input) {
  char *value = NULL;
  size_t length = 0;
  FILE *output = open_memstream(&value, &length);
  if (output == NULL) {
    return false;
  }
  const bool copied = copy_alternates(input, output);
  const bool closed = fclose(output) == 0;
  const bool stored =
      copied && closed && setenv("GIT_ALTERNATE_OBJECT_DIRECTORIES", value, 1) == 0;
  free(value);
  return stored;
}

static bool preserve_alternates(void) {
  const char *value = getenv("GIT_ALTERNATE_OBJECT_DIRECTORIES");
  if (value == NULL || value[0] == '\0') {
    return true;
  }
  // Git resolves and quotes alternates: https://git-scm.com/docs/git-count-objects
  FILE *output = query_git(".", "count-objects", "-v", NULL);
  if (output == NULL) {
    return false;
  }
  const bool stored = store_alternates(output);
  fclose(output);
  return stored;
}

bool cli_git_prepare_environment(const char *root) {
  git_environment environment = {0};
  if (!read_environment(&environment)) {
    return false;
  }
  if (environment.count == 0) {
    return true;
  }
  if (!same_repository(root, &environment)) {
    return clear_environment(&environment);
  }
  char *directory = getcwd(NULL, 0);
  const bool preserved =
      directory != NULL && preserve_alternates() && preserve_relative_paths(directory);
  free(directory);
  return preserved;
}
