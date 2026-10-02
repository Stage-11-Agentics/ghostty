//! Bounded active-screen capture for an embedder inspecting terminal input.
//! This deliberately has no formatter, allocator, scrollback traversal, or
//! viewport dependency: callers supply all storage and receive only the rows
//! ending at the active cursor.

const std = @import("std");
const Screen = @import("Screen.zig");

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
};

/// Copies no more than the native constants or the provided slice capacities.
/// A partial cell/row remains marked incomplete so callers cannot treat it as
/// an empty prompt. The window includes up to 9 rows above and 6 below the live
/// cursor; it captures multiline composers and nearby dialog hints without
/// touching history.
pub fn capture(
    screen: *const Screen,
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
    const first_y = cursor_y - @min(cursor_y, rows_before_cursor);
    const last_y = @min(screen_rows - 1, cursor_y + rows_after_cursor);

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
            cell_buffer[cell_index] = .{
                .text_offset = start,
                .text_len = @intCast(cursor - start),
                .faint = row_pin.style(cell).flags.faint,
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
