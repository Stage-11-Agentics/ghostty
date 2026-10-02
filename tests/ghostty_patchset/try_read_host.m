#import <Cocoa/Cocoa.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>
#include "try_read_abi.h"

// Defined only by src/c11_read_test.zig, never by the shipping library.
extern void c11_read_test_install_allocator(void);
extern int c11_read_test_prepare(ghostty_surface_t);
extern int c11_read_test_finish(void);
extern int c11_read_test_hold(void *);
extern int c11_read_test_release(void *);
extern int c11_read_test_fail(void *, bool);
extern int c11_read_test_select(void *, const ghostty_selection_s *);

static void watchdog(int signal_number) {
  (void)signal_number;
  const char message[] = "FAIL: native read fixture exceeded 30-second watchdog\n";
  (void)write(STDERR_FILENO, message, sizeof(message) - 1);
  _exit(124);
}

// Intentionally no app tick while the suite runs. No clipboard request is
// expected, and manual IO never launches an external command.
static void wakeup(void *context) { (void)context; }
static bool action(ghostty_app_t app, ghostty_target_s target, ghostty_action_s value) {
  (void)app; (void)target; (void)value;
  return true;
}
static void read_clipboard(void *context, ghostty_clipboard_e clipboard, void *request) {
  (void)context; (void)clipboard; (void)request;
}
static void confirm_clipboard(void *context, const char *text, void *request,
                              ghostty_clipboard_request_e kind) {
  (void)context; (void)text; (void)request; (void)kind;
}
static void write_clipboard(void *context, ghostty_clipboard_e clipboard,
                            const ghostty_clipboard_content_s *content,
                            size_t count, bool confirm) {
  (void)context; (void)clipboard; (void)content; (void)count; (void)confirm;
}

static ghostty_selection_s range(uint32_t first, uint32_t last) {
  return (ghostty_selection_s){
      .top_left = {GHOSTTY_POINT_VIEWPORT, GHOSTTY_POINT_COORD_EXACT, first, 0},
      .bottom_right = {GHOSTTY_POINT_VIEWPORT, GHOSTTY_POINT_COORD_EXACT, last, 0},
      .rectangle = false};
}

int main(int argc, char **argv) {
  signal(SIGALRM, watchdog);
  alarm(30);
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    if (ghostty_init((uintptr_t)argc, argv) != 0) return 1;
    c11_read_test_install_allocator();
    ghostty_config_t config = ghostty_config_new();
    if (!config) return 1;
    // Never load tenant configuration, shell startup files, or host hooks.
    ghostty_config_finalize(config);
    ghostty_runtime_config_s runtime = {
        .wakeup_cb = wakeup, .action_cb = action,
        .read_clipboard_cb = read_clipboard,
        .confirm_read_clipboard_cb = confirm_clipboard,
        .write_clipboard_cb = write_clipboard};
    ghostty_app_t app = ghostty_app_new(&runtime, config);
    if (!app) { ghostty_config_free(config); return 1; }
    // A real NSView/Metal-backed embedded surface without presenting a window.
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    ghostty_surface_config_s options = ghostty_surface_config_new();
    options.platform_tag = GHOSTTY_PLATFORM_MACOS;
    options.platform.macos.nsview = (__bridge void *)view;
    options.io_mode = GHOSTTY_SURFACE_IO_MANUAL;
    ghostty_surface_t surface = ghostty_surface_new(app, &options);
    if (!surface) {
      fprintf(stderr, "FAIL: real embedded surface creation failed (unlocked GUI required)\n");
      ghostty_app_free(app);
      ghostty_config_free(config);
      return 1;
    }
    int failed = c11_read_test_prepare(surface);
    if (!failed) {
      c11_try_read_fixture_s fixture = {
          .surface = surface, .context = surface,
          .hold_renderer = c11_read_test_hold,
          .release_renderer = c11_read_test_release,
          .set_selection = c11_read_test_select,
          .fail_formatter_allocation = c11_read_test_fail,
          .first = range(0, 4), .second = range(6, 10),
          .first_text = "alpha", .second_text = "bravo",
          .invalid = {
              .top_left = {GHOSTTY_POINT_SURFACE, GHOSTTY_POINT_COORD_TOP_LEFT, 0, 0},
              .bottom_right = {GHOSTTY_POINT_SURFACE, GHOSTTY_POINT_COORD_BOTTOM_RIGHT, 0, 0}}};
      // C's historical SURFACE enum value maps to native .history. There is
      // no scrollback in the freshly created fixture, so its end pin is absent.
      failed = c11_test_try_read_abi(&fixture);
      failed |= c11_read_test_finish();
    }
    ghostty_surface_free(surface);
    ghostty_app_free(app);
    ghostty_config_free(config);
    fprintf(stderr, "%s: real native try-read ABI fixture\n", failed ? "FAIL" : "PASS");
    alarm(0);
    return failed ? 1 : 0;
  }
}
