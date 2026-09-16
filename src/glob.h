#ifndef FS_LINT_GLOB_H
#define FS_LINT_GLOB_H

#include <stdbool.h>
#include <stddef.h>

typedef struct fs_lint_glob_matcher fs_lint_glob_matcher;

fs_lint_glob_matcher *fs_lint_glob_matcher_create(const char *const *patterns,
                                                  size_t pattern_count);

bool fs_lint_glob_matcher_allows(fs_lint_glob_matcher *matcher, const char *path,
                                 bool default_allowed);

void fs_lint_glob_matcher_destroy(fs_lint_glob_matcher *matcher);

#endif
