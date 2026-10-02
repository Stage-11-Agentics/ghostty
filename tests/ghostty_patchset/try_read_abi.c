#include "try_read_abi.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

static ghostty_text_s dirty_result(void) {
  return (ghostty_text_s){
      .tl_px_x = 123, .tl_px_y = 456, .offset_start = 789,
      .offset_len = 10, .text = "not-owned", .text_len = 9};
}

static bool zero_result(const ghostty_text_s *t) {
  return t->tl_px_x == 0 && t->tl_px_y == 0 && t->offset_start == 0 &&
         t->offset_len == 0 && t->text == NULL && t->text_len == 0;
}

static bool same_result(const ghostty_text_s *a, const ghostty_text_s *b) {
  return a->tl_px_x == b->tl_px_x && a->tl_px_y == b->tl_px_y &&
         a->offset_start == b->offset_start && a->offset_len == b->offset_len &&
         a->text_len == b->text_len && a->text && b->text &&
         memcmp(a->text, b->text, a->text_len + 1) == 0;
}

static double milliseconds(struct timespec a, struct timespec b) {
  return (double)(b.tv_sec - a.tv_sec) * 1000 +
         (double)(b.tv_nsec - a.tv_nsec) / 1000000;
}

// Both paths use the actual exports and each successful owned result is freed
// exactly once. Allocation diagnostics in the host detect leaks/double frees.
static int compare_read(const c11_try_read_fixture_s *f,
                        ghostty_selection_s selection, bool current,
                        const char *expected_bytes) {
  ghostty_text_s expected = {0}, actual = dirty_result();
  bool ok = current ? ghostty_surface_read_selection(f->surface, &expected)
                    : ghostty_surface_read_text(f->surface, selection, &expected);
  if (!ok) {
    fprintf(stderr, "baseline read failed (current=%d)\n", current);
    return 1;
  }
  struct timespec start, end;
  clock_gettime(CLOCK_MONOTONIC, &start);
  ghostty_text_read_status_e status = current
      ? ghostty_surface_try_read_selection(f->surface, &actual)
      : ghostty_surface_try_read_text(f->surface, selection, &actual);
  clock_gettime(CLOCK_MONOTONIC, &end);
  fprintf(stderr, "try_read current=%d acquired-plus-formatting-ms=%.3f\n",
          current, milliseconds(start, end));
  int failed = status != GHOSTTY_TEXT_READ_OK || !same_result(&expected, &actual) ||
      expected.text_len != strlen(expected_bytes) || !expected.text ||
      memcmp(expected.text, expected_bytes, strlen(expected_bytes)) != 0;
  ghostty_surface_free_text(f->surface, &expected);
  if (status == GHOSTTY_TEXT_READ_OK)
    ghostty_surface_free_text(f->surface, &actual);
  if (failed) fprintf(stderr, "read parity failed (current=%d status=%d)\n", current, status);
  return failed;
}

int c11_test_try_read_abi(const c11_try_read_fixture_s *f) {
  int failed = 0;
  if (f->hold_renderer(f->context)) return 1;

  // The holder remains gated through both calls. A blocking implementation
  // cannot finish this section, and the host watchdog must terminate it.
  for (int current = 0; current < 2; ++current) {
    ghostty_text_s result = dirty_result();
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    ghostty_text_read_status_e status = current
        ? ghostty_surface_try_read_selection(f->surface, &result)
        : ghostty_surface_try_read_text(f->surface, f->first, &result);
    clock_gettime(CLOCK_MONOTONIC, &end);
    fprintf(stderr, "try_read current=%d busy-acquisition-ms=%.3f\n",
            current, milliseconds(start, end));
    if (status != GHOSTTY_TEXT_READ_BUSY || !zero_result(&result)) {
      fprintf(stderr, "BUSY/zero-result failed (current=%d status=%d)\n", current, status);
      failed = 1;
    }
    if (status == GHOSTTY_TEXT_READ_OK)
      ghostty_surface_free_text(f->surface, &result);
  }
  if (f->release_renderer(f->context)) return 1;

  if (f->set_selection(f->context, NULL)) return 1;
  ghostty_text_s result = dirty_result();
  ghostty_text_read_status_e status = ghostty_surface_try_read_selection(f->surface, &result);
  if (status != GHOSTTY_TEXT_READ_NO_SELECTION || !zero_result(&result)) {
    fprintf(stderr, "NO_SELECTION/zero-result failed\n");
    failed = 1;
  }
  if (status == GHOSTTY_TEXT_READ_OK) ghostty_surface_free_text(f->surface, &result);

  result = dirty_result();
  status = ghostty_surface_try_read_text(f->surface, f->invalid, &result);
  if (status != GHOSTTY_TEXT_READ_INVALID_SELECTION || !zero_result(&result)) {
    fprintf(stderr, "INVALID_SELECTION/zero-result failed\n");
    failed = 1;
  }
  if (status == GHOSTTY_TEXT_READ_OK) ghostty_surface_free_text(f->surface, &result);

  const ghostty_selection_s selections[] = {f->first, f->second};
  const char *texts[] = {f->first_text, f->second_text};
  for (unsigned i = 0; i < 2; ++i) {
    if (f->set_selection(f->context, &selections[i])) return 1;
    failed |= compare_read(f, selections[i], false, texts[i]);
    failed |= compare_read(f, selections[i], true, texts[i]);
  }

  if (f->fail_formatter_allocation(f->context, true)) return 1;
  for (int current = 0; current < 2; ++current) {
    result = dirty_result();
    status = current
        ? ghostty_surface_try_read_selection(f->surface, &result)
        : ghostty_surface_try_read_text(f->surface, f->first, &result);
    if (status != GHOSTTY_TEXT_READ_FAILED || !zero_result(&result)) {
      fprintf(stderr, "FAILED/zero-result failed (current=%d status=%d)\n", current, status);
      failed = 1;
    }
    if (status == GHOSTTY_TEXT_READ_OK) ghostty_surface_free_text(f->surface, &result);
  }
  if (f->fail_formatter_allocation(f->context, false)) return 1;

  // Successful retry proves error exits released the renderer lock.
  failed |= compare_read(f, f->first, false, f->first_text);
  if (f->set_selection(f->context, NULL)) return 1;
  result = dirty_result();
  status = ghostty_surface_try_read_selection(f->surface, &result);
  if (status != GHOSTTY_TEXT_READ_NO_SELECTION || !zero_result(&result)) {
    fprintf(stderr, "cleared selection/zero-result failed\n");
    failed = 1;
  }
  if (status == GHOSTTY_TEXT_READ_OK) ghostty_surface_free_text(f->surface, &result);
  return failed;
}
