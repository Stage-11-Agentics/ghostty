//! Root of the opt-in test library ONLY. Shipping builds use main_c.zig.
//! All reads go through the production C exports imported below.
const std = @import("std");
const api = @import("main_c.zig");
const Surface = @import("apprt/embedded.zig").Surface;
const global = &@import("global.zig").state;
const Allocator = std.mem.Allocator;

pub const std_options = api.std_options;
comptime {
    _ = api;
}

var backing: Allocator = undefined;
threadlocal var fail_allocation = false;
threadlocal var track_allocation = false;
threadlocal var outstanding: isize = 0;
var holder: ?std.Thread = null;
var acquired: std.Thread.ResetEvent = .{};
var release: std.Thread.ResetEvent = .{};

// Install once before creating any app/surface threads. There are no global
// allocator swaps during the fixture: failure/accounting are thread-local.
// Public so macOS signpost initialization can discover a root function and
// resolve this library's Mach-O image (matching main_c.zig's public exports).
pub export fn c11_read_test_install_allocator() void {
    backing = global.alloc;
    global.alloc = .{ .ptr = &backing, .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    } };
}

fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    if (fail_allocation) return null;
    const result = backing.rawAlloc(len, alignment, ra) orelse return null;
    if (track_allocation) outstanding += @intCast(len);
    return result;
}

fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
    if (fail_allocation) return false;
    if (!backing.rawResize(memory, alignment, len, ra)) return false;
    if (track_allocation) outstanding += @as(isize, @intCast(len)) - @as(isize, @intCast(memory.len));
    return true;
}

fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
    if (fail_allocation) return null;
    const result = backing.rawRemap(memory, alignment, len, ra) orelse return null;
    if (track_allocation) outstanding += @as(isize, @intCast(len)) - @as(isize, @intCast(memory.len));
    return result;
}

fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
    if (track_allocation) outstanding -= @intCast(memory.len);
    backing.rawFree(memory, alignment, ra);
}

export fn c11_read_test_prepare(surface: *Surface) c_int {
    const core = &surface.core_surface;
    core.renderer_state.mutex.lock();
    defer core.renderer_state.mutex.unlock();
    core.io.terminal.printString("alpha bravo") catch return 1;
    outstanding = 0;
    track_allocation = true;
    return 0;
}

export fn c11_read_test_finish() c_int {
    track_allocation = false;
    std.debug.print("try-read outstanding bytes={d}\n", .{outstanding});
    return if (outstanding == 0 and !fail_allocation and holder == null) 0 else 1;
}

fn hold(surface: *Surface) void {
    surface.core_surface.renderer_state.mutex.lock();
    acquired.set();
    release.wait();
    surface.core_surface.renderer_state.mutex.unlock();
}

export fn c11_read_test_hold(context: ?*anyopaque) c_int {
    const surface: *Surface = @ptrCast(@alignCast(context.?));
    if (holder != null) return 1;
    acquired.reset();
    release.reset();
    holder = std.Thread.spawn(.{}, hold, .{surface}) catch return 1;
    // The host's SIGALRM watchdog bounds a setup failure as well as a read
    // regression. The mutex is never released merely because time elapsed.
    acquired.wait();
    return 0;
}

export fn c11_read_test_release(_: ?*anyopaque) c_int {
    const thread = holder orelse return 1;
    release.set();
    thread.join();
    holder = null;
    return 0;
}

export fn c11_read_test_fail(_: ?*anyopaque, enabled: bool) c_int {
    fail_allocation = enabled;
    return 0;
}

// Use the public C layout without duplicating it. This import is provided only
// by C11ReadTest's test library build.
const c = @cImport({
    @cInclude("ghostty.h");
});

export fn c11_read_test_select(context: ?*anyopaque, selection: ?*const c.ghostty_selection_s) c_int {
    const surface: *Surface = @ptrCast(@alignCast(context.?));
    const core = &surface.core_surface;
    core.renderer_state.mutex.lock();
    defer core.renderer_state.mutex.unlock();
    // Selection setup owns its tracked pins; only formatter allocations belong
    // to the accounting interval being asserted by this fixture.
    const tracking = track_allocation;
    track_allocation = false;
    defer track_allocation = tracking;
    const screen = core.io.terminal.screens.active;
    const selected = selection orelse {
        screen.select(null) catch return 1;
        return 0;
    };
    const start = screen.pages.pin(.{ .viewport = .{
        .x = @intCast(selected.top_left.x),
        .y = selected.top_left.y,
    } }) orelse return 1;
    const end = screen.pages.pin(.{ .viewport = .{
        .x = @intCast(selected.bottom_right.x),
        .y = selected.bottom_right.y,
    } }) orelse return 1;
    screen.select(.{ .bounds = .{ .untracked = .{ .start = start, .end = end } }, .rectangle = selected.rectangle }) catch return 1;
    return 0;
}

// Shared by the independent teardown host. These expose the real queue and
// actual blocked worker count, not a synthetic queue-only producer fixture.
export fn c11_test_fill_app_mailbox(surface: *Surface) u32 {
    const core = &surface.core_surface;
    const queue = &core.app.mailbox;
    while (queue.push(.{ .surface_message = .{
        .surface = core,
        .message = .{ .password_input = false },
    } }, .instant) != 0) {}
    return @intCast(queue.count());
}

export fn c11_test_app_waiter_count(surface: *Surface) u32 {
    const queue = &surface.core_surface.app.mailbox;
    queue.mutex.lock();
    defer queue.mutex.unlock();
    return @intCast(queue.not_full_waiters);
}
