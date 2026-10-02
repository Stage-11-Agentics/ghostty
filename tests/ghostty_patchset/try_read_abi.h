#ifndef C11_TRY_READ_ABI_H
#define C11_TRY_READ_ABI_H

#include <ghostty.h>

// Host-side controls, not additions to the shipping Ghostty ABI. The host owns
// a live surface and invokes the suite on its app thread. Each callback returns
// zero on success. Hold must wait for a separate worker to acquire the actual
// renderer mutex, and that worker must retain it until release is called.
typedef struct {
  ghostty_surface_t surface;
  void *context;
  int (*hold_renderer)(void *);
  int (*release_renderer)(void *);
  int (*set_selection)(void *, const ghostty_selection_s *); // NULL clears it
  // Fail only this app thread's native formatter allocation, restoring normal
  // allocation when false. Do not fail unrelated worker allocations.
  int (*fail_formatter_allocation)(void *, bool);
  // Valid nonempty ranges with different bytes, on a stable terminal grid.
  ghostty_selection_s first;
  ghostty_selection_s second;
  const char *first_text;
  const char *second_text;
  // A range resolving to no pin, e.g. history bottom-right with no history.
  ghostty_selection_s invalid;
} c11_try_read_fixture_s;

// Returns zero on success. Prints measured call durations and failures to
// stderr. The host must enforce an external watchdog: a blocking regression
// must fail the run, not rely on releasing the gated holder on a timer.
int c11_test_try_read_abi(const c11_try_read_fixture_s *);

#endif
