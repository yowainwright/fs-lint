// Only production translation units use the failing allocator replacements.
#undef malloc
#undef calloc
#undef free

#include "legibility.h"

#include <stdio.h>
#include <stdlib.h>

static size_t allocation_count;
static size_t fail_at;
static size_t live_allocations;

static void fail(const char *message) {
  fprintf(stderr, "allocation %zu: %s\n", fail_at, message);
  exit(EXIT_FAILURE);
}

static void *track_allocation(void *pointer) {
  if (pointer != NULL) {
    live_allocations += 1;
  }
  return pointer;
}

void *test_malloc(size_t size) {
  allocation_count += 1;
  if (allocation_count == fail_at) {
    return NULL;
  }
  return track_allocation(malloc(size));
}

void *test_calloc(size_t count, size_t size) {
  allocation_count += 1;
  if (allocation_count == fail_at) {
    return NULL;
  }
  return track_allocation(calloc(count, size));
}

void test_free(void *pointer) {
  if (pointer == NULL) {
    return;
  }
  if (live_allocations == 0) {
    fail("freed an untracked allocation");
  }
  live_allocations -= 1;
  free(pointer);
}

static legibility_status check_path(void) {
  const char *patterns[] = {"src/**/{index,utils}.c", "!**/generated/**"};
  const legibility_config config = {
      .allow_patterns = patterns,
      .allow_pattern_count = 2,
  };
  const legibility_change change = {
      .path = "src/index.c",
      .kind = LEGIBILITY_CHANGE_ADDED,
  };
  allocation_count = 0;
  const legibility_status status = legibility_check(&config, &change, 1, NULL, NULL);
  if (live_allocations != 0) {
    fail("matcher leaked memory");
  }
  return status;
}

int main(void) {
  if (check_path() != LEGIBILITY_STATUS_OK || allocation_count == 0) {
    fail("baseline check failed");
  }
  const size_t total_allocations = allocation_count;
  for (fail_at = 1; fail_at <= total_allocations; fail_at += 1) {
    if (check_path() != LEGIBILITY_STATUS_ERROR) {
      fail("expected an allocation failure to return an error");
    }
  }
  return EXIT_SUCCESS;
}
