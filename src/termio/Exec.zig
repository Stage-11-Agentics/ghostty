//! Exec implements the logic for starting and stopping a subprocess with a
//! pty as well as spinning up the necessary read thread to read from the
//! pty and forward it to the Termio instance.
const Exec = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const posix = std.posix;
const xev = @import("../global.zig").xev;
const apprt = @import("../apprt.zig");
const build_config = @import("../build_config.zig");
const configpkg = @import("../config.zig");
const crash = @import("../crash/main.zig");
const fastmem = @import("../fastmem.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const shell_integration = @import("shell_integration.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const Command = @import("../Command.zig");
const ptypkg = @import("../pty.zig");
const Pty = ptypkg.Pty;
const EnvMap = std.process.EnvMap;
const PasswdEntry = internal_os.passwd.Entry;
const windows = internal_os.windows;

const darwin_proc = if (builtin.target.os.tag.isDarwin()) struct {
    const c = @cImport({
        @cInclude("sys/sysctl.h");
    });
} else struct {};

const log = std.log.scoped(.io_exec);

/// The termios poll rate in milliseconds.
const TERMIOS_POLL_MS = 200;

/// If we build with flatpak support then we have to keep track of
/// a potential execution on the host.
const FlatpakHostCommand = if (!build_config.flatpak) struct {
    pub const Completion = struct {};
} else internal_os.FlatpakHostCommand;

/// The subprocess state for our exec backend.
subprocess: Subprocess,

/// Initialize the exec state. This will NOT start it, this only sets
/// up the internal state necessary to start it later.
pub fn init(
    alloc: Allocator,
    cfg: Config,
) !Exec {
    var subprocess = try Subprocess.init(alloc, cfg);
    errdefer subprocess.deinit();

    return .{ .subprocess = subprocess };
}

pub fn deinit(self: *Exec) void {
    self.subprocess.deinit();
}

/// Call to initialize the terminal state as necessary for this backend.
/// This is called before any termio begins. This should not be called
/// after termio begins because it may put the internal terminal state
/// into a bad state.
pub fn initTerminal(self: *Exec, term: *terminal.Terminal) void {
    // If we have an initial pwd requested by the subprocess, then we
    // set that on the terminal now. This allows rapidly initializing
    // new surfaces to use the proper pwd.
    if (self.subprocess.cwd) |cwd| term.setPwd(cwd) catch |err| {
        log.warn("error setting initial pwd err={}", .{err});
    };

    // Setup our initial grid/screen size from the terminal. This
    // can't fail because the pty should not exist at this point.
    self.resize(.{
        .columns = term.cols,
        .rows = term.rows,
    }, .{
        .width = term.width_px,
        .height = term.height_px,
    }) catch unreachable;
}

pub fn threadEnter(
    self: *Exec,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    // Start our subprocess
    const pty_fds = self.subprocess.start(alloc) catch |err| {
        // If we specifically got this error then we are in the forked
        // process and our child failed to execute. If we DIDN'T
        // get this specific error then we're in the parent and
        // we need to bubble it up.
        if (err != error.ExecFailedInChild) return err;

        // We're in the child. Nothing more we can do but abnormal exit.
        // The Command will output some additional information.
        posix.exit(1);
    };
    errdefer self.subprocess.stop();

    // Watcher to detect subprocess exit
    var process: ?xev.Process = if (self.subprocess.process) |v| switch (v) {
        .fork_exec => |cmd| try xev.Process.init(
            cmd.pid orelse return error.ProcessNoPid,
        ),

        // If we're executing via Flatpak then we can't do
        // traditional process watching (its implemented
        // as a special case in os/flatpak.zig) since the
        // command is on the host.
        .flatpak => null,
    } else return error.ProcessNotStarted;
    errdefer if (process) |*p| p.deinit();

    // Track our process start time for abnormal exits
    const process_start = try std.time.Instant.now();

    // Create our pipe that we'll use to kill our read thread.
    // pipe[0] is the read end, pipe[1] is the write end.
    const pipe = try internal_os.pipe();
    errdefer posix.close(pipe[0]);
    errdefer posix.close(pipe[1]);

    // Setup our stream so that we can write.
    var stream = xev.Stream.initFd(pty_fds.write);
    errdefer stream.deinit();

    // Start our timer to read termios state changes. This is used
    // to detect things such as when password input is being done
    // so we can render the terminal in a different way.
    var termios_timer = try xev.Timer.init();
    errdefer termios_timer.deinit();

    // Start our read thread
    const read_thread = try std.Thread.spawn(
        .{},
        if (builtin.os.tag == .windows) ReadThread.threadMainWindows else ReadThread.threadMainPosix,
        .{ pty_fds.read, io, pipe[0] },
    );
    read_thread.setName("io-reader") catch {};

    // Setup our threadata backend state to be our own
    td.backend = .{ .exec = .{
        .start = process_start,
        .write_stream = stream,
        .write_pool = std.heap.MemoryPool(ThreadData.Write).init(alloc),
        .process = process,
        .read_thread = read_thread,
        .read_thread_pipe = pipe[1],
        .read_thread_fd = pty_fds.read,
        .termios_timer = termios_timer,
    } };

    // Start our process watcher. If we have an xev.Process use it.
    if (process) |*p| p.wait(
        td.loop,
        &td.backend.exec.process_wait_c,
        termio.Termio.ThreadData,
        td,
        processExit,
    ) else if (comptime build_config.flatpak) flatpak: {
        switch (self.subprocess.process orelse break :flatpak) {
            // If we're in flatpak and we have a flatpak command
            // then we can run the special flatpak logic for watching.
            .flatpak => |*c| c.waitXev(
                td.loop,
                &td.backend.exec.flatpak_wait_c,
                termio.Termio.ThreadData,
                td,
                flatpakExit,
            ),

            .fork_exec => {},
        }
    }

    // Start our termios timer. We don't support this on Windows.
    // Fundamentally, we could support this on Windows so we're just
    // waiting for someone to implement it.
    if (comptime builtin.os.tag != .windows) {
        termios_timer.run(
            td.loop,
            &td.backend.exec.termios_timer_c,
            TERMIOS_POLL_MS,
            termio.Termio.ThreadData,
            td,
            termiosTimer,
        );
    }
}

pub fn threadExit(self: *Exec, td: *termio.Termio.ThreadData) void {
    assert(td.backend == .exec);
    const exec = &td.backend.exec;

    if (exec.exited) self.subprocess.externalExit();
    // Wake the reader before waiting on process shutdown. Surface cancellation
    // also breaks its inner read loop while output is still flowing.
    _ = posix.write(exec.read_thread_pipe, "x") catch |err| switch (err) {
        // BrokenPipe means that our read thread is closed already,
        // which is completely fine since that is what we were trying
        // to achieve.
        error.BrokenPipe => {},

        else => log.warn(
            "error writing to read thread quit pipe err={}",
            .{err},
        ),
    };

    if (comptime builtin.os.tag == .windows) {
        // Interrupt the blocking read so the thread can see the quit message
        if (windows.kernel32.CancelIoEx(exec.read_thread_fd, null) == 0) {
            switch (windows.kernel32.GetLastError()) {
                .NOT_FOUND => {},
                else => |err| log.warn("error interrupting read thread err={}", .{err}),
            }
        }
    }

    if (comptime builtin.os.tag == .windows) {
        self.subprocess.stop();
        exec.read_thread.join();
    } else if (td.surface_mailbox.surface.stopping.load(.acquire)) {
        // No callback will run after this IO loop exits. Join the cancelled
        // reader before closing its descriptor, then release the terminal so
        // protected launchers such as macOS login observe a real hangup.
        exec.read_thread.join();
        self.subprocess.stopClosingPty();
    } else {
        // Initialization error cleanup can run before surface cancellation is
        // published. Preserve stop-before-join for a continuously noisy child.
        self.subprocess.stop();
        exec.read_thread.join();
    }
}

pub fn focusGained(
    self: *Exec,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;

    assert(td.backend == .exec);
    const execdata = &td.backend.exec;

    if (!focused) {
        // Flag the timer to end on the next iteration. This is
        // a lot cheaper than doing full timer cancellation.
        execdata.termios_timer_running = false;
    } else {
        // Always set this to true. There is a race condition if we lose
        // focus and regain focus before the termios timer ticks where
        // if we don't set this unconditionally the timer will end on
        // the next iteration.
        execdata.termios_timer_running = true;

        // If we're focused, we want to start our termios timer. We
        // only do this if it isn't already running. We use the termios
        // callback because that'll trigger an immediate state check AND
        // start the timer.
        if (execdata.termios_timer_c.state() != .active) {
            _ = termiosTimer(td, undefined, undefined, {});
        }
    }
}

pub fn resize(
    self: *Exec,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    return try self.subprocess.resize(grid_size, screen_size);
}

fn processExitCommon(td: *termio.Termio.ThreadData, exit_code: u32) void {
    assert(td.backend == .exec);
    const execdata = &td.backend.exec;
    execdata.exited = true;

    // Determine how long the process was running for.
    const runtime_ms: ?u64 = runtime: {
        const process_end = std.time.Instant.now() catch break :runtime null;
        const runtime_ns = process_end.since(execdata.start);
        const runtime_ms = runtime_ns / std.time.ns_per_ms;
        break :runtime runtime_ms;
    };
    log.debug(
        "child process exited status={} runtime={}ms",
        .{ exit_code, runtime_ms orelse 0 },
    );

    // We always notify the surface immediately that the child has
    // exited and some metadata about the exit.
    _ = td.surface_mailbox.push(.{
        .child_exited = .{
            .exit_code = exit_code,
            .runtime_ms = runtime_ms orelse 0,
        },
    }, .{ .forever = {} });
}

fn processExit(
    td_: ?*termio.Termio.ThreadData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Process.WaitError!u32,
) xev.CallbackAction {
    const exit_code = r catch unreachable;
    processExitCommon(td_.?, exit_code);
    return .disarm;
}

fn flatpakExit(
    td_: ?*termio.Termio.ThreadData,
    _: *xev.Loop,
    _: *FlatpakHostCommand.Completion,
    r: FlatpakHostCommand.WaitError!u8,
) void {
    const exit_code = r catch unreachable;
    processExitCommon(td_.?, exit_code);
}

fn termiosTimer(
    td_: ?*termio.Termio.ThreadData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    // log.debug("termios timer fired", .{});

    // This should never happen because we guard starting our
    // timer on windows but we want this assertion to fire if
    // we ever do start the timer on windows.
    // TODO: support on windows
    if (comptime builtin.os.tag == .windows) {
        @panic("termios timer not implemented on Windows");
    }

    _ = r catch |err| switch (err) {
        // This is sent when our timer is canceled. That's fine.
        error.Canceled => return .disarm,

        else => {
            log.warn("error in termios timer callback err={}", .{err});
            @panic("crash in termios timer callback");
        },
    };

    const td = td_.?;
    assert(td.backend == .exec);
    const exec = &td.backend.exec;

    // This is kind of hacky but we rebuild a Pty struct to get the
    // termios data.
    const mode: ptypkg.Mode = (Pty{
        .master = exec.read_thread_fd,
        .slave = undefined,
    }).getMode() catch |err| err: {
        log.warn("error getting termios mode err={}", .{err});

        // If we have an error we return the default mode values
        // which are the likely values.
        break :err .{};
    };

    // If the mode changed, then we process it.
    if (!std.meta.eql(mode, exec.termios_mode)) mode_change: {
        log.debug("termios change mode={}", .{mode});
        exec.termios_mode = mode;

        // We assume we're in some sort of password input if we're
        // in canonical mode and not echoing. This is a heuristic.
        const password_input = mode.canonical and !mode.echo;

        // If our password input state changed on the terminal then
        // we notify the surface.
        {
            td.renderer_state.mutex.lock();
            defer td.renderer_state.mutex.unlock();
            const t = td.renderer_state.terminal;
            if (t.flags.password_input == password_input) {
                break :mode_change;
            }
        }

        // We have to notify the surface that we're in password input.
        // We must block on this because the balanced true/false state
        // of this is critical to apprt behavior.
        _ = td.surface_mailbox.push(.{
            .password_input = password_input,
        }, .{ .forever = {} });
    }

    // Repeat the timer
    if (exec.termios_timer_running) {
        exec.termios_timer.run(
            td.loop,
            &exec.termios_timer_c,
            TERMIOS_POLL_MS,
            termio.Termio.ThreadData,
            td,
            termiosTimer,
        );
    }

    return .disarm;
}

pub fn queueWrite(
    self: *Exec,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = self;
    _ = alloc; // This Zig version stores the allocator in MemoryPool.
    const exec = &td.backend.exec;

    // If our process is exited then we don't send any more writes.
    if (exec.exited) return;

    // We go through and chunk the data if necessary to fit into
    // our cached buffers that we can queue to the stream.
    var i: usize = 0;
    while (i < data.len) {
        const w = try exec.write_pool.create();
        w.td = exec;
        const buf = &w.buf;
        const slice = slice: {
            // The maximum end index is either the end of our data or
            // the end of our buffer, whichever is smaller.
            const max = @min(data.len, i + buf.len);

            // Fast
            if (!linefeed) {
                fastmem.copy(u8, buf, data[i..max]);
                const len = max - i;
                i = max;
                break :slice buf[0..len];
            }

            // Slow, have to replace \r with \r\n
            var buf_i: usize = 0;
            while (i < data.len and buf_i < buf.len - 1) {
                const ch = data[i];
                i += 1;

                if (ch != '\r') {
                    buf[buf_i] = ch;
                    buf_i += 1;
                    continue;
                }

                // CRLF
                buf[buf_i] = '\r';
                buf[buf_i + 1] = '\n';
                buf_i += 2;
            }

            break :slice buf[0..buf_i];
        };

        //for (slice) |b| log.warn("write: {x}", .{b});

        exec.write_stream.queueWrite(
            td.loop,
            &exec.write_queue,
            &w.req,
            .{ .slice = slice },
            ThreadData.Write,
            w,
            ttyWrite,
        );
    }
}

fn ttyWrite(
    w_: ?*ThreadData.Write,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Stream,
    _: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    const w = w_.?;
    w.td.write_pool.destroy(w);

    const d = r catch |err| {
        log.err("write error: {}", .{err});
        return .disarm;
    };
    _ = d;
    //log.info("WROTE: {d}", .{d});

    return .disarm;
}

/// The thread local data for the exec implementation.
pub const ThreadData = struct {
    /// One pointer-stable state per queued write. Completion returns this exact
    /// request and buffer together, even when completions arrive out of order.
    pub const Write = struct {
        td: *ThreadData,
        req: xev.WriteRequest,
        buf: [64]u8,
    };

    /// Process start time and boolean of whether its already exited.
    start: std.time.Instant,
    exited: bool = false,

    /// The data stream is the main IO for the pty.
    write_stream: xev.Stream,

    /// The process watcher
    process: ?xev.Process,

    write_pool: std.heap.MemoryPool(Write),

    /// The write queue for the data stream.
    write_queue: xev.WriteQueue = .{},

    /// This is used for both waiting for the process to exit and then
    /// subsequently to wait for the data_stream to close.
    process_wait_c: xev.Completion = .{},

    // The completion specific to Flatpak process waiting. If
    // we aren't compiling with Flatpak support this is zero-sized.
    flatpak_wait_c: FlatpakHostCommand.Completion = .{},

    /// Reader thread state
    read_thread: std.Thread,
    read_thread_pipe: posix.fd_t,
    read_thread_fd: posix.fd_t,

    /// The timer to detect termios state changes.
    termios_timer: xev.Timer,
    termios_timer_c: xev.Completion = .{},
    termios_timer_running: bool = true,

    /// The last known termios mode. Used for change detection
    /// to prevent unnecessary locking of expensive mutexes.
    termios_mode: ptypkg.Mode = .{},

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        posix.close(self.read_thread_pipe);

        _ = alloc;

        // Clear our write pool. We know we aren't ever going to do
        // any more IO since we stop our data stream below so we can just
        // drop this.
        self.write_pool.deinit();

        // Stop our process watcher
        if (self.process) |*p| p.deinit();

        // Stop our write stream
        self.write_stream.deinit();

        // Stop our termios timer
        self.termios_timer.deinit();
    }
};

pub const Config = struct {
    command: ?configpkg.Command = null,
    env: EnvMap,
    env_override: configpkg.RepeatableStringMap = .{},
    shell_integration: configpkg.Config.ShellIntegration = .detect,
    shell_integration_features: configpkg.Config.ShellIntegrationFeatures = .{},
    cursor_blink: ?bool = null,
    working_directory: ?[]const u8 = null,
    resources_dir: ?[]const u8,
    term: []const u8,

    rt_pre_exec_info: Command.RtPreExecInfo,
    rt_post_fork_info: Command.RtPostForkInfo,
};

const Subprocess = struct {
    const c = @cImport({
        @cInclude("errno.h");
        @cInclude("signal.h");
        @cInclude("unistd.h");
        @cInclude("termios.h");
        @cInclude("sys/ioctl.h");
    });

    arena: std.heap.ArenaAllocator,
    cwd: ?[:0]const u8,
    env: ?EnvMap,
    args: []const [:0]const u8,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
    pty: ?Pty = null,
    process: ?Process = null,
    /// A terminal teardown has one signal/reap budget, even though threadExit
    /// and deinit both call stop. externalExit alone does not consume it.
    stopped: bool = false,

    rt_pre_exec_info: Command.RtPreExecInfo,
    rt_post_fork_info: Command.RtPostForkInfo,

    /// Union that represents the running process type.
    const Process = union(enum) {
        /// Standard POSIX fork/exec
        fork_exec: Command,

        /// Flatpak DBus command
        flatpak: FlatpakHostCommand,
    };

    const ArgsFormatter = struct {
        args: []const [:0]const u8,

        pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            for (this.args, 0..) |a, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("`{s}`", .{a});
            }
        }
    };

    /// Initialize the subprocess. This will NOT start it, this only sets
    /// up the internal state necessary to start it later.
    pub fn init(gpa: Allocator, cfg: Config) !Subprocess {
        // We have a lot of maybe-allocations that all share the same lifetime
        // so use an arena so we don't end up in an accounting nightmare.
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        // Get our env. If a default env isn't provided by the caller
        // then we get it ourselves.
        var env = cfg.env;

        // If we have a resources dir then set our env var
        if (cfg.resources_dir) |dir| {
            log.info("found Ghostty resources dir: {s}", .{dir});
            try env.put("GHOSTTY_RESOURCES_DIR", dir);
        }

        // Set our TERM var. This is a bit complicated because we want to use
        // the ghostty TERM value but we want to only do that if we have
        // ghostty in the TERMINFO database.
        //
        // For now, we just look up a bundled dir but in the future we should
        // also load the terminfo database and look for it.
        if (cfg.resources_dir) |base| {
            try env.put("TERM", cfg.term);
            try env.put("COLORTERM", "truecolor");

            // Assume that the resources directory is adjacent to the terminfo
            // database
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const dir = try std.fmt.bufPrint(&buf, "{s}/terminfo", .{
                std.fs.path.dirname(base) orelse unreachable,
            });
            try env.put("TERMINFO", dir);
        } else {
            if (comptime builtin.target.os.tag.isDarwin()) {
                log.warn("ghostty terminfo not found, using xterm-256color", .{});
                log.warn("the terminfo SHOULD exist on macos, please ensure", .{});
                log.warn("you're using a valid app bundle.", .{});
            }

            try env.put("TERM", "xterm-256color");
            try env.put("COLORTERM", "truecolor");
        }

        // Add our binary to the path if we can find it.
        ghostty_path: {
            // Skip this for flatpak since host cannot reach them
            if ((comptime build_config.flatpak) and
                internal_os.isFlatpak())
            {
                break :ghostty_path;
            }

            var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
            const exe_bin_path = std.fs.selfExePath(&exe_buf) catch |err| {
                log.warn("failed to get ghostty exe path err={}", .{err});
                break :ghostty_path;
            };
            const exe_dir = std.fs.path.dirname(exe_bin_path) orelse break :ghostty_path;
            log.debug("appending ghostty bin to path dir={s}", .{exe_dir});

            // We always set this so that if the shell overwrites the path
            // scripts still have a way to find the Ghostty binary when
            // running in Ghostty.
            try env.put("GHOSTTY_BIN_DIR", exe_dir);

            // Append if we have a path. We want to append so that ghostty is
            // the last priority in the path. If we don't have a path set
            // then we just set it to the directory of the binary.
            if (env.get("PATH")) |path| {
                // Verify that our path doesn't already contain this entry
                var it = std.mem.tokenizeScalar(u8, path, std.fs.path.delimiter);
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry, exe_dir)) break :ghostty_path;
                }

                try env.put(
                    "PATH",
                    try internal_os.appendEnv(alloc, path, exe_dir),
                );
            } else {
                try env.put("PATH", exe_dir);
            }
        }

        // On macOS, export additional data directories from our
        // application bundle.
        if (comptime builtin.target.os.tag.isDarwin()) darwin: {
            const resources_dir = cfg.resources_dir orelse break :darwin;

            var buf: [std.fs.max_path_bytes]u8 = undefined;

            const xdg_data_dir_key = "XDG_DATA_DIRS";
            if (std.fmt.bufPrint(&buf, "{s}/..", .{resources_dir})) |data_dir| {
                try env.put(
                    xdg_data_dir_key,
                    try internal_os.appendEnv(
                        alloc,
                        env.get(xdg_data_dir_key) orelse "/usr/local/share:/usr/share",
                        data_dir,
                    ),
                );
            } else |err| {
                log.warn("error building {s}; err={}", .{ xdg_data_dir_key, err });
            }

            const manpath_key = "MANPATH";
            if (std.fmt.bufPrint(&buf, "{s}/../man", .{resources_dir})) |man_dir| {
                // Always append with colon in front, as it mean that if
                // `MANPATH` is empty, then it should be treated as an extra
                // path instead of overriding all paths set by OS.
                try env.put(
                    manpath_key,
                    try internal_os.appendEnvAlways(
                        alloc,
                        env.get(manpath_key) orelse "",
                        man_dir,
                    ),
                );
            } else |err| {
                log.warn("error building {s}; man pages may not be available; err={}", .{ manpath_key, err });
            }
        }

        // Set environment variables used by some programs (such as neovim) to detect
        // which terminal emulator and version they're running under.
        try env.put("TERM_PROGRAM", "ghostty");
        try env.put("TERM_PROGRAM_VERSION", build_config.version_string);

        // VTE_VERSION is set by gnome-terminal and other VTE-based terminals.
        // We don't want our child processes to think we're running under VTE.
        // This is not apprt-specific, so we do it here.
        env.remove("VTE_VERSION");

        // Setup our shell integration, if we can.
        const shell_command: configpkg.Command = shell: {
            const default_shell_command: configpkg.Command =
                cfg.command orelse .{ .shell = switch (builtin.os.tag) {
                    .windows => "cmd.exe",
                    else => "sh",
                } };

            // Always set up shell features (GHOSTTY_SHELL_FEATURES). These are
            // used by both automatic and manual shell integrations.
            try shell_integration.setupFeatures(
                &env,
                cfg.shell_integration_features,
                cfg.cursor_blink orelse true,
            );

            const force: ?shell_integration.Shell = switch (cfg.shell_integration) {
                .none => {
                    // This is a source of confusion for users despite being
                    // opt-in since it results in some Ghostty features not
                    // working. We always want to log it.
                    log.info("shell integration disabled by configuration", .{});
                    break :shell default_shell_command;
                },

                .detect => null,
                .bash => .bash,
                .elvish => .elvish,
                .fish => .fish,
                .nushell => .nushell,
                .zsh => .zsh,
            };

            const dir = cfg.resources_dir orelse {
                log.warn("no resources dir set, shell integration disabled", .{});
                break :shell default_shell_command;
            };

            const integration = try shell_integration.setup(
                alloc,
                dir,
                default_shell_command,
                &env,
                force,
            ) orelse {
                log.warn("shell could not be detected, no automatic shell integration will be injected", .{});
                break :shell default_shell_command;
            };

            log.info(
                "shell integration automatically injected shell={}",
                .{integration.shell},
            );

            break :shell integration.command;
        };

        // Add the environment variables that override any others.
        {
            var it = cfg.env_override.iterator();
            while (it.next()) |entry| try env.put(
                entry.key_ptr.*,
                entry.value_ptr.*,
            );
        }

        // Build our args list
        const args: []const [:0]const u8 = execCommand(
            alloc,
            shell_command,
            internal_os.passwd,
        ) catch |err| switch (err) {
            // If we fail to allocate space for the command we want to
            // execute, we'd still like to try to run something so
            // Ghostty can launch (and maybe the user can debug this further).
            // Realistically, if you're getting OOM, I think other stuff is
            // about to crash, but we can try.
            error.OutOfMemory => oom: {
                log.warn("failed to allocate space for command args, falling back to basic shell", .{});

                // The comptime here is important to ensure the full slice
                // is put into the binary data and not the stack.
                break :oom comptime switch (builtin.os.tag) {
                    .windows => &.{"cmd.exe"},
                    else => &.{"/bin/sh"},
                };
            },

            // This logs on its own, this is a bad error.
            error.SystemError => return err,
        };

        // We have to copy the cwd because there is no guarantee that
        // pointers in full_config remain valid.
        const cwd: ?[:0]u8 = if (cfg.working_directory) |cwd|
            try alloc.dupeZ(u8, cwd)
        else
            null;

        // Propagate the current working directory (CWD) to the shell, enabling
        // the shell to display the current directory name rather than the
        // resolved path for symbolic links. This is important and based
        // on the same behavior in Konsole and Kitty (see the linked issues):
        // https://bugs.kde.org/show_bug.cgi?id=242114
        // https://github.com/kovidgoyal/kitty/issues/1595
        // https://github.com/ghostty-org/ghostty/discussions/7769
        if (cwd) |pwd| try env.put("PWD", pwd);

        return .{
            .arena = arena,
            .env = env,
            .cwd = cwd,
            .args = args,

            .rt_pre_exec_info = cfg.rt_pre_exec_info,
            .rt_post_fork_info = cfg.rt_post_fork_info,

            // Should be initialized with initTerminal call.
            .grid_size = .{},
            .screen_size = .{ .width = 1, .height = 1 },
        };
    }

    /// Clean up the subprocess. This will stop the subprocess if it is started.
    pub fn deinit(self: *Subprocess) void {
        self.stop();
        if (self.pty) |*pty| pty.deinit();
        if (self.env) |*env| env.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// Start the subprocess. If the subprocess is already started this
    /// will crash.
    pub fn start(self: *Subprocess, alloc: Allocator) !struct {
        read: Pty.Fd,
        write: Pty.Fd,
    } {
        assert(self.pty == null and self.process == null);
        self.stopped = false;

        // This function is funny because on POSIX systems it can
        // fail in the forked process. This is flipped to true if
        // we're in an error state in the forked process (child
        // process).
        var in_child: bool = false;

        // Create our pty
        var pty = try Pty.open(.{
            .ws_row = @intCast(self.grid_size.rows),
            .ws_col = @intCast(self.grid_size.columns),
            .ws_xpixel = @intCast(self.screen_size.width),
            .ws_ypixel = @intCast(self.screen_size.height),
        });
        self.pty = pty;
        errdefer if (!in_child) {
            if (comptime builtin.os.tag != .windows) {
                _ = posix.close(pty.slave);
            }

            pty.deinit();
            self.pty = null;
        };

        // Cleanup we only run in our parent when we successfully start
        // the process.
        defer if (!in_child and self.process != null) {
            if (comptime builtin.os.tag != .windows) {
                // Once our subcommand is started we can close the slave
                // side. This prevents the slave fd from being leaked to
                // future children.
                _ = posix.close(pty.slave);
            }

            // Successful start we can clear out some memory.
            if (self.env) |*env| {
                env.deinit();
                self.env = null;
            }
        };

        log.debug("starting command command={f}", .{ArgsFormatter{ .args = self.args }});

        // If we can't access the cwd, then don't set any cwd and inherit.
        // This is important because our cwd can be set by the shell (OSC 7)
        // and we don't want to break new windows.
        const cwd: ?[:0]const u8 = if (self.cwd) |proposed| cwd: {
            if ((comptime build_config.flatpak) and internal_os.isFlatpak()) {
                // Flatpak sandboxing prevents access to certain reserved paths
                // regardless of configured permissions. Perform a test spawn
                // to get around this problem
                //
                // https://docs.flatpak.org/en/latest/sandbox-permissions.html#reserved-paths
                log.info("flatpak detected, will use host command to verify cwd access", .{});
                const dev_null = try std.fs.cwd().openFile("/dev/null", .{ .mode = .read_write });
                defer dev_null.close();
                var cmd: internal_os.FlatpakHostCommand = .{
                    .argv = &[_][]const u8{
                        "/bin/sh",
                        "-c",
                        ":",
                    },
                    .cwd = proposed,
                    .stdin = dev_null.handle,
                    .stdout = dev_null.handle,
                    .stderr = dev_null.handle,
                };
                _ = cmd.spawn(alloc) catch |err| {
                    log.warn("cannot spawn command at cwd, ignoring: {}", .{err});
                    break :cwd null;
                };
                _ = try cmd.wait();

                break :cwd proposed;
            }

            if (std.fs.cwd().access(proposed, .{})) {
                break :cwd proposed;
            } else |err| {
                log.warn("cannot access cwd, ignoring: {}", .{err});
                break :cwd null;
            }
        } else null;

        // In flatpak, we use the HostCommand to execute our shell.
        if (internal_os.isFlatpak()) flatpak: {
            if (comptime !build_config.flatpak) {
                log.warn("flatpak detected, but flatpak support not built-in", .{});
                break :flatpak;
            }

            // Flatpak command must have a stable pointer.
            self.process = .{ .flatpak = .{
                .argv = self.args,
                .cwd = cwd,
                .env = if (self.env) |*env| env else null,
                .stdin = pty.slave,
                .stdout = pty.slave,
                .stderr = pty.slave,
            } };
            var cmd = &self.process.?.flatpak;
            const pid = try cmd.spawn(alloc);
            errdefer killCommandFlatpak(cmd);

            log.info("started subcommand on host via flatpak API path={s} pid={}", .{
                self.args[0],
                pid,
            });

            return .{
                .read = pty.master,
                .write = pty.master,
            };
        }

        // Build our subcommand
        var cmd: Command = .{
            .path = self.args[0],
            .args = self.args,
            .env = if (self.env) |*env| env else null,
            .cwd = cwd,
            .stdin = if (builtin.os.tag == .windows) null else .{ .handle = pty.slave },
            .stdout = if (builtin.os.tag == .windows) null else .{ .handle = pty.slave },
            .stderr = if (builtin.os.tag == .windows) null else .{ .handle = pty.slave },
            .pseudo_console = if (builtin.os.tag == .windows) pty.pseudo_console else {},
            .os_pre_exec = switch (comptime builtin.os.tag) {
                .windows => null,
                else => f: {
                    const f = struct {
                        fn callback(cmd: *Command) ?u8 {
                            const sp = cmd.getData(Subprocess) orelse unreachable;
                            sp.childPreExec() catch |err| log.err(
                                "error initializing child: {}",
                                .{err},
                            );
                            return null;
                        }
                    };
                    break :f f.callback;
                },
            },
            .rt_pre_exec = if (comptime @hasDecl(apprt.runtime, "pre_exec")) apprt.runtime.pre_exec.preExec else null,
            .rt_pre_exec_info = self.rt_pre_exec_info,
            .rt_post_fork = if (comptime @hasDecl(apprt.runtime, "post_fork")) apprt.runtime.post_fork.postFork else null,
            .rt_post_fork_info = self.rt_post_fork_info,
            .data = self,
        };

        cmd.start(alloc) catch |err| {
            // We have to do this because start on Windows can't
            // ever return ExecFailedInChild
            const StartError = error{ExecFailedInChild} || @TypeOf(err);
            switch (@as(StartError, err)) {
                // If we fail in our child we need to flag it so our
                // errdefers don't run.
                error.ExecFailedInChild => {
                    in_child = true;
                    return err;
                },

                else => return err,
            }
        };
        errdefer killCommand(&cmd) catch |err| {
            log.warn("error killing command during cleanup err={}", .{err});
        };
        log.info("started subcommand path={s} pid={?}", .{ self.args[0], cmd.pid });

        self.process = .{ .fork_exec = cmd };
        return switch (builtin.os.tag) {
            .windows => .{
                .read = pty.out_pipe,
                .write = pty.in_pipe,
            },

            else => .{
                .read = pty.master,
                .write = pty.master,
            },
        };
    }

    /// This should be called after fork but before exec in the child process.
    /// To repeat: this function RUNS IN THE FORKED CHILD PROCESS before
    /// exec is called; it does NOT run in the main Ghostty process.
    fn childPreExec(self: *Subprocess) !void {
        // Setup our pty
        try self.pty.?.childPreExec();
    }

    /// Called to notify that we exited externally so we can unset our
    /// running state.
    pub fn externalExit(self: *Subprocess) void {
        self.process = null;
    }

    /// Stop the subprocess. This is safe to call anytime. POSIX teardown
    /// allows the process group a bounded SIGHUP grace period, then escalates
    /// to SIGKILL and bounds that reap wait as well.
    /// This does not close the pty.
    pub fn stop(self: *Subprocess) void {
        self.stopWithTimeouts(.{});
    }

    fn stopWithTimeouts(self: *Subprocess, timeouts: KillTimeouts) void {
        self.stopWithOptions(timeouts, false);
    }

    /// Only after the IO loop has returned and the reader has joined. Capture
    /// attribution before releasing the descriptor; never close under a reader.
    fn stopClosingPty(self: *Subprocess) void {
        self.stopWithOptions(.{}, true);
    }

    fn stopWithOptions(self: *Subprocess, timeouts: KillTimeouts, close_pty: bool) void {
        if (self.stopped) return;
        self.stopped = true;
        const foreground_process_group_id = self.foregroundProcessGroupId();
        if (close_pty) {
            if (self.pty) |*pty| pty.deinit();
            self.pty = null;
        }
        if (self.process) |*process| {
            switch (process.*) {
                .fork_exec => |*cmd| {
                    if (comptime builtin.os.tag != .windows) {
                        if (close_pty) {
                            // The IO thread is joined by main during surface
                            // free. Transfer only numeric ownership to a reaper;
                            // no command, PTY, or surface storage may escape.
                            const pid = cmd.pid;
                            self.process = null;
                            if (pid) |child| (DetachedShutdown{
                                .primary_pgid = child,
                                .foreground_pgid = foreground_process_group_id,
                                .direct_child_pid = child,
                                .timeouts = timeouts,
                            }).start();
                            return;
                        }
                    }
                    // Note: this will also wait for the command to exit, so
                    // DO NOT call cmd.wait.
                    killCommandWithTimeouts(
                        cmd,
                        foreground_process_group_id,
                        timeouts,
                    ) catch |err|
                        log.err("error stopping command: {}", .{err});
                },

                .flatpak => |*cmd| if (comptime build_config.flatpak) {
                    killCommandFlatpak(cmd) catch |err|
                        log.err("error sending SIGHUP to command, may hang: {}", .{err});
                    _ = cmd.wait() catch |err|
                        log.err("error waiting for command to exit: {}", .{err});
                },
            }
        } else if (comptime builtin.os.tag != .windows) {
            // Once the watcher consumes the direct child's wait status, its
            // cached numeric process-group id may be recycled. A foreground
            // group freshly observed through this retained PTY is the only
            // group identity that remains attributable to this subprocess.
            if (foreground_process_group_id) |pgid| {
                if (close_pty) {
                    (DetachedShutdown{
                        .primary_pgid = pgid,
                        .foreground_pgid = null,
                        .direct_child_pid = null,
                        .timeouts = timeouts,
                    }).start();
                } else {
                    killProcessGroupWithTimeouts(pgid, null, timeouts) catch |err|
                        log.err("error stopping foreground process group: {}", .{err});
                }
            }
        }

        self.process = null;
    }

    fn foregroundProcessGroupId(self: *Subprocess) ?c.pid_t {
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .ios) return null;
        const pty = self.pty orelse return null;
        const pgid = c.tcgetpgrp(pty.master);
        return if (pgid > 0 and pgid != c.getpgrp()) pgid else null;
    }

    /// Resize the pty subprocess. This is safe to call anytime.
    pub fn resize(
        self: *Subprocess,
        grid_size: renderer.GridSize,
        screen_size: renderer.ScreenSize,
    ) !void {
        self.grid_size = grid_size;
        self.screen_size = screen_size;

        if (self.pty) |*pty| {
            // It is theoretically possible for the grid or screen size to
            // exceed u16, although the terminal in that case isn't very
            // usable. This should be protected upstream but we still clamp
            // in case there is a bad caller which has happened before.
            try pty.setSize(.{
                .ws_row = std.math.cast(u16, grid_size.rows) orelse std.math.maxInt(u16),
                .ws_col = std.math.cast(u16, grid_size.columns) orelse std.math.maxInt(u16),
                .ws_xpixel = std.math.cast(u16, screen_size.width) orelse std.math.maxInt(u16),
                .ws_ypixel = std.math.cast(u16, screen_size.height) orelse std.math.maxInt(u16),
            });
        }
    }

    /// Kill the underlying subprocess. POSIX process groups receive SIGHUP
    /// first and SIGKILL if they outlive the graceful shutdown budget.
    fn killCommand(command: *Command) !void {
        return killCommandWithTimeouts(command, null, .{});
    }

    fn killCommandWithTimeouts(
        command: *Command,
        foreground_process_group_id: ?c.pid_t,
        timeouts: KillTimeouts,
    ) !void {
        if (command.pid) |pid| {
            switch (builtin.os.tag) {
                .windows => {
                    if (windows.kernel32.TerminateProcess(pid, 0) == 0) {
                        return windows.unexpectedError(windows.kernel32.GetLastError());
                    }

                    _ = try command.wait(false);
                },

                else => try killProcessGroupsWithTimeouts(
                    pid,
                    foreground_process_group_id,
                    pid,
                    timeouts,
                ),
            }
        }
    }

    const KillTimeouts = struct {
        // Allow cooperative terminal children to finish graceful shutdown.
        sighup_grace: u64 = 12 * std.time.ns_per_s,
        sigterm_grace: u64 = 250 * std.time.ns_per_ms,
        sigkill_grace: u64 = 3 * std.time.ns_per_s,
        poll_interval: u64 = 10 * std.time.ns_per_ms,
    };

    /// Entire detached-worker state, copied into the new thread's allocation.
    /// No pointer here may refer to a dying surface, PTY, Command, or allocator.
    const DetachedShutdown = struct {
        primary_pgid: c.pid_t,
        foreground_pgid: ?c.pid_t,
        direct_child_pid: ?c.pid_t,
        timeouts: KillTimeouts,

        fn start(self: DetachedShutdown) void {
            const thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
                // Resource exhaustion must not abandon our waitable child or
                // silently leak its group. This exceptional fallback retains
                // the bounded synchronous cleanup, and explicitly diagnoses
                // the loss of nonblocking close behavior.
                log.err("unable to spawn child reaper; stopping synchronously: {}", .{err});
                self.run();
                return;
            };
            thread.detach();
        }

        fn run(self: DetachedShutdown) void {
            killProcessGroupsWithTimeouts(
                self.primary_pgid,
                self.foreground_pgid,
                self.direct_child_pid,
                self.timeouts,
            ) catch |err| log.err("error stopping detached process groups: {}", .{err});
        }
    };

    const KillPhase = enum { sighup, sigterm, sigkill };

    fn processIgnoresSignal(pid: c.pid_t, signal: c_int) bool {
        if (comptime !builtin.target.os.tag.isDarwin()) return false;

        var mib = [_]c_int{
            darwin_proc.c.CTL_KERN,
            darwin_proc.c.KERN_PROC,
            darwin_proc.c.KERN_PROC_PID,
            pid,
        };
        // Keep the fallback safe if the kernel returns a short record while
        // the process is exiting. The signal mask is only trustworthy when
        // the complete kinfo record was copied.
        var process = std.mem.zeroes(darwin_proc.c.struct_kinfo_proc);
        var size: usize = @sizeOf(@TypeOf(process));
        if (darwin_proc.c.sysctl(
            &mib,
            mib.len,
            &process,
            &size,
            null,
            0,
        ) != 0 or size < @sizeOf(@TypeOf(process))) return false;

        const signal_bit = @as(@TypeOf(process.kp_proc.p_sigignore), 1) <<
            @intCast(signal - 1);
        return process.kp_proc.p_sigignore & signal_bit != 0;
    }

    fn killPid(pid: c.pid_t) !void {
        return killPidWithTimeouts(pid, .{});
    }

    fn killPidWithTimeouts(pid: c.pid_t, timeouts: KillTimeouts) !void {
        return killProcessGroupWithTimeouts(pid, pid, timeouts);
    }

    fn killProcessGroupWithTimeouts(
        pgid: c.pid_t,
        direct_child_pid: ?c.pid_t,
        timeouts: KillTimeouts,
    ) !void {
        return killProcessGroupsWithTimeouts(
            pgid,
            null,
            direct_child_pid,
            timeouts,
        );
    }

    fn killProcessGroupsWithTimeouts(
        primary_pgid: c.pid_t,
        foreground_pgid: ?c.pid_t,
        direct_child_pid: ?c.pid_t,
        timeouts: KillTimeouts,
    ) !void {
        // Only a still-owned child or a group freshly attributed by our PTY
        // reaches this helper. Never signal the host's group or a special ID.
        const own_pgid = c.getpgrp();
        if (primary_pgid <= 0 or primary_pgid == own_pgid) return error.InvalidProcessGroup;
        if (foreground_pgid) |pgid| {
            if (pgid <= 0 or pgid == own_pgid) return error.InvalidProcessGroup;
        }
        if (direct_child_pid) |pid| {
            if (pid <= 0) return error.InvalidChildPid;
        }

        const distinct_foreground_pgid = if (foreground_pgid) |pgid|
            if (pgid != primary_pgid) pgid else null
        else
            null;
        const group_ids: [2]?c.pid_t = .{
            primary_pgid,
            distinct_foreground_pgid,
        };
        var group_gone: [2]bool = .{ false, distinct_foreground_pgid == null };
        var phase_signal_sent: [2]bool = .{ false, false };
        var phases: [2]KillPhase = .{ .sighup, .sighup };
        var timer = try std.time.Timer.start();
        var deadlines: [2]u64 = .{ timeouts.sighup_grace, timeouts.sighup_grace };
        var direct_child_reaped = direct_child_pid == null;
        var direct_sigkill_sent = false;
        while (true) {
            var primary_group_missing = false;
            for (group_ids, 0..) |maybe_pgid, index| {
                const pgid = maybe_pgid orelse continue;
                if (group_gone[index]) continue;

                if (!phase_signal_sent[index]) {
                    const signal = switch (phases[index]) {
                        .sighup => c.SIGHUP,
                        .sigterm => c.SIGTERM,
                        .sigkill => c.SIGKILL,
                    };
                    switch (posix.errno(c.killpg(pgid, signal))) {
                        .SUCCESS => {
                            phase_signal_sent[index] = true;
                            log.debug(
                                "process group signalled pgid={} signal={}",
                                .{ pgid, signal },
                            );

                            // macOS's login(1) deliberately ignores SIGHUP
                            // while it is still handing the terminal to the
                            // shell. Escalate only that group immediately so
                            // an early close does not consume the shell hook's
                            // normal graceful-shutdown budget.
                            if (phases[index] == .sighup and
                                processIgnoresSignal(pgid, c.SIGHUP))
                            {
                                phases[index] = .sigterm;
                                phase_signal_sent[index] = false;
                                deadlines[index] = timer.read() + timeouts.sigterm_grace;
                            }
                        },
                        .SRCH => {
                            // A just-forked direct child may not have called
                            // setsid yet. Retry its primary group until the
                            // child creates it or is reaped. The foreground
                            // group was already observed through tcgetpgrp, so
                            // once it disappears it must not be targeted again.
                            if (index == 0 and !direct_child_reaped) {
                                primary_group_missing = true;
                            } else {
                                group_gone[index] = true;
                            }
                        },
                        else => |err| killpg: {
                            if ((comptime builtin.target.os.tag.isDarwin()) and
                                err == .PERM)
                            {
                                phase_signal_sent[index] = true;
                                log.debug(
                                    "killpg failed with EPERM, expected on Darwin and ignoring",
                                    .{},
                                );
                                break :killpg;
                            }

                            log.warn(
                                "error signalling process group pgid={} err={}",
                                .{ pgid, err },
                            );
                            return error.KillFailed;
                        },
                    }
                } else switch (posix.errno(c.killpg(pgid, 0))) {
                    .SUCCESS => {},
                    .SRCH => {
                        if (index == 0 and !direct_child_reaped) {
                            primary_group_missing = true;
                        } else {
                            group_gone[index] = true;
                        }
                    },
                    .PERM => {},
                    else => |err| {
                        log.warn(
                            "error probing process group pgid={} err={}",
                            .{ pgid, err },
                        );
                        return error.KillFailed;
                    },
                }
            }

            if (!direct_child_reaped) {
                direct_child_reaped = try reapExitedChild(direct_child_pid.?);
            }
            if (direct_child_reaped and primary_group_missing) {
                group_gone[0] = true;
            }
            if (phases[0] == .sigkill and
                primary_group_missing and
                !direct_child_reaped and
                !direct_sigkill_sent)
            {
                // If teardown raced the child's pre-exec setsid, the intended
                // process group does not exist yet. The still-waitable direct
                // child is ours, so terminate it without risking pid reuse.
                switch (posix.errno(c.kill(direct_child_pid.?, c.SIGKILL))) {
                    .SUCCESS, .SRCH => direct_sigkill_sent = true,
                    else => |err| {
                        log.warn(
                            "error signalling direct child pid={} err={}",
                            .{ direct_child_pid.?, err },
                        );
                        return error.KillFailed;
                    },
                }
            }
            if (direct_child_reaped and group_gone[0] and group_gone[1]) return;

            const now = timer.read();
            for (deadlines, 0..) |deadline, index| {
                if (group_gone[index] or
                    now < deadline) continue;

                switch (phases[index]) {
                    .sighup => {
                        phases[index] = .sigkill;
                        phase_signal_sent[index] = false;
                        deadlines[index] = now + timeouts.sigkill_grace;
                        log.warn(
                            "process group exceeded SIGHUP grace; escalating " ++
                                "pgid={}",
                            .{group_ids[index].?},
                        );
                    },
                    .sigterm => {
                        phases[index] = .sigkill;
                        phase_signal_sent[index] = false;
                        deadlines[index] = now + timeouts.sigkill_grace;
                        log.warn(
                            "process group did not exit after SIGTERM; escalating " ++
                                "pgid={}",
                            .{group_ids[index].?},
                        );
                    },
                    .sigkill => {
                        log.err(
                            "process group did not reap after SIGKILL " ++
                                "primary_pgid={} foreground_pgid={?} pid={?}",
                            .{
                                primary_pgid,
                                distinct_foreground_pgid,
                                direct_child_pid,
                            },
                        );
                        return error.ProcessTerminationTimedOut;
                    },
                }
            }

            std.Thread.sleep(timeouts.poll_interval);
        }
    }

    /// Reap the direct child if it exited without racing the process watcher.
    /// Returns true when that child needs no further wait and false while it
    /// is still running. Descendant process-group liveness is tracked separately.
    fn reapExitedChild(pid: c.pid_t) !bool {
        while (true) {
            var status: c_int = 0;
            const result = posix.system.waitpid(pid, &status, std.c.W.NOHANG);
            switch (posix.errno(result)) {
                .SUCCESS => {
                    log.debug("waitpid result={}", .{result});
                    return result != 0;
                },
                .INTR => return false,

                // The process watcher won the race and already reaped it.
                .CHILD => return true,

                else => |err| {
                    log.warn("error waiting for child pid={} err={}", .{ pid, err });
                    return error.WaitFailed;
                },
            }
        }
    }

    /// Kill the underlying process started via Flatpak host command.
    /// This sends a signal via the Flatpak API.
    fn killCommandFlatpak(command: *FlatpakHostCommand) !void {
        try command.signal(c.SIGHUP, true);
    }
};

/// The read thread sits in a loop doing the following pseudo code:
///
///   while (true) { blocking_read(); exit_if_eof(); process(); }
///
/// Almost all terminal-modifying activity is from the pty read, so
/// putting this on a dedicated thread keeps performance very predictable
/// while also almost optimal. "Locking is fast, lock contention is slow."
/// and since we rarely have contention, this is fast.
///
/// This is also empirically fast compared to putting the read into
/// an async mechanism like io_uring/epoll because the reads are generally
/// small.
///
/// We use a basic poll syscall here because we are only monitoring two
/// fds and this is still much faster and lower overhead than any async
/// mechanism.
pub const ReadThread = struct {
    fn threadMainPosix(fd: posix.fd_t, io: *termio.Termio, quit: posix.fd_t) void {
        // Always close our end of the pipe when we exit.
        defer posix.close(quit);

        // Right now, on Darwin, `std.Thread.setName` can only name the current
        // thread, and we have no way to get the current thread from within it,
        // so instead we use this code to name the thread instead.
        if (builtin.os.tag.isDarwin()) {
            internal_os.macos.pthread_setname_np(&"io-reader".*);
        }

        // Setup our crash metadata
        crash.sentry.thread_state = .{
            .type = .io,
            .surface = io.surface_mailbox.surface,
        };
        defer crash.sentry.thread_state = null;

        // First thing, we want to set the fd to non-blocking. We do this
        // so that we can try to read from the fd in a tight loop and only
        // check the quit fd occasionally.
        if (posix.fcntl(fd, posix.F.GETFL, 0)) |flags| {
            _ = posix.fcntl(
                fd,
                posix.F.SETFL,
                flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
            ) catch |err| {
                log.warn("read thread failed to set flags err={}", .{err});
                log.warn("this isn't a fatal error, but may cause performance issues", .{});
            };
        } else |err| {
            log.warn("read thread failed to get flags err={}", .{err});
            log.warn("this isn't a fatal error, but may cause performance issues", .{});
        }

        // Build up the list of fds we're going to poll. We are looking
        // for data on the pty and our quit notification.
        var pollfds: [2]posix.pollfd = .{
            .{ .fd = fd, .events = posix.POLL.IN, .revents = undefined },
            .{ .fd = quit, .events = posix.POLL.IN, .revents = undefined },
        };

        var buf: [1024]u8 = undefined;
        while (true) {
            // We try to read from the file descriptor as long as possible
            // to maximize performance. We only check the quit fd if the
            // main fd blocks. This optimizes for the realistic scenario that
            // the data will eventually stop while we're trying to quit. This
            // is always true because we kill the process.
            while (true) {
                if (io.surface_mailbox.surface.stopping.load(.acquire)) return;
                const n = posix.read(fd, &buf) catch |err| {
                    switch (err) {
                        // This means our pty is closed. We're probably
                        // gracefully shutting down.
                        error.NotOpenForReading,
                        error.InputOutput,
                        => {
                            log.info("io reader exiting", .{});
                            return;
                        },

                        // No more data, fall back to poll and check for
                        // exit conditions.
                        error.WouldBlock => break,

                        else => {
                            log.err("io reader error err={}", .{err});
                            unreachable;
                        },
                    }
                };

                // This happens on macOS instead of WouldBlock when the
                // child process dies. To be safe, we just break the loop
                // and let our poll happen.
                if (n == 0) break;

                // log.info("DATA: {d}", .{n});
                @call(.always_inline, termio.Termio.processOutput, .{ io, buf[0..n] });
            }

            // Wait for data.
            _ = posix.poll(&pollfds, -1) catch |err| {
                log.warn("poll failed on read thread, exiting early err={}", .{err});
                return;
            };

            // If our quit fd is set, we're done.
            if (pollfds[1].revents & posix.POLL.IN != 0) {
                log.info("read thread got quit signal", .{});
                return;
            }

            // If our pty fd is closed, then we're also done with our
            // read thread.
            if (pollfds[0].revents & posix.POLL.HUP != 0) {
                log.info("pty fd closed, read thread exiting", .{});
                return;
            }
        }
    }

    fn threadMainWindows(fd: posix.fd_t, io: *termio.Termio, quit: posix.fd_t) void {
        // Always close our end of the pipe when we exit.
        defer posix.close(quit);

        // Setup our crash metadata
        crash.sentry.thread_state = .{
            .type = .io,
            .surface = io.surface_mailbox.surface,
        };
        defer crash.sentry.thread_state = null;

        var buf: [1024]u8 = undefined;
        while (true) {
            while (true) {
                if (io.surface_mailbox.surface.stopping.load(.acquire)) return;
                var n: windows.DWORD = 0;
                if (windows.kernel32.ReadFile(fd, &buf, buf.len, &n, null) == 0) {
                    const err = windows.kernel32.GetLastError();
                    switch (err) {
                        // Check for a quit signal
                        .OPERATION_ABORTED => break,

                        else => {
                            log.err("io reader error err={}", .{err});
                            unreachable;
                        },
                    }
                }

                @call(.always_inline, termio.Termio.processOutput, .{ io, buf[0..n] });
            }

            var quit_bytes: windows.DWORD = 0;
            if (windows.exp.kernel32.PeekNamedPipe(quit, null, 0, null, &quit_bytes, null) == 0) {
                const err = windows.kernel32.GetLastError();
                log.err("quit pipe reader error err={}", .{err});
                unreachable;
            }

            if (quit_bytes > 0) {
                log.info("read thread got quit signal", .{});
                return;
            }
        }
    }
};

test "write completion returns only its owned request and buffer" {
    const testing = std.testing;
    var td: ThreadData = undefined;
    td.write_pool = std.heap.MemoryPool(ThreadData.Write).init(testing.allocator);
    defer td.write_pool.deinit();
    const first = try td.write_pool.create();
    first.* = .{ .td = &td, .req = undefined, .buf = @splat(0x11) };
    const second = try td.write_pool.create();
    second.* = .{ .td = &td, .req = undefined, .buf = @splat(0x22) };
    const third = try td.write_pool.create();
    third.* = .{ .td = &td, .req = undefined, .buf = @splat(0x33) };

    // Complete the middle request first, then reuse the returned storage.
    // Calling the production completion is essential: FIFO pool release used
    // to free another request's still-pending buffer here.
    _ = ttyWrite(second, undefined, undefined, undefined, undefined, 64);
    const replacement = try td.write_pool.create();
    replacement.* = .{ .td = &td, .req = undefined, .buf = @splat(0x44) };
    try testing.expect(replacement != first and replacement != third);
    try testing.expectEqualSlices(u8, &@as([64]u8, @splat(0x11)), &first.buf);
    try testing.expectEqualSlices(u8, &@as([64]u8, @splat(0x33)), &third.buf);
    _ = ttyWrite(third, undefined, undefined, undefined, undefined, 64);
    _ = ttyWrite(first, undefined, undefined, undefined, undefined, 64);
    _ = ttyWrite(replacement, undefined, undefined, undefined, undefined, 64);
}

/// Real child fixtures for the production shutdown path. Each child has a
/// five-second SIGALRM watchdog, a bounded readiness handshake, and cleanup.
/// Run only in the remote test environment, never against operator processes.
const ShutdownFixture = struct {
    const Mode = enum { graceful, ignores_hup, ignores_both, before_setsid };
    pid: posix.pid_t,
    events: posix.fd_t,
    var signal_fd: posix.fd_t = undefined;

    fn setSignal(sig: u8, handler: ?posix.Sigaction.handler_fn) void {
        var action: posix.Sigaction = .{
            .handler = .{ .handler = handler },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(sig, &action, null);
    }

    fn signalled(sig: c_int) callconv(.c) void {
        const byte: [1]u8 = .{if (sig == Subprocess.c.SIGHUP) 'h' else 't'};
        _ = posix.system.write(signal_fd, &byte, 1);
        Subprocess.c._exit(0);
    }

    fn start(mode: Mode) !ShutdownFixture {
        const c = Subprocess.c;
        const pipe = try internal_os.pipe();
        errdefer posix.close(pipe[0]);
        const pid = posix.fork() catch |err| {
            posix.close(pipe[1]);
            return err;
        };
        if (pid == 0) {
            ShutdownFixture.setSignal(posix.SIG.ALRM, posix.SIG.DFL);
            _ = c.alarm(5);
            posix.close(pipe[0]);
            signal_fd = pipe[1];
            if (mode != .before_setsid and c.setsid() < 0) c._exit(1);
            setSignal(posix.SIG.HUP, if (mode == .graceful) signalled else posix.SIG.IGN);
            setSignal(posix.SIG.TERM, if (mode == .ignores_hup) signalled else posix.SIG.IGN);
            if (posix.system.write(pipe[1], "r", 1) != 1) c._exit(1);
            while (true) _ = c.pause();
        }
        posix.close(pipe[1]);
        errdefer cleanup(pid);
        var polls = [_]posix.pollfd{.{ .fd = pipe[0], .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&polls, 1000) != 1) return error.ChildReadinessTimedOut;
        var byte: [1]u8 = undefined;
        if (try posix.read(pipe[0], &byte) != 1 or byte[0] != 'r') return error.ChildNotReady;
        return .{ .pid = pid, .events = pipe[0] };
    }

    fn cleanup(pid: posix.pid_t) void {
        // Probe ownership before sending any signal, including during failure
        // cleanup. A successful shutdown may already have reaped this PID.
        var status: c_int = 0;
        const result = posix.system.waitpid(pid, &status, std.c.W.NOHANG);
        if (result == 0) {
            _ = Subprocess.c.kill(pid, Subprocess.c.SIGKILL);
            _ = posix.system.waitpid(pid, &status, 0);
        }
    }

    fn deinit(self: ShutdownFixture) void {
        cleanup(self.pid);
        posix.close(self.events);
    }

    fn expectReaped(self: ShutdownFixture) !void {
        var status: c_int = 0;
        const result = posix.system.waitpid(self.pid, &status, std.c.W.NOHANG);
        try std.testing.expectEqual(@as(posix.pid_t, -1), result);
        try std.testing.expectEqual(posix.E.CHILD, posix.errno(result));
    }
};

test "subprocess shutdown allows cooperative HUP handler and reaps" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .ios) return error.SkipZigTest;
    const fixture = try ShutdownFixture.start(.graceful);
    defer fixture.deinit();
    try Subprocess.killPidWithTimeouts(fixture.pid, .{
        .sighup_grace = 500 * std.time.ns_per_ms,
        .sigkill_grace = 500 * std.time.ns_per_ms,
    });
    var event: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try posix.read(fixture.events, &event));
    try std.testing.expectEqual(@as(u8, 'h'), event[0]);
    try fixture.expectReaped();
}

test "subprocess shutdown actually sends TERM to Darwin HUP-ignoring leader" {
    if (comptime !builtin.os.tag.isDarwin() or builtin.os.tag == .ios) return error.SkipZigTest;
    const fixture = try ShutdownFixture.start(.ignores_hup);
    defer fixture.deinit();
    var timer = try std.time.Timer.start();
    try Subprocess.killPidWithTimeouts(fixture.pid, .{
        .sighup_grace = 2 * std.time.ns_per_s,
        .sigterm_grace = 250 * std.time.ns_per_ms,
        .sigkill_grace = 500 * std.time.ns_per_ms,
    });
    try std.testing.expect(timer.read() < std.time.ns_per_s);
    var event: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try posix.read(fixture.events, &event));
    try std.testing.expectEqual(@as(u8, 't'), event[0]);
    try fixture.expectReaped();
}

test "subprocess shutdown bounds ignored signals and pre-setsid child" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .ios) return error.SkipZigTest;
    for ([_]ShutdownFixture.Mode{ .ignores_both, .before_setsid }) |mode| {
        const fixture = try ShutdownFixture.start(mode);
        defer fixture.deinit();
        var timer = try std.time.Timer.start();
        try Subprocess.killPidWithTimeouts(fixture.pid, .{
            .sighup_grace = 50 * std.time.ns_per_ms,
            .sigterm_grace = 50 * std.time.ns_per_ms,
            .sigkill_grace = 500 * std.time.ns_per_ms,
        });
        try std.testing.expect(timer.read() < std.time.ns_per_s);
        try fixture.expectReaped();
    }
}

test "cancelled subprocess close returns before grace and detached worker reaps" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .ios) return error.SkipZigTest;
    const testing = std.testing;
    const c = Subprocess.c;
    for ([_]ShutdownFixture.Mode{ .ignores_hup, .ignores_both }) |mode| {
        const fixture = try ShutdownFixture.start(mode);
        defer fixture.deinit();
        var command: Command = undefined;
        command.pid = fixture.pid;
        var subprocess: Subprocess = undefined;
        subprocess.stopped = false;
        subprocess.pty = null;
        subprocess.process = .{ .fork_exec = command };

        var timer = try std.time.Timer.start();
        subprocess.stopWithOptions(.{
            .sighup_grace = 750 * std.time.ns_per_ms,
            .sigterm_grace = 750 * std.time.ns_per_ms,
            .sigkill_grace = 750 * std.time.ns_per_ms,
        }, true);
        const return_ns = timer.read();
        const ownership_cleared = subprocess.stopped and
            subprocess.process == null and subprocess.pty == null;
        // Model destruction immediately after the IO join. The reaper must
        // not retain even a read-only pointer to either of these owners.
        subprocess = undefined;
        command = undefined;

        // Do not waitpid here: consuming the status would hide a reaper bug.
        // Signal zero also observes zombies, so disappearance means the worker
        // reaped the child. Wait before assertions/fixture cleanup to avoid
        // racing the detached worker on a failure path.
        var disappeared = false;
        while (timer.read() < 3 * std.time.ns_per_s) {
            const result = c.kill(fixture.pid, 0);
            if (result < 0 and posix.errno(result) == .SRCH) {
                disappeared = true;
                break;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        try testing.expect(ownership_cleared);
        try testing.expect(return_ns < 250 * std.time.ns_per_ms);
        try testing.expect(disappeared);
        try fixture.expectReaped();
    }
}

test "subprocess shutdown rejects host group and special process IDs" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .ios) return error.SkipZigTest;
    for ([_]Subprocess.c.pid_t{ 0, -1, Subprocess.c.getpgrp() }) |pgid| {
        try std.testing.expectError(error.InvalidProcessGroup, Subprocess.killProcessGroupWithTimeouts(pgid, null, .{}));
    }
}

test "subprocess external exit discards a stale command identity" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .ios) return error.SkipZigTest;
    const sentinel = try ShutdownFixture.start(.ignores_both);
    defer sentinel.deinit();
    var cmd: Command = undefined;
    cmd.pid = sentinel.pid;
    var subprocess: Subprocess = undefined;
    subprocess.stopped = false;
    subprocess.pty = null;
    subprocess.process = .{ .fork_exec = cmd };
    subprocess.externalExit();
    subprocess.stopWithTimeouts(.{
        .sighup_grace = 20 * std.time.ns_per_ms,
        .sigkill_grace = 100 * std.time.ns_per_ms,
    });
    var status: c_int = 0;
    try std.testing.expectEqual(@as(posix.pid_t, 0), posix.system.waitpid(sentinel.pid, &status, std.c.W.NOHANG));
}

test "subprocess stop kills a distinct foreground process group" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .ios) {
        return error.SkipZigTest;
    }

    const testing = std.testing;
    const c = Subprocess.c;
    const detached = try ShutdownFixture.start(.ignores_both);
    defer detached.deinit();
    var pty = try Pty.open(.{});
    defer pty.deinit();
    var slave_open = true;
    defer if (slave_open) posix.close(pty.slave);

    const ready_pipe = try internal_os.pipe();
    const job_ready_pipe = try internal_os.pipe();
    defer {
        _ = posix.system.close(ready_pipe[0]);
        _ = posix.system.close(ready_pipe[1]);
        _ = posix.system.close(job_ready_pipe[0]);
        _ = posix.system.close(job_ready_pipe[1]);
    }

    const leader_pid: posix.pid_t = leader: {
        const rc = posix.system.fork();
        switch (posix.errno(rc)) {
            .SUCCESS => break :leader @intCast(rc),
            .AGAIN, .NOMEM => return error.SystemResources,
            else => |err| return posix.unexpectedErrno(err),
        }
    };
    if (leader_pid == 0) {
        ShutdownFixture.setSignal(posix.SIG.ALRM, posix.SIG.DFL);
        _ = c.alarm(5);
        _ = posix.system.close(pty.master);
        _ = posix.system.close(ready_pipe[0]);
        if (c.setsid() < 0) c._exit(1);
        const tiocsctty = if (builtin.os.tag == .macos) 536900705 else c.TIOCSCTTY;
        if (c.ioctl(pty.slave, tiocsctty, @as(c_ulong, 0)) < 0) c._exit(1);

        const job_pid = posix.system.fork();
        switch (posix.errno(job_pid)) {
            .SUCCESS => {},
            else => c._exit(1),
        }
        if (job_pid == 0) {
            ShutdownFixture.setSignal(posix.SIG.ALRM, posix.SIG.DFL);
            _ = c.alarm(5);
            _ = posix.system.close(ready_pipe[1]);
            _ = posix.system.close(job_ready_pipe[0]);
            if (c.setpgid(0, 0) < 0) c._exit(1);

            var action: posix.Sigaction = .{
                .handler = .{ .handler = posix.SIG.IGN },
                .mask = posix.sigemptyset(),
                .flags = 0,
            };
            posix.sigaction(posix.SIG.HUP, &action, null);
            if (posix.system.write(job_ready_pipe[1], "j", 1) != 1) c._exit(1);
            while (true) _ = c.pause();
        }

        _ = posix.system.close(job_ready_pipe[1]);
        var job_ready: [1]u8 = undefined;
        if (posix.system.read(job_ready_pipe[0], &job_ready, 1) != 1) c._exit(1);
        if (c.tcsetpgrp(pty.slave, @intCast(job_pid)) < 0) c._exit(1);
        if (posix.system.write(ready_pipe[1], "r", 1) != 1) c._exit(1);
        while (true) _ = c.pause();
    }

    var leader_reaped = false;
    var foreground_pgid: ?c.pid_t = null;
    defer {
        if (foreground_pgid) |pgid| {
            if (pgid > 0 and pgid != c.getpgrp() and c.tcgetpgrp(pty.master) == pgid) {
                _ = c.killpg(pgid, c.SIGKILL);
            }
        }
        if (!leader_reaped) {
            ShutdownFixture.cleanup(leader_pid);
        }
    }

    _ = posix.system.close(ready_pipe[1]);
    var polls = [_]posix.pollfd{.{ .fd = ready_pipe[0], .events = posix.POLL.IN, .revents = 0 }};
    try testing.expectEqual(@as(usize, 1), try posix.poll(&polls, 1000));
    var ready: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), try posix.read(ready_pipe[0], &ready));
    posix.close(pty.slave);
    slave_open = false;

    foreground_pgid = c.tcgetpgrp(pty.master);
    try testing.expect(foreground_pgid.? > 0);
    try testing.expect(foreground_pgid.? != leader_pid);

    var command: Command = undefined;
    command.pid = leader_pid;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var subprocess: Subprocess = .{
        .arena = arena,
        .cwd = null,
        .env = null,
        .args = &.{},
        .grid_size = .{},
        .screen_size = .{ .width = 1, .height = 1 },
        .pty = pty,
        .process = .{ .fork_exec = command },
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    subprocess.stopWithTimeouts(.{
        .sighup_grace = 20 * std.time.ns_per_ms,
        .sigkill_grace = std.time.ns_per_s,
    });

    var leader_status: c_int = 0;
    const leader_wait = posix.system.waitpid(leader_pid, &leader_status, std.c.W.NOHANG);
    leader_reaped = leader_wait < 0 and posix.errno(leader_wait) == .CHILD;
    try testing.expect(leader_reaped);

    var detached_status: c_int = 0;
    try testing.expectEqual(@as(posix.pid_t, 0), posix.system.waitpid(detached.pid, &detached_status, std.c.W.NOHANG));

    const foreground_probe = c.killpg(foreground_pgid.?, 0);
    const foreground_probe_err = posix.errno(foreground_probe);
    try testing.expectEqual(@as(c_int, -1), foreground_probe);
    try testing.expectEqual(posix.E.SRCH, foreground_probe_err);
}

/// Builds the argv array for the process we should exec for the
/// configured command. This isn't as straightforward as it seems since
/// we deal with shell-wrapping, macOS login shells, etc.
///
/// The passwdpkg comptime argument is expected to have a single function
/// `get(Allocator)` that returns a passwd entry. This is used by macOS
/// to determine the username and home directory for the login shell.
/// It is unused on other platforms.
///
/// Memory ownership:
///
/// The allocator should be an arena, since the returned value may or
/// may not be allocated and args may or may not be allocated (or copied).
/// Pointers in the return value may point to pointers in the command
/// struct.
fn execCommand(
    alloc: Allocator,
    command: configpkg.Command,
    comptime passwdpkg: type,
) (Allocator.Error || error{SystemError})![]const [:0]const u8 {
    // If we're on macOS, we have to use `login(1)` to get all of
    // the proper environment variables set, a login shell, and proper
    // hushlogin behavior.
    if (comptime builtin.target.os.tag.isDarwin()) darwin: {
        const passwd = passwdpkg.get(alloc) catch |err| {
            log.warn("failed to read passwd, not using a login shell err={}", .{err});
            break :darwin;
        };

        const username = passwd.name orelse {
            log.warn("failed to get username, not using a login shell", .{});
            break :darwin;
        };

        const hush = if (passwd.home) |home| hush: {
            var dir = std.fs.openDirAbsolute(home, .{}) catch |err| {
                log.warn(
                    "failed to open home dir, not checking for hushlogin err={}",
                    .{err},
                );
                break :hush false;
            };
            defer dir.close();

            break :hush if (dir.access(".hushlogin", .{})) true else |_| false;
        } else false;

        // If we made it this far we're going to start building
        // the actual command.
        var args: std.ArrayList([:0]const u8) = try .initCapacity(
            alloc,

            // This capacity is chosen based on what we'd need to
            // execute a shell command (very common). We can/will
            // grow if necessary for a longer command (uncommon).
            9,
        );
        defer args.deinit(alloc);

        // The reason for executing login this way is unclear. This
        // comment will attempt to explain but prepare for a truly
        // unhinged reality.
        //
        // The first major issue is that on macOS, a lot of users
        // put shell configurations in ~/.bash_profile instead of
        // ~/.bashrc (or equivalent for another shell). This file is only
        // loaded for a login shell so macOS users expect all their terminals
        // to be login shells. No other platform behaves this way and its
        // totally braindead but somehow the entire dev community on
        // macOS has cargo culted their way to this reality so we have to
        // do it...
        //
        // To get a login shell, you COULD just prepend argv0 with a `-`
        // but that doesn't fully work because `getlogin()` C API will
        // return the wrong value, SHELL won't be set, and various
        // other login behaviors that macOS users expect.
        //
        // The proper way is to use `login(1)`. But login(1) forces
        // the working directory to change to the home directory,
        // which we may not want. If we specify "-l" then we can avoid
        // this behavior but now the shell isn't a login shell.
        //
        // There is another issue: `login(1)` on macOS 14.3 and earlier
        // checked for ".hushlogin" in the working directory. This means
        // that if we specify "-l" then we won't get hushlogin honored
        // if its in the home directory (which is standard). To get
        // around this, we check for hushlogin ourselves and if present
        // specify the "-q" flag to login(1).
        //
        // So to get all the behaviors we want, we specify "-l" but
        // execute "bash" (which is built-in to macOS). We then use
        // the bash builtin "exec" to replace the process with a login
        // shell ("-l" on exec) with the command we really want.
        //
        // We use "bash" instead of other shells that ship with macOS
        // because as of macOS Sonoma, we found with a microbenchmark
        // that bash can `exec` into the desired command ~2x faster
        // than zsh.
        //
        // To figure out a lot of this logic I read the login.c
        // source code in the OSS distribution Apple provides for
        // macOS.
        //
        // Awesome.
        try args.append(alloc, "/usr/bin/login");
        if (hush) try args.append(alloc, "-q");
        try args.append(alloc, "-flp");
        try args.append(alloc, username);

        switch (command) {
            // Direct args can be passed directly to login, since
            // login uses execvp we don't need to worry about PATH
            // searching.
            .direct => |v| try args.appendSlice(alloc, v),

            .shell => |v| {
                // Use "exec" to replace the bash process with
                // our intended command so we don't have a parent
                // process hanging around.
                const cmd = try std.fmt.allocPrintSentinel(
                    alloc,
                    "exec -l {s}",
                    .{v},
                    0,
                );

                // We execute bash with "--noprofile --norc" so that it doesn't
                // load startup files so that (1) our shell integration doesn't
                // break and (2) user configuration doesn't mess this process
                // up.
                try args.append(alloc, "/bin/bash");
                try args.append(alloc, "--noprofile");
                try args.append(alloc, "--norc");
                try args.append(alloc, "-c");
                try args.append(alloc, cmd);
            },
        }

        return try args.toOwnedSlice(alloc);
    }

    return switch (command) {
        // We need to clone the command since there's no guarantee the config remains valid.
        .direct => |_| (try command.clone(alloc)).direct,

        .shell => |v| shell: {
            var args: std.ArrayList([:0]const u8) = try .initCapacity(alloc, 4);
            defer args.deinit(alloc);

            if (comptime builtin.os.tag == .windows) {
                // We run our shell wrapped in `cmd.exe` so that we don't have
                // to parse the command line ourselves if it has arguments.

                // Note we don't free any of the memory below since it is
                // allocated in the arena.
                const windir = std.process.getEnvVarOwned(
                    alloc,
                    "WINDIR",
                ) catch |err| {
                    log.warn("failed to get WINDIR, cannot run shell command err={}", .{err});
                    return error.SystemError;
                };
                const cmd = try std.fs.path.joinZ(alloc, &[_][]const u8{
                    windir,
                    "System32",
                    "cmd.exe",
                });

                try args.append(alloc, cmd);
                try args.append(alloc, "/C");
            } else {
                // We run our shell wrapped in `/bin/sh` so that we don't have
                // to parse the command line ourselves if it has arguments.
                // Additionally, some environments (NixOS, I found) use /bin/sh
                // to setup some environment variables that are important to
                // have set.
                try args.append(alloc, "/bin/sh");
                if (internal_os.isFlatpak()) try args.append(alloc, "-l");
                try args.append(alloc, "-c");
            }

            try args.append(alloc, v);
            break :shell try args.toOwnedSlice(alloc);
        },
    };
}

test "execCommand darwin: shell command" {
    if (comptime !builtin.os.tag.isDarwin()) return error.SkipZigTest;

    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try execCommand(alloc, .{ .shell = "foo bar baz" }, struct {
        fn get(_: Allocator) !PasswdEntry {
            return .{
                .name = "testuser",
            };
        }
    });

    try testing.expectEqual(8, result.len);
    try testing.expectEqualStrings(result[0], "/usr/bin/login");
    try testing.expectEqualStrings(result[1], "-flp");
    try testing.expectEqualStrings(result[2], "testuser");
    try testing.expectEqualStrings(result[3], "/bin/bash");
    try testing.expectEqualStrings(result[4], "--noprofile");
    try testing.expectEqualStrings(result[5], "--norc");
    try testing.expectEqualStrings(result[6], "-c");
    try testing.expectEqualStrings(result[7], "exec -l foo bar baz");
}

test "execCommand darwin: direct command" {
    if (comptime !builtin.os.tag.isDarwin()) return error.SkipZigTest;

    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try execCommand(alloc, .{ .direct = &.{
        "foo",
        "bar baz",
    } }, struct {
        fn get(_: Allocator) !PasswdEntry {
            return .{
                .name = "testuser",
            };
        }
    });

    try testing.expectEqual(5, result.len);
    try testing.expectEqualStrings(result[0], "/usr/bin/login");
    try testing.expectEqualStrings(result[1], "-flp");
    try testing.expectEqualStrings(result[2], "testuser");
    try testing.expectEqualStrings(result[3], "foo");
    try testing.expectEqualStrings(result[4], "bar baz");
}

test "execCommand: shell command, empty passwd" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try execCommand(
        alloc,
        .{ .shell = "foo bar baz" },
        struct {
            fn get(_: Allocator) !PasswdEntry {
                // Empty passwd entry means we can't construct a macOS
                // login command and falls back to POSIX behavior.
                return .{};
            }
        },
    );

    try testing.expectEqual(3, result.len);
    try testing.expectEqualStrings(result[0], "/bin/sh");
    try testing.expectEqualStrings(result[1], "-c");
    try testing.expectEqualStrings(result[2], "foo bar baz");
}

test "execCommand: shell command, error passwd" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try execCommand(
        alloc,
        .{ .shell = "foo bar baz" },
        struct {
            fn get(_: Allocator) !PasswdEntry {
                // Failed passwd entry means we can't construct a macOS
                // login command and falls back to POSIX behavior.
                return error.Fail;
            }
        },
    );

    try testing.expectEqual(3, result.len);
    try testing.expectEqualStrings(result[0], "/bin/sh");
    try testing.expectEqualStrings(result[1], "-c");
    try testing.expectEqualStrings(result[2], "foo bar baz");
}

test "execCommand: direct command, error passwd" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try execCommand(alloc, .{
        .direct = &.{
            "foo",
            "bar baz",
        },
    }, struct {
        fn get(_: Allocator) !PasswdEntry {
            // Failed passwd entry means we can't construct a macOS
            // login command and falls back to POSIX behavior.
            return error.Fail;
        }
    });

    try testing.expectEqual(2, result.len);
    try testing.expectEqualStrings(result[0], "foo");
    try testing.expectEqualStrings(result[1], "bar baz");
}

test "execCommand: direct command, config freed" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var command_arena = ArenaAllocator.init(testing.allocator);
    const command_alloc = command_arena.allocator();
    const command = try (configpkg.Command{
        .direct = &.{
            "foo",
            "bar baz",
        },
    }).clone(command_alloc);

    const result = try execCommand(alloc, command, struct {
        fn get(_: Allocator) !PasswdEntry {
            // Failed passwd entry means we can't construct a macOS
            // login command and falls back to POSIX behavior.
            return error.Fail;
        }
    });

    command_arena.deinit();

    try testing.expectEqual(2, result.len);
    try testing.expectEqualStrings(result[0], "foo");
    try testing.expectEqualStrings(result[1], "bar baz");
}
