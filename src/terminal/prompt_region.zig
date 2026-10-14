//! Bounded active-screen capture for an embedder inspecting terminal input.
//! This deliberately has no formatter, allocator, scrollback traversal, or
//! viewport dependency: callers supply all storage and receive only the rows
//! around the active cursor, or the bottom rows of the active screen.

const std = @import("std");
const Screen = @import("Screen.zig");
const Style = @import("style.zig").Style;

pub const max_rows = 16;
pub const max_cells = 4096;
pub const max_text_bytes = 16 * 1024;

pub const Result = extern struct {
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    row_count: u32 = 0,
    cell_count: u32 = 0,
    text_len: u32 = 0,
    cursor_pending_wrap: bool = false,
    complete: bool = false,
};

pub const Row = extern struct {
    screen_y: u32 = 0,
    cell_start: u32 = 0,
    cell_count: u32 = 0,
    soft_wrap: bool = false,
    wrap_continuation: bool = false,
};

pub const Cell = extern struct {
    text_offset: u32 = 0,
    text_len: u32 = 0,
    faint: bool = false,
    /// SGR 3. Grok draws its next-prompt suggestion italic, not faint.
    italic: bool = false,
    /// True when the cell's foreground is an explicit truecolor (SGR 38;2).
    /// Palette and default colors are not resolved, so they read false.
    fg_rgb_set: bool = false,
    /// True when the cell's background is an explicit truecolor (SGR 48;2),
    /// including a blank cell that carries only its background.
    bg_rgb_set: bool = false,
    /// 0x00RRGGBB when `fg_rgb_set`, else 0. Grok draws its unfocused
    /// composer's placeholder in a dim grey and typed text in a brighter one,
    /// with no faint or italic bit to tell them apart.
    fg_rgb: u32 = 0,
    /// 0x00RRGGBB when `bg_rgb_set`, else 0.
    bg_rgb: u32 = 0,
};

/// Where the bounded window sits on the active screen.
pub const Anchor = enum {
    /// Up to 9 rows above and 6 below the live cursor.
    cursor,
    /// The last 16 rows of the active screen. A TUI that parks its cursor
    /// away from a composer pinned to the bottom (Grok, unfocused) is still
    /// readable. The result still reports the live cursor.
    bottom,
};

/// Copies no more than the native constants or the provided slice capacities.
/// A partial cell/row remains marked incomplete so callers cannot treat it as
/// an empty prompt. The `.cursor` window includes up to 9 rows above and 6
/// below the live cursor; it captures multiline composers and nearby dialog
/// hints without touching history. The `.bottom` window is the last 16 rows.
pub fn capture(
    screen: *const Screen,
    result: *Result,
    row_buffer: []Row,
    cell_buffer: []Cell,
    text_buffer: []u8,
) void {
    captureAt(screen, .cursor, result, row_buffer, cell_buffer, text_buffer);
}

pub fn captureAt(
    screen: *const Screen,
    anchor: Anchor,
    result: *Result,
    row_buffer: []Row,
    cell_buffer: []Cell,
    text_buffer: []u8,
) void {
    result.* = std.mem.zeroes(Result);
    result.cursor_x = @intCast(screen.cursor.x);
    result.cursor_y = @intCast(screen.cursor.y);
    result.cursor_pending_wrap = screen.cursor.pending_wrap;
    result.complete = true;

    const row_limit = @min(row_buffer.len, max_rows);
    const cell_limit = @min(cell_buffer.len, max_cells);
    const text_limit = @min(text_buffer.len, max_text_bytes);
    if (row_limit == 0 or cell_limit == 0 or text_limit == 0) {
        result.complete = false;
        return;
    }

    const cursor_y: usize = @intCast(screen.cursor.y);
    const screen_rows: usize = @intCast(screen.pages.rows);
    if (cursor_y >= screen_rows) {
        result.complete = false;
        return;
    }
    const rows_before_cursor = max_rows - 7;
    const rows_after_cursor = max_rows - rows_before_cursor - 1;
    const first_y = switch (anchor) {
        .cursor => cursor_y - @min(cursor_y, rows_before_cursor),
        .bottom => screen_rows - @min(screen_rows, max_rows),
    };
    const last_y = switch (anchor) {
        .cursor => @min(screen_rows - 1, cursor_y + rows_after_cursor),
        .bottom => screen_rows - 1,
    };

    var row_pin = screen.pages.pin(.{ .active = .{
        .x = 0,
        .y = @intCast(first_y),
    } }) orelse {
        result.complete = false;
        return;
    };

    var y = first_y;
    while (y <= last_y) : (y += 1) {
        if (result.row_count >= @as(u32, @intCast(row_limit))) {
            result.complete = false;
            break;
        }
        const row = row_pin.rowAndCell().row;
        const row_index: usize = @intCast(result.row_count);
        row_buffer[row_index] = .{
            .screen_y = @intCast(y),
            .cell_start = result.cell_count,
            .cell_count = 0,
            .soft_wrap = row.wrap,
            .wrap_continuation = row.wrap_continuation,
        };

        var clipped = false;
        for (row_pin.cells(.all)) |*cell| {
            if (result.cell_count >= @as(u32, @intCast(cell_limit))) {
                result.complete = false;
                clipped = true;
                break;
            }

            const start = result.text_len;
            var cursor: usize = start;
            if (cell.wide != .spacer_tail and cell.wide != .spacer_head) {
                const codepoint = cell.codepoint();
                const encoded = if (codepoint == 0) appendByte(text_buffer, &cursor, text_limit, ' ')
                    else appendCodepoint(text_buffer, &cursor, text_limit, codepoint);
                if (!encoded) {
                    result.complete = false;
                    clipped = true;
                    break;
                }

                if (cell.hasGrapheme()) {
                    if (row_pin.grapheme(cell)) |extra| {
                        for (extra) |cp| {
                            if (!appendCodepoint(text_buffer, &cursor, text_limit, cp)) {
                                result.complete = false;
                                clipped = true;
                                break;
                            }
                        }
                    } else {
                        result.complete = false;
                        clipped = true;
                    }
                }
                if (clipped) break;
            }

            const cell_index: usize = @intCast(result.cell_count);
            const style = row_pin.style(cell);
            const fg = explicitRgb(style.fg_color);
            const bg: ?u32 = switch (cell.content_tag) {
                .bg_color_rgb => packRgb(cell.content.color_rgb.r, cell.content.color_rgb.g, cell.content.color_rgb.b),
                .bg_color_palette => null,
                else => explicitRgb(style.bg_color),
            };
            cell_buffer[cell_index] = .{
                .text_offset = start,
                .text_len = @intCast(cursor - start),
                .faint = style.flags.faint,
                .italic = style.flags.italic,
                .fg_rgb_set = fg != null,
                .bg_rgb_set = bg != null,
                .fg_rgb = fg orelse 0,
                .bg_rgb = bg orelse 0,
            };
            result.cell_count += 1;
            row_buffer[row_index].cell_count += 1;
            result.text_len = @intCast(cursor);
        }
        if (clipped) break;
        result.row_count += 1;
        if (y < last_y) {
            row_pin = row_pin.down(1) orelse {
                result.complete = false;
                break;
            };
        }
    }
}

fn explicitRgb(color: Style.Color) ?u32 {
    return switch (color) {
        .rgb => |rgb| packRgb(rgb.r, rgb.g, rgb.b),
        .none, .palette => null,
    };
}

fn packRgb(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

fn appendByte(buffer: []u8, position: *usize, limit: usize, byte: u8) bool {
    if (position.* >= limit) return false;
    buffer[position.*] = byte;
    position.* += 1;
    return true;
}

fn appendCodepoint(buffer: []u8, position: *usize, limit: usize, cp: u21) bool {
    var encoded: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &encoded) catch return false;
    const byte_len: usize = len;
    if (byte_len > limit - position.*) return false;
    @memcpy(buffer[position.* .. position.* + byte_len], encoded[0..byte_len]);
    position.* += byte_len;
    return true;
}

test "prompt region preserves faint cells and soft-wrap boundaries" {
    const Terminal = @import("Terminal.zig");
    const testing = std.testing;
    var terminal = try Terminal.init(testing.allocator, .{
        .cols = 6,
        .rows = 4,
        .max_scrollback = 0,
    });
    defer terminal.deinit(testing.allocator);

    try terminal.print(0x276F); // Claude's prompt glyph.
    try terminal.print(0x00A0); // Claude's live input marker is followed by NBSP.
    try terminal.setAttribute(.faint);
    for ("suggestion") |byte| try terminal.print(byte);
    try terminal.setAttribute(.unset);

    var result: Result = .{};
    var rows: [max_rows]Row = undefined;
    var cells: [max_cells]Cell = undefined;
    var bytes: [max_text_bytes]u8 = undefined;
    capture(terminal.screens.active, &result, &rows, &cells, &bytes);

    try testing.expect(result.complete);
    try testing.expect(result.row_count >= 2);
    try testing.expect(rows[0].soft_wrap);
    try testing.expect(rows[1].wrap_continuation);
    try testing.expect(std.mem.indexOf(u8, bytes[0..result.text_len], "suggestion") != null);
    var saw_faint = false;
    for (cells[0..result.cell_count]) |cell| saw_faint = saw_faint or cell.faint;
    try testing.expect(saw_faint);
}

test "prompt region preserves italic cells apart from faint" {
    const Terminal = @import("Terminal.zig");
    const testing = std.testing;
    var terminal = try Terminal.init(testing.allocator, .{
        .cols = 16,
        .rows = 2,
        .max_scrollback = 0,
    });
    defer terminal.deinit(testing.allocator);

    for ("ab") |byte| try terminal.print(byte);
    try terminal.setAttribute(.italic);
    for ("cd") |byte| try terminal.print(byte);
    try terminal.setAttribute(.unset);

    var result: Result = .{};
    var rows: [max_rows]Row = undefined;
    var cells: [max_cells]Cell = undefined;
    var bytes: [max_text_bytes]u8 = undefined;
    capture(terminal.screens.active, &result, &rows, &cells, &bytes);

    try testing.expect(result.complete);
    try testing.expect(!cells[0].italic);
    try testing.expect(!cells[1].italic);
    try testing.expect(cells[2].italic);
    try testing.expect(cells[3].italic);
    try testing.expect(!cells[2].faint);
    try testing.expect(!cells[4].italic);
}

test "prompt region reads Grok's recorded suggestion as italic, not faint" {
    const Terminal = @import("Terminal.zig");
    const testing = std.testing;
    var terminal = try Terminal.init(testing.allocator, .{
        .cols = 100,
        .rows = 30,
        .max_scrollback = 0,
    });
    defer terminal.deinit(testing.allocator);
    var stream = terminal.vtStream();
    defer stream.deinit();

    // Bytes recorded from Grok 1.0.50 (Grok 4.7) in a 100x30 pty: the boxed
    // composer's prefix, then the next-prompt suggestion, then the cursor
    // parked on the suggestion's first cell.
    try stream.nextSlice("\x1b[26;1H  \x1b[38;2;80;80;88;48;2;20;20;20m\xe2\x94\x82" ++
        "\x1b[38;2;225;225;225;48;2;20;20;20m \x1b[38;2;200;200;200;48;2;20;20;20m\xe2\x9d\xaf ");
    try stream.nextSlice("\x1b[26;7H\x1b[3m\x1b[38;2;88;88;88;48;2;20;20;20m" ++
        "Reply with the one word CHARLIE and stop.\x1b[29;3H\x1b[23m");
    try stream.nextSlice("\x1b[26;7H");

    var result: Result = .{};
    var rows: [max_rows]Row = undefined;
    var cells: [max_cells]Cell = undefined;
    var bytes: [max_text_bytes]u8 = undefined;
    capture(terminal.screens.active, &result, &rows, &cells, &bytes);

    try testing.expect(result.complete);
    try testing.expectEqual(@as(u32, 6), result.cursor_x);
    try testing.expectEqual(@as(u32, 25), result.cursor_y);
    var prompt_row: ?Row = null;
    for (rows[0..result.row_count]) |row| {
        if (row.screen_y == 25) prompt_row = row;
    }
    const row = prompt_row orelse return error.TestUnexpectedResult;
    const prefix = cells[row.cell_start + 4];
    try testing.expectEqualStrings("\xe2\x9d\xaf", bytes[prefix.text_offset .. prefix.text_offset + prefix.text_len]);
    try testing.expect(!prefix.italic);
    for (cells[row.cell_start + 6 .. row.cell_start + 6 + 41]) |cell| {
        try testing.expect(cell.italic);
        try testing.expect(!cell.faint);
    }
    try testing.expect(!cells[row.cell_start + 6 + 41].italic);
}

test "prompt region keeps explicit truecolor apart from palette and default" {
    const Terminal = @import("Terminal.zig");
    const testing = std.testing;
    var terminal = try Terminal.init(testing.allocator, .{
        .cols = 16,
        .rows = 2,
        .max_scrollback = 0,
    });
    defer terminal.deinit(testing.allocator);
    var stream = terminal.vtStream();
    defer stream.deinit();

    // a: default; b: truecolor fg and bg; c: palette fg and bg; d: truecolor
    // fg only. Then an erase that leaves bg-only cells in a truecolor bg.
    try stream.nextSlice("a\x1b[38;2;78;78;78;48;2;20;20;20mb\x1b[0m" ++
        "\x1b[31;44mc\x1b[0m\x1b[38;2;1;2;3md\x1b[0m");
    try stream.nextSlice("\x1b[48;2;9;8;7m\x1b[K\x1b[0m");

    var result: Result = .{};
    var rows: [max_rows]Row = undefined;
    var cells: [max_cells]Cell = undefined;
    var bytes: [max_text_bytes]u8 = undefined;
    capture(terminal.screens.active, &result, &rows, &cells, &bytes);

    try testing.expect(result.complete);
    try testing.expect(!cells[0].fg_rgb_set and !cells[0].bg_rgb_set);
    try testing.expect(cells[1].fg_rgb_set and cells[1].bg_rgb_set);
    try testing.expectEqual(@as(u32, 0x4E4E4E), cells[1].fg_rgb);
    try testing.expectEqual(@as(u32, 0x141414), cells[1].bg_rgb);
    try testing.expect(!cells[2].fg_rgb_set and !cells[2].bg_rgb_set);
    try testing.expect(cells[3].fg_rgb_set and !cells[3].bg_rgb_set);
    try testing.expectEqual(@as(u32, 0x010203), cells[3].fg_rgb);
    try testing.expect(cells[5].bg_rgb_set);
    try testing.expectEqual(@as(u32, 0x090807), cells[5].bg_rgb);
}

test "prompt region bottom anchor reads the last rows, not the cursor's" {
    const Terminal = @import("Terminal.zig");
    const testing = std.testing;
    var terminal = try Terminal.init(testing.allocator, .{
        .cols = 8,
        .rows = 30,
        .max_scrollback = 0,
    });
    defer terminal.deinit(testing.allocator);
    var stream = terminal.vtStream();
    defer stream.deinit();
    try stream.nextSlice("\x1b[30;1Hbottom\x1b[3;2H");

    var result: Result = .{};
    var rows: [max_rows]Row = undefined;
    var cells: [max_cells]Cell = undefined;
    var bytes: [max_text_bytes]u8 = undefined;

    captureAt(terminal.screens.active, .cursor, &result, &rows, &cells, &bytes);
    try testing.expectEqual(@as(u32, 0), rows[0].screen_y);
    try testing.expectEqual(@as(u32, 8), rows[result.row_count - 1].screen_y);
    try testing.expect(std.mem.indexOf(u8, bytes[0..result.text_len], "bottom") == null);

    captureAt(terminal.screens.active, .bottom, &result, &rows, &cells, &bytes);
    try testing.expect(result.complete);
    try testing.expectEqual(@as(u32, 16), result.row_count);
    try testing.expectEqual(@as(u32, 14), rows[0].screen_y);
    try testing.expectEqual(@as(u32, 29), rows[15].screen_y);
    try testing.expectEqual(@as(u32, 1), result.cursor_x);
    try testing.expectEqual(@as(u32, 2), result.cursor_y);
    try testing.expect(std.mem.indexOf(u8, bytes[0..result.text_len], "bottom") != null);
}

test "prompt region bottom anchor on a short screen reads every row" {
    const Terminal = @import("Terminal.zig");
    const testing = std.testing;
    var terminal = try Terminal.init(testing.allocator, .{
        .cols = 8,
        .rows = 5,
        .max_scrollback = 0,
    });
    defer terminal.deinit(testing.allocator);

    var result: Result = .{};
    var rows: [max_rows]Row = undefined;
    var cells: [max_cells]Cell = undefined;
    var bytes: [max_text_bytes]u8 = undefined;
    captureAt(terminal.screens.active, .bottom, &result, &rows, &cells, &bytes);
    try testing.expect(result.complete);
    try testing.expectEqual(@as(u32, 5), result.row_count);
    try testing.expectEqual(@as(u32, 0), rows[0].screen_y);
}

test "prompt region reads Grok's recorded unfocused placeholder colors" {
    const Terminal = @import("Terminal.zig");
    const testing = std.testing;
    var terminal = try Terminal.init(testing.allocator, .{
        .cols = 100,
        .rows = 30,
        .max_scrollback = 0,
    });
    defer terminal.deinit(testing.allocator);
    var stream = terminal.vtStream();
    defer stream.deinit();

    // Bytes recorded from Grok 1.0.52 (Grok 4.7) in a 100x30 pty after a
    // click in its transcript: the boxed composer's dim prefix, the dim
    // `Build anything` placeholder, then the cursor hidden and parked on the
    // footer row below the box. Grok writes no faint and no italic here.
    try stream.nextSlice("\x1b[26;3H\x1b[38;2;50;50;55;48;2;20;20;20m\xe2\x94\x82" ++
        "\x1b[38;2;155;155;155;48;2;20;20;20m \x1b[38;2;65;65;65;48;2;20;20;20m\xe2\x9d\xaf " ++
        "\x1b[38;2;78;78;78;48;2;20;20;20mBuild anything" ++
        "\x1b[38;2;155;155;155;48;2;20;20;20m             ");
    try stream.nextSlice("\x1b[29;63H\x1b[0m\x1b[?25l");

    var result: Result = .{};
    var rows: [max_rows]Row = undefined;
    var cells: [max_cells]Cell = undefined;
    var bytes: [max_text_bytes]u8 = undefined;
    capture(terminal.screens.active, &result, &rows, &cells, &bytes);

    try testing.expect(result.complete);
    try testing.expectEqual(@as(u32, 28), result.cursor_y);
    var prompt_row: ?Row = null;
    for (rows[0..result.row_count]) |row| {
        if (row.screen_y == 25) prompt_row = row;
    }
    const row = prompt_row orelse return error.TestUnexpectedResult;
    const glyph = cells[row.cell_start + 4];
    try testing.expectEqualStrings("\xe2\x9d\xaf", bytes[glyph.text_offset .. glyph.text_offset + glyph.text_len]);
    try testing.expectEqual(@as(u32, 0x414141), glyph.fg_rgb);
    for (cells[row.cell_start + 6 .. row.cell_start + 6 + 14]) |cell| {
        try testing.expect(!cell.faint);
        try testing.expect(!cell.italic);
        try testing.expect(cell.fg_rgb_set and cell.bg_rgb_set);
        try testing.expectEqual(@as(u32, 0x4E4E4E), cell.fg_rgb);
        try testing.expectEqual(@as(u32, 0x141414), cell.bg_rgb);
    }
    try testing.expectEqual(@as(u32, 0x9B9B9B), cells[row.cell_start + 6 + 14].fg_rgb);
}

test "prompt region marks bounded cell copies incomplete" {
    const Terminal = @import("Terminal.zig");
    const testing = std.testing;
    var terminal = try Terminal.init(testing.allocator, .{
        .cols = 8,
        .rows = 2,
        .max_scrollback = 0,
    });
    defer terminal.deinit(testing.allocator);
    for ("draft") |byte| try terminal.print(byte);

    var result: Result = .{};
    var rows: [1]Row = undefined;
    var cells: [2]Cell = undefined;
    var bytes: [max_text_bytes]u8 = undefined;
    capture(terminal.screens.active, &result, &rows, &cells, &bytes);

    try testing.expect(!result.complete);
    try testing.expect(result.row_count <= rows.len);
    try testing.expect(result.cell_count <= cells.len);
    try testing.expect(result.text_len <= bytes.len);
}

test "prompt region marks bounded text copies incomplete" {
    const Terminal = @import("Terminal.zig");
    const testing = std.testing;
    var terminal = try Terminal.init(testing.allocator, .{
        .cols = 8,
        .rows = 2,
        .max_scrollback = 0,
    });
    defer terminal.deinit(testing.allocator);
    for ("draft") |byte| try terminal.print(byte);

    var result: Result = .{};
    var rows: [max_rows]Row = undefined;
    var cells: [max_cells]Cell = undefined;
    var bytes: [2]u8 = undefined;
    capture(terminal.screens.active, &result, &rows, &cells, &bytes);

    try testing.expect(!result.complete);
    try testing.expect(result.row_count <= rows.len);
    try testing.expect(result.cell_count <= cells.len);
    try testing.expect(result.text_len <= bytes.len);
}
