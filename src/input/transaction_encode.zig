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
