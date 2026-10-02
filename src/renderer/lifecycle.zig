//! Renderer lifecycle publication and bounded mailbox turns. Kept independent
//! of GPU state so the production scheduling policy can be exercised directly.
const std = @import("std");

/// Each atomic slot owns one latest-value request. Zero is empty, one is false,
/// two is true. A racing store is either consumed by swap or remains pending.
pub const SurfaceStateRequests = struct {
    visible: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    focused: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    pub fn publishVisible(self: *SurfaceStateRequests, value: bool) void {
        self.visible.store(if (value) 2 else 1, .release);
    }

    pub fn publishFocused(self: *SurfaceStateRequests, value: bool) void {
        self.focused.store(if (value) 2 else 1, .release);
    }

    pub fn takeVisible(self: *SurfaceStateRequests) ?bool {
        return decode(self.visible.swap(0, .acq_rel));
    }

    pub fn takeFocused(self: *SurfaceStateRequests) ?bool {
        return decode(self.focused.swap(0, .acq_rel));
    }

    fn decode(value: u8) ?bool {
        return switch (value) {
            0 => null,
            1 => false,
            2 => true,
            else => unreachable,
        };
    }
};

/// Process at most the initial queue count. Continuous refill cannot starve
/// lifecycle application or the render after this turn. Finishing and re-waking
/// also run on handler errors because producer wakeups may have coalesced with
/// the wake being handled. The caller owns rendering and error reporting.
pub fn drainMailboxTurn(
    queue: anytype,
    context: anytype,
    comptime consume: anytype,
    comptime finish: anytype,
    comptime wake: anytype,
) !void {
    var remaining = queue.count();
    defer if (queue.count() > 0) wake(context);
    defer finish(context);
    while (remaining > 0) : (remaining -= 1) {
        const message = queue.pop() orelse break;
        try consume(context, message);
    }
}

const TestQueue = @import("../datastruct/blocking_queue.zig").BlockingQueue(u8, 4);

const TestConsumer = struct {
    queue: *TestQueue,
    requests: SurfaceStateRequests = .{},
    visible: bool = false,
    focused: bool = false,
    processed: [8]u8 = undefined,
    processed_len: usize = 0,
    turns_finished: usize = 0,
    wakes: usize = 0,
    refill: bool = false,
    fail: bool = false,
    publish_during_consume: bool = false,

    fn consume(self: *TestConsumer, message: u8) !void {
        self.processed[self.processed_len] = message;
        self.processed_len += 1;
        if (self.refill) {
            try std.testing.expect(self.queue.push(message + 10, .{ .instant = {} }) > 0);
        }
        if (self.publish_during_consume) {
            self.requests.publishVisible(true);
            self.requests.publishFocused(true);
        }
        if (self.fail) return error.TestHandlerFailure;
    }

    fn finish(self: *TestConsumer) void {
        self.turns_finished += 1;
        if (self.requests.takeVisible()) |v| self.visible = v;
        if (self.requests.takeFocused()) |v| self.focused = v;
    }

    fn wake(self: *TestConsumer) void {
        self.wakes += 1;
    }

    fn drain(self: *TestConsumer) !void {
        try drainMailboxTurn(self.queue, self, consume, finish, wake);
    }
};

test "lifecycle publication bypasses full mailbox and retains latest values" {
    var queue: TestQueue = .{};
    for (0..4) |i| try std.testing.expect(queue.push(@intCast(i), .{ .instant = {} }) > 0);
    try std.testing.expectEqual(@as(TestQueue.Size, 0), queue.push(99, .{ .instant = {} }));
    var consumer: TestConsumer = .{ .queue = &queue };
    for (0..1000) |_| {
        consumer.requests.publishVisible(false);
        consumer.requests.publishFocused(false);
        consumer.requests.publishVisible(true);
        consumer.requests.publishFocused(true);
    }
    // Publishing never needed a queue slot or consumer progress.
    try std.testing.expectEqual(@as(usize, 4), @as(usize, queue.count()));
    try consumer.drain();
    try std.testing.expect(consumer.visible);
    try std.testing.expect(consumer.focused);
    try std.testing.expectEqual(@as(usize, 1), consumer.turns_finished);
    try std.testing.expectEqual(@as(usize, 0), consumer.wakes);
}

test "lifecycle slots consume independently and preserve later publications" {
    var requests: SurfaceStateRequests = .{};
    requests.publishVisible(false);
    requests.publishFocused(true);
    try std.testing.expectEqual(@as(?bool, false), requests.takeVisible());
    // A publication following the take remains pending. Consuming one slot
    // cannot discard another property if the caller exits before applying it.
    requests.publishVisible(true);
    try std.testing.expectEqual(@as(?bool, true), requests.takeFocused());
    try std.testing.expectEqual(@as(?bool, true), requests.takeVisible());
    try std.testing.expectEqual(@as(?bool, null), requests.takeVisible());
    try std.testing.expectEqual(@as(?bool, null), requests.takeFocused());
}

test "bounded renderer turn yields under refill and retains next wake" {
    var queue: TestQueue = .{};
    try std.testing.expect(queue.push(1, .{ .instant = {} }) > 0);
    try std.testing.expect(queue.push(2, .{ .instant = {} }) > 0);
    var consumer: TestConsumer = .{
        .queue = &queue,
        .refill = true,
        .publish_during_consume = true,
    };
    try consumer.drain();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, consumer.processed[0..consumer.processed_len]);
    try std.testing.expect(consumer.visible and consumer.focused);
    try std.testing.expectEqual(@as(usize, 1), consumer.wakes);

    // Model the retained wake alone, without an unrelated input event.
    consumer.refill = false;
    consumer.publish_during_consume = false;
    try consumer.drain();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 11, 12 }, consumer.processed[0..consumer.processed_len]);
    try std.testing.expectEqual(@as(usize, 2), consumer.turns_finished);
    try std.testing.expectEqual(@as(usize, 1), consumer.wakes);
}

test "handler error still applies lifecycle and retains queued work wake" {
    var queue: TestQueue = .{};
    try std.testing.expect(queue.push(1, .{ .instant = {} }) > 0);
    try std.testing.expect(queue.push(2, .{ .instant = {} }) > 0);
    var consumer: TestConsumer = .{
        .queue = &queue,
        .fail = true,
        .publish_during_consume = true,
    };
    try std.testing.expectError(error.TestHandlerFailure, consumer.drain());
    try std.testing.expect(consumer.visible and consumer.focused);
    try std.testing.expectEqual(@as(usize, 1), consumer.turns_finished);
    try std.testing.expectEqual(@as(usize, 1), consumer.wakes);
    consumer.fail = false;
    try consumer.drain();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, consumer.processed[0..consumer.processed_len]);
}
