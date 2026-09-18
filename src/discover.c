#define _XOPEN_SOURCE 700

#include "discover.h"

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static const char *const config_names[] = {
    ".fs-lintrc", "fs-lint.json", "fs-lint.toml", "fs-lint.yaml", "fs-lint.yml",
};
static const size_t config_name_count = sizeof(config_names) / sizeof(config_names[0]);

static char *join_path(const char *root, const char *name) {
  const size_t size = strlen(root) + strlen(name) + 2;
  char *path = malloc(size);
  if (path != NULL) {
    snprintf(path, size, "%s/%s", root, name);
  }
  return path;
}

static bool path_exists(const char *path) {
  struct stat details;
  return stat(path, &details) == 0;
}

static bool config_path_missing(const char *path) {
  struct stat details;
  return lstat(path, &details) == -1 && errno == ENOENT;
}

static bool reached_repository_root(const char *directory) {
  char *git_path = join_path(directory, ".git");
  const bool reached = git_path != NULL && path_exists(git_path);
  free(git_path);
  return reached;
}

static void move_to_parent(char *directory) {
  size_t end = strlen(directory);
  while (end > 1 && directory[end - 1] == '/') {
    end -= 1;
  }
  size_t separator = end;
  while (separator > 0 && directory[separator - 1] != '/') {
    separator -= 1;
  }
  if (separator <= 1) {
    directory[1] = '\0';
    return;
  }
  directory[separator - 1] = '\0';
}

static char *reject_conflict(char *found, char *candidate, char *error,
                             size_t error_size) {
  free(found);
  free(candidate);
  snprintf(error, error_size, "multiple configuration files found");
  return NULL;
}

static char *find_in_directory(const char *directory, char *error, size_t error_size) {
  char *found = NULL;
  for (size_t index = 0; index < config_name_count; index += 1) {
    char *candidate = join_path(directory, config_names[index]);
    if (candidate == NULL) {
      free(found);
      snprintf(error, error_size, "could not allocate configuration path");
      return NULL;
    }
    if (config_path_missing(candidate)) {
      free(candidate);
      continue;
    }
    if (found != NULL) {
      return reject_conflict(found, candidate, error, error_size);
    }
    found = candidate;
  }
  return found;
}

static char *find_from_directory(char *directory, char *error, size_t error_size) {
  while (true) {
    char *candidate = find_in_directory(directory, error, error_size);
    if (candidate != NULL) {
      return candidate;
    }
    if (error[0] != '\0') {
      return NULL;
    }
    const bool should_stop =
        reached_repository_root(directory) || strcmp(directory, "/") == 0;
    if (should_stop) {
      return NULL;
    }
    move_to_parent(directory);
  }
}

char *fs_lint_discover_config(const char *root, char *error, size_t error_size) {
  error[0] = '\0';
  char *directory = realpath(root, NULL);
  if (directory == NULL) {
    snprintf(error, error_size, "could not resolve lint root");
    return NULL;
  }
  char *config_path = find_from_directory(directory, error, error_size);
  free(directory);
  if (config_path == NULL && error[0] == '\0') {
    snprintf(error, error_size, "no configuration file found");
  }
  return config_path;
}
