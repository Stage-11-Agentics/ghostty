//! Side-effect-free paste and optional unmodified Return encoding for embedders.
const std = @import("std");
const paste = @import("paste.zig");
const key_encode = @import("key_encode.zig");

pub const Result = struct {
    body: []u8,
    submit: []u8,

    pub fn deinit(self: Result, alloc: std.mem.Allocator) void {
        alloc.free(self.body);
        alloc.free(self.submit);
    }
};

/// Uses the canonical paste sanitizer and keyboard encoder. The caller takes
/// one terminal-mode snapshot; this function neither changes state nor writes IO.
pub fn encode(
    alloc: std.mem.Allocator,
    data: []const u8,
    submit: bool,
    paste_opts: paste.Options,
    key_opts: key_encode.Options,
    linefeed: bool,
) !Result {
    const pasted = if (data.len == 0)
        try alloc.alloc(u8, 0)
    else
        try paste.encodeAlloc(alloc, data, paste_opts);
    defer alloc.free(pasted);
    const body = try expandLinefeed(alloc, pasted, linefeed);
    errdefer alloc.free(body);

    var return_buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&return_buffer);
    if (submit) {
        try key_encode.encode(&writer, .{ .action = .press, .key = .enter }, key_opts);
        try key_encode.encode(&writer, .{ .action = .release, .key = .enter }, key_opts);
    }
    return .{
        .body = body,
        .submit = try expandLinefeed(alloc, writer.buffered(), linefeed),
    };
}

fn expandLinefeed(alloc: std.mem.Allocator, data: []const u8, enabled: bool) ![]u8 {
    const extra = if (enabled) std.mem.count(u8, data, "\r") else 0;
    const len = try std.math.add(usize, data.len, extra);
    const result = try alloc.alloc(u8, len);
    var i: usize = 0;
    for (data) |byte| {
        result[i] = byte;
        i += 1;
        if (enabled and byte == '\r') {
            result[i] = '\n';
            i += 1;
        }
    }
    return result;
}

test "transaction encoding preserves framing sanitization and Return boundary" {
    const alloc = std.testing.allocator;
    const result = try encode(alloc, "hé\n\x1b[201~", true, .{ .bracketed = true }, .{}, false);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("\x1b[200~hé\n [201~\x1b[201~", result.body);
    try std.testing.expectEqualStrings("\r", result.submit);
}

test "transaction encoding applies linefeed to paste and Return" {
    const alloc = std.testing.allocator;
    const result = try encode(alloc, "a\nb\r", true, .{ .bracketed = false }, .{}, true);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("a\r\nb\r\n", result.body);
    try std.testing.expectEqualStrings("\r\n", result.submit);
}

test "transaction encoding includes kitty release only when requested by mode" {
    const alloc = std.testing.allocator;
    const result = try encode(alloc, "", true, .{ .bracketed = true }, .{ .kitty_flags = .{ .report_all = true, .report_events = true } }, false);
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), result.body.len);
    try std.testing.expect(std.mem.indexOf(u8, result.submit, ":3u") != null);
    const draft = try encode(alloc, "draft", false, .{ .bracketed = false }, .{}, false);
    defer draft.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), draft.submit.len);
}

/// Conservative bound for one key event and an optional paired release,
/// including Kitty associated text and CR-to-CRLF expansion.
pub fn keyBound(text_len: usize) !usize {
    return std.math.add(usize, try std.math.mul(usize, text_len, 16), 512);
}

/// Capture canonical key bytes without any key binding or IO side effects.
/// A paired release uses the same event and terminal-mode snapshot.
pub fn encodeKey(
    alloc: std.mem.Allocator,
    event: @import("key.zig").KeyEvent,
    release_after_press: bool,
    key_opts: key_encode.Options,
    linefeed: bool,
    byte_limit: usize,
) ![]u8 {
    if (release_after_press and event.action != .press) return error.InvalidAction;
    const bound = try keyBound(event.utf8.len);
    if (bound > byte_limit) return error.ByteLimit;
    // Each Unicode scalar needs at most seven decimal digits and a delimiter.
    // 256 extra bytes cover both key/event/modifier sequences. A fixed writer
    // refuses overflow rather than returning a truncated capture.
    const buffer = try alloc.alloc(u8, bound / 2);
    defer alloc.free(buffer);
    var writer: std.Io.Writer = .fixed(buffer);
    try key_encode.encode(&writer, event, key_opts);
    if (release_after_press) {
        var release = event;
        release.action = .release;
        try key_encode.encode(&writer, release, key_opts);
    }
    const result = try expandLinefeed(alloc, writer.buffered(), linefeed);
    errdefer alloc.free(result);
    if (result.len > byte_limit) return error.ByteLimit;
    return result;
}

test "synchronous key encoding preserves modes controls and paired release" {
    const alloc = std.testing.allocator;
    const up = @import("key.zig").KeyEvent{ .action = .press, .key = .arrow_up };
    const normal = try encodeKey(alloc, up, true, .{}, false, 512);
    defer alloc.free(normal);
    try std.testing.expectEqualStrings("\x1b[A", normal);
    const application = try encodeKey(alloc, up, true, .{ .cursor_key_application = true }, false, 512);
    defer alloc.free(application);
    try std.testing.expectEqualStrings("\x1bOA", application);
    const ctrl_c = try encodeKey(alloc, .{ .action = .press, .key = .key_c, .mods = .{ .ctrl = true }, .utf8 = "c", .unshifted_codepoint = 'c' }, true, .{}, false, 528);
    defer alloc.free(ctrl_c);
    try std.testing.expectEqualStrings("\x03", ctrl_c);
    const enter = try encodeKey(alloc, .{ .action = .press, .key = .enter }, true, .{}, true, 512);
    defer alloc.free(enter);
    try std.testing.expectEqualStrings("\r\n", enter);
    const kitty = try encodeKey(alloc, .{ .action = .press, .key = .enter }, true, .{ .kitty_flags = .{ .report_all = true, .report_events = true } }, false, 512);
    defer alloc.free(kitty);
    try std.testing.expectEqualStrings("\x1b[13u\x1b[13;1:3u", kitty);
    const text = try encodeKey(alloc, .{ .action = .press, .key = .unidentified, .utf8 = "hé" }, true, .{}, false, try keyBound("hé".len));
    defer alloc.free(text);
    try std.testing.expectEqualStrings("hé", text);
    const control_text = try encodeKey(alloc, .{ .action = .press, .key = .unidentified, .utf8 = "\x03\x1b\x7f" }, false, .{}, false, try keyBound(3));
    defer alloc.free(control_text);
    try std.testing.expectEqualStrings("\x03\x1b\x7f", control_text);
    const associated = try encodeKey(alloc, .{ .action = .press, .key = .key_a, .utf8 = "aé", .unshifted_codepoint = 'a' }, true, .{ .kitty_flags = .{ .report_all = true, .report_events = true, .report_associated = true } }, false, try keyBound("aé".len));
    defer alloc.free(associated);
    try std.testing.expectEqualStrings("\x1b[97;;97:233u\x1b[97;1:3u", associated);
    try std.testing.expectError(error.ByteLimit, encodeKey(alloc, up, true, .{}, false, 511));
    try std.testing.expectError(error.InvalidAction, encodeKey(alloc, .{ .action = .release, .key = .enter }, true, .{}, false, 512));
    try std.testing.expectError(error.Overflow, keyBound(std.math.maxInt(usize)));
}
