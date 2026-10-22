#ifndef FS_LINT_GIT_ENVIRONMENT_H
#define FS_LINT_GIT_ENVIRONMENT_H

#include <stdbool.h>
#include <stddef.h>

bool cli_git_prepare_environment(const char *root);
bool cli_git_read_work_tree(const char *root, char *path, size_t capacity);

#endif
