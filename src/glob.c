#include "glob.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  char *text;
  bool negated;
} glob_pattern;

struct legibility_glob_matcher {
  glob_pattern *patterns;
  unsigned char *current;
  unsigned char *next;
  unsigned char *seen;
  size_t *brace_ends;
  size_t *jumps;
  size_t pattern_count;
  size_t pattern_width;
};

typedef struct {
  legibility_glob_matcher *matcher;
  const char *pattern;
  size_t length;
} pattern_matcher;

static bool is_separator(char value) { return value == '/' || value == '\\'; }

static bool characters_match(char pattern, char path) {
  const bool both_separators = is_separator(pattern) && is_separator(path);
  return both_separators || pattern == path;
}

static char *copy_pattern_text(const char *pattern) {
  const size_t size = strlen(pattern) + 1;
  char *copy = malloc(size);
  if (copy != NULL) {
    memcpy(copy, pattern, size);
  }
  return copy;
}

static void *allocate_items(size_t count, size_t item_size) {
  if (count == 0) {
    return NULL;
  }
  if (count > SIZE_MAX / item_size) {
    return NULL;
  }
  return calloc(count, item_size);
}

static bool find_pattern_width(const char *const *patterns, size_t pattern_count,
                               size_t *width) {
  *width = 1;
  for (size_t index = 0; index < pattern_count; index += 1) {
    const bool negated = patterns[index][0] == '!';
    const char *text = negated ? patterns[index] + 1 : patterns[index];
    const size_t length = strlen(text);
    if (length == SIZE_MAX) {
      return false;
    }
    const size_t candidate = length + 1;
    *width = candidate > *width ? candidate : *width;
  }
  return true;
}

static bool allocate_pattern_storage(legibility_glob_matcher *matcher,
                                     size_t pattern_count) {
  matcher->patterns = allocate_items(pattern_count, sizeof(*matcher->patterns));
  if (pattern_count > 0 && matcher->patterns == NULL) {
    return false;
  }
  matcher->pattern_count = pattern_count;
  return true;
}

static bool allocate_match_storage(legibility_glob_matcher *matcher) {
  matcher->current = allocate_items(matcher->pattern_width, sizeof(*matcher->current));
  matcher->next = allocate_items(matcher->pattern_width, sizeof(*matcher->next));
  matcher->seen = allocate_items(matcher->pattern_width, sizeof(*matcher->seen));
  matcher->brace_ends =
      allocate_items(matcher->pattern_width, sizeof(*matcher->brace_ends));
  matcher->jumps = allocate_items(matcher->pattern_width, sizeof(*matcher->jumps));
  return matcher->current != NULL && matcher->next != NULL && matcher->seen != NULL &&
         matcher->brace_ends != NULL && matcher->jumps != NULL;
}

static bool copy_input_patterns(legibility_glob_matcher *matcher,
                                const char *const *patterns, size_t pattern_count) {
  for (size_t index = 0; index < pattern_count; index += 1) {
    const bool negated = patterns[index][0] == '!';
    const char *text = negated ? patterns[index] + 1 : patterns[index];
    matcher->patterns[index] = (glob_pattern){
        .text = copy_pattern_text(text),
        .negated = negated,
    };
    if (matcher->patterns[index].text == NULL) {
      return false;
    }
  }
  return true;
}

static bool find_brace_group_at(const char *pattern, size_t open, size_t *close) {
  size_t depth = 0;
  bool comma = false;
  for (size_t index = open; pattern[index] != '\0'; index += 1) {
    const bool starts_group = pattern[index] == '{';
    const bool ends_group = pattern[index] == '}' && depth > 0;
    if (starts_group) {
      depth += 1;
    } else if (pattern[index] == ',' && depth == 1) {
      comma = true;
    } else if (ends_group && --depth == 0 && comma) {
      *close = index;
      return true;
    }
  }
  return false;
}

static void mark_brace_group(pattern_matcher *context, size_t open, size_t close) {
  legibility_glob_matcher *matcher = context->matcher;
  matcher->brace_ends[open] = close + 1;
  size_t depth = 0;
  for (size_t index = open + 1; index <= close; index += 1) {
    depth += context->pattern[index] == '{' ? 1 : 0;
    depth -= context->pattern[index] == '}' && depth > 0 ? 1 : 0;
    const bool separator = context->pattern[index] == ',' && depth == 0;
    const bool last = index == close;
    if (separator || last) {
      matcher->jumps[index] = close + 1;
    }
  }
}

static void prepare_pattern(pattern_matcher *context) {
  legibility_glob_matcher *matcher = context->matcher;
  memset(matcher->current, 0, matcher->pattern_width);
  memset(matcher->next, 0, matcher->pattern_width);
  memset(matcher->brace_ends, 0, matcher->pattern_width * sizeof(*matcher->brace_ends));
  memset(matcher->jumps, 0, matcher->pattern_width * sizeof(*matcher->jumps));
  for (size_t index = 0; index < context->length; index += 1) {
    size_t close;
    if (context->pattern[index] == '{' &&
        find_brace_group_at(context->pattern, index, &close)) {
      mark_brace_group(context, index, close);
    }
  }
}

static void add_state(pattern_matcher *context, unsigned char *states, size_t index);

static void add_brace_alternatives(pattern_matcher *context, unsigned char *states,
                                   size_t open, size_t close) {
  add_state(context, states, open + 1);
  size_t depth = 0;
  for (size_t index = open + 1; index < close; index += 1) {
    depth += context->pattern[index] == '{' ? 1 : 0;
    depth -= context->pattern[index] == '}' && depth > 0 ? 1 : 0;
    if (context->pattern[index] == ',' && depth == 0) {
      add_state(context, states, index + 1);
    }
  }
}

static void add_star_zero_state(pattern_matcher *context, unsigned char *states,
                                size_t index) {
  const bool starstar = context->pattern[index + 1] == '*';
  const bool directory = starstar && is_separator(context->pattern[index + 2]);
  if (directory) {
    add_state(context, states, index + 3);
    return;
  }
  add_state(context, states, index + (starstar ? 2 : 1));
}

static void add_state(pattern_matcher *context, unsigned char *states, size_t index) {
  legibility_glob_matcher *matcher = context->matcher;
  if (index > context->length || matcher->seen[index] != 0) {
    return;
  }
  matcher->seen[index] = 1;
  const size_t jump = matcher->jumps[index];
  if (jump != 0) {
    add_state(context, states, jump);
    return;
  }
  const size_t brace_end = matcher->brace_ends[index];
  if (brace_end != 0) {
    add_brace_alternatives(context, states, index, brace_end - 1);
    return;
  }
  states[index] = 1;
  if (index < context->length && context->pattern[index] == '*') {
    add_star_zero_state(context, states, index);
  }
}

static void add_open_state(pattern_matcher *context) {
  memset(context->matcher->seen, 0, context->matcher->pattern_width);
  add_state(context, context->matcher->current, 0);
}

static void add_next_state(pattern_matcher *context, size_t index) {
  add_state(context, context->matcher->next, index);
}

static void consume_star(pattern_matcher *context, size_t index, char path) {
  const bool starstar = context->pattern[index + 1] == '*';
  const bool directory = starstar && is_separator(context->pattern[index + 2]);
  if (directory) {
    // Stay in the directory loop without reopening the zero-directory path.
    context->matcher->next[index] = 1;
    if (is_separator(path)) {
      add_next_state(context, index + 3);
    }
    return;
  }
  if (starstar) {
    add_next_state(context, index);
    return;
  }
  if (!is_separator(path)) {
    add_next_state(context, index);
  }
}

static void consume_state(pattern_matcher *context, size_t index, char path) {
  if (index == context->length) {
    return;
  }
  const char token = context->pattern[index];
  if (token == '*') {
    consume_star(context, index, path);
    return;
  }
  const bool question_match = token == '?' && !is_separator(path);
  const bool literal_match = token != '?' && characters_match(token, path);
  if (question_match || literal_match) {
    add_next_state(context, index + 1);
  }
}

static void consume_path_character(pattern_matcher *context, char path) {
  legibility_glob_matcher *matcher = context->matcher;
  memset(matcher->next, 0, matcher->pattern_width);
  memset(matcher->seen, 0, matcher->pattern_width);
  for (size_t index = 0; index <= context->length; index += 1) {
    if (matcher->current[index] != 0) {
      consume_state(context, index, path);
    }
  }
  unsigned char *swap = matcher->current;
  matcher->current = matcher->next;
  matcher->next = swap;
}

static bool matches_pattern(legibility_glob_matcher *matcher, glob_pattern pattern,
                            const char *path, size_t path_length) {
  pattern_matcher context = {
      .matcher = matcher,
      .pattern = pattern.text,
      .length = strlen(pattern.text),
  };
  prepare_pattern(&context);
  add_open_state(&context);
  for (size_t index = 0; index < path_length; index += 1) {
    consume_path_character(&context, path[index]);
  }
  return matcher->current[context.length] != 0;
}

static legibility_glob_matcher *allocate_matcher(size_t pattern_count,
                                                 size_t pattern_width) {
  legibility_glob_matcher *matcher = calloc(1, sizeof(*matcher));
  if (matcher == NULL) {
    return NULL;
  }
  matcher->pattern_width = pattern_width;
  const bool storage_ready = allocate_pattern_storage(matcher, pattern_count);
  const bool matches_ready = storage_ready && allocate_match_storage(matcher);
  if (!matches_ready) {
    legibility_glob_matcher_destroy(matcher);
    return NULL;
  }
  return matcher;
}

legibility_glob_matcher *legibility_glob_matcher_create(const char *const *patterns,
                                                        size_t pattern_count) {
  size_t pattern_width;
  if (!find_pattern_width(patterns, pattern_count, &pattern_width)) {
    return NULL;
  }
  legibility_glob_matcher *matcher = allocate_matcher(pattern_count, pattern_width);
  if (matcher == NULL) {
    return NULL;
  }
  if (!copy_input_patterns(matcher, patterns, pattern_count)) {
    legibility_glob_matcher_destroy(matcher);
    return NULL;
  }
  return matcher;
}

bool legibility_glob_matcher_allows(legibility_glob_matcher *matcher, const char *path,
                                    bool default_allowed) {
  const size_t path_length = strlen(path);
  bool allowed = default_allowed;
  for (size_t index = 0; index < matcher->pattern_count; index += 1) {
    if (matches_pattern(matcher, matcher->patterns[index], path, path_length)) {
      allowed = !matcher->patterns[index].negated;
    }
  }
  return allowed;
}

void legibility_glob_matcher_destroy(legibility_glob_matcher *matcher) {
  if (matcher == NULL) {
    return;
  }
  free(matcher->current);
  free(matcher->next);
  free(matcher->seen);
  free(matcher->brace_ends);
  free(matcher->jumps);
  for (size_t index = 0; index < matcher->pattern_count; index += 1) {
    free(matcher->patterns[index].text);
  }
  free(matcher->patterns);
  free(matcher);
}
