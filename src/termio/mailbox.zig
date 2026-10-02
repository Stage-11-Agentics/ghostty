const std = @import("std");
const Allocator = std.mem.Allocator;
const xev = @import("../global.zig").xev;
const renderer = @import("../renderer.zig");
const termio = @import("../termio.zig");
const BlockingQueue = @import("../datastruct/main.zig").BlockingQueue;

const log = std.log.scoped(.io_writer);

/// A queue used for storing messages that is periodically drained.
/// Typically used by a multi-threaded application. The capacity is
/// hardcoded to a value that empirically has made sense for Ghostty usage
/// but I'm open to changing it with good arguments.
const Queue = BlockingQueue(termio.Message, 64);

/// The location to where write-related messages are sent.
pub const Mailbox = union(enum) {
    // /// Write messages to an unbounded list backed by an allocator.
    // /// This is useful for single-threaded applications where you're not
    // /// afraid of running out of memory. You should be careful that you're
    // /// processing this in a timely manner though since some heavy workloads
    // /// will produce a LOT of messages.
    // ///
    // /// At the time of authoring this, the primary use case for this is
    // /// testing more than anything, but it probably will have a use case
    // /// in libghostty eventually.
    // unbounded: std.ArrayList(termio.Message),

    /// Write messages to a SPSC queue for multi-threaded applications.
    spsc: struct {
        queue: *Queue,
        wakeup: xev.Async,
        stop: ?*const std.atomic.Value(bool) = null,
    },

    /// Init the SPSC writer.
    pub fn initSPSC(alloc: Allocator) !Mailbox {
        var queue = try Queue.create(alloc);
        errdefer queue.destroy(alloc);

        var wakeup = try xev.Async.init();
        errdefer wakeup.deinit();

        return .{ .spsc = .{ .queue = queue, .wakeup = wakeup } };
    }

    pub fn deinit(self: *Mailbox, alloc: Allocator) void {
        switch (self.*) {
            .spsc => |*v| {
                while (v.queue.pop()) |msg| msg.deinit();
                v.queue.destroy(alloc);
                v.wakeup.deinit();
            },
        }
    }

    /// Sends the given message without notifying there are messages.
    ///
    /// If the optional mutex is given, it must already be LOCKED. If the
    /// send would block, we'll unlock this mutex, resend the message, and
    /// lock it again. This handles an edge case where queues are full.
    /// This may not apply to all writer types.
    pub fn send(
        self: *Mailbox,
        msg: termio.Message,
        mutex: ?*std.Thread.Mutex,
    ) void {
        switch (self.*) {
            .spsc => |*mb| send: {
                // Try to write to the queue with an instant timeout. This is the
                // fast path because we can queue without a lock.
                if (mb.queue.push(msg, .{ .instant = {} }) > 0) break :send;

                // If we enter this conditional, the queue is full. We wake up
                // the writer thread so that it can process messages to clear up
                // space. However, the writer thread may require the renderer
                // lock so we need to unlock.
                mb.wakeup.notify() catch |err| {
                    log.warn("failed to wake up writer, data will be dropped err={}", .{err});
                    msg.deinit();
                    return;
                };

                // Unlock the renderer state so the writer thread can acquire it.
                // Then try to queue our message before continuing. This is a very
                // slow path because we are having a lot of contention for data.
                // But this only gets triggered in certain pathological cases.
                //
                // Note that writes themselves don't require a lock, but there
                // are other messages in the writer queue (resize, focus) that
                // could acquire the lock. This is why we have to release our lock
                // here.
                if (mutex) |m| m.unlock();
                defer if (mutex) |m| m.lock();
                if (mb.stop) |stop| {
                    if (mb.queue.pushCancelable(msg, stop) == 0) msg.deinit();
                } else {
                    while (mb.queue.push(msg, .forever) == 0) {}
                }
            },
        }
    }

    /// App-thread ordered sends cannot wait for a worker that may need main.
    pub fn sendNonBlocking(self: *Mailbox, msg: termio.Message) void {
        switch (self.*) {
            .spsc => |*mb| {
                _ = mb.queue.pushNonBlocking(msg) catch |err| {
                    msg.deinit();
                    log.err("unable to enqueue IO message err={}", .{err});
                    return;
                };
            },
        }
        self.notify();
    }

    /// Notify that there are new messages. This may be a noop depending
    /// on the writer type.
    pub fn notify(self: *Mailbox) void {
        switch (self.*) {
            .spsc => |*v| v.wakeup.notify() catch |err| {
                log.warn("failed to notify writer, data will be dropped err={}", .{err});
            },
        }
    }
};

test "cancelled IO publication disposes its owned write" {
    const alloc = std.testing.allocator;
    var mailbox = try Mailbox.initSPSC(alloc);
    defer mailbox.deinit(alloc);
    var stop = std.atomic.Value(bool).init(false);
    mailbox.spsc.stop = &stop;
    for (0..64) |_| _ = mailbox.spsc.queue.push(.{ .write_stable = "fill" }, .instant);
    const payload = try alloc.dupe(u8, "owned paste payload");
    const Worker = struct {
        fn run(mb: *Mailbox, bytes: []u8) void {
            mb.send(.{ .write_alloc = .{ .alloc = std.testing.allocator, .data = bytes } }, null);
        }
    };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{ &mailbox, payload });
    std.Thread.sleep(10 * std.time.ns_per_ms);
    stop.store(true, .release);
    worker.join();
    try std.testing.expectEqual(@as(Queue.Size, 64), mailbox.spsc.queue.count());
    // testing.allocator asserts that the cancelled payload was freed exactly once.
}

test "IO spill shutdown frees accepted owned payloads" {
    const alloc = std.testing.allocator;
    var mailbox = try Mailbox.initSPSC(alloc);
    defer mailbox.deinit(alloc);
    for (0..64) |_| _ = mailbox.spsc.queue.push(.{ .write_stable = "fill" }, .instant);
    const payload = try alloc.dupe(u8, "accepted paste payload");
    mailbox.sendNonBlocking(.{ .write_alloc = .{ .alloc = alloc, .data = payload } });
    try std.testing.expectEqual(@as(Queue.Size, 65), mailbox.spsc.queue.count());
    // No consumer runs. Shutdown owns both the spill and its payload.
}
