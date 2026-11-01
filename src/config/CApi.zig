const std = @import("std");
const inputpkg = @import("../input.zig");
const state = &@import("../global.zig").state;
const c = @import("../main_c.zig");

const Config = @import("Config.zig");
const c_get = @import("c_get.zig");
const edit = @import("edit.zig");
const Key = @import("key.zig").Key;

const log = std.log.scoped(.config);

/// Create a new configuration filled with the initial default values.
export fn ghostty_config_new() ?*Config {
    const result = state.alloc.create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = Config.default(state.alloc) catch |err| {
        log.err("error creating config err={}", .{err});
        state.alloc.destroy(result);
        return null;
    };

    return result;
}

export fn ghostty_config_free(ptr: ?*Config) void {
    if (ptr) |v| {
        v.deinit();
        state.alloc.destroy(v);
    }
}

/// Deep clone the configuration.
export fn ghostty_config_clone(self: *Config) ?*Config {
    const result = state.alloc.create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = self.clone(state.alloc) catch |err| {
        log.err("error cloning config err={}", .{err});
        state.alloc.destroy(result);
        return null;
    };

    return result;
}

/// Load the configuration from the CLI args.
export fn ghostty_config_load_cli_args(self: *Config) void {
    self.loadCliArgs(state.alloc) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from the default file locations. This
/// is usually done first. The default file locations are locations
/// such as the home directory.
export fn ghostty_config_load_default_files(self: *Config) void {
    self.loadDefaultFiles(state.alloc) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from a specific file path.
/// The path must be null-terminated.
export fn ghostty_config_load_file(self: *Config, path: [*:0]const u8) void {
    const path_slice = std.mem.span(path);
    self.loadFile(state.alloc, path_slice) catch |err| {
        log.err("error loading config from file path={s} err={}", .{ path_slice, err });
    };
}

/// Load the configuration from the user-specified configuration
/// file locations in the previously loaded configuration. This will
/// recursively continue to load up to a built-in limit.
export fn ghostty_config_load_recursive_files(self: *Config) void {
    self.loadRecursiveFiles(state.alloc) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

export fn ghostty_config_finalize(self: *Config) void {
    self.finalize() catch |err| {
        log.err("error finalizing config err={}", .{err});
    };
}

export fn ghostty_config_get(
    self: *Config,
    ptr: *anyopaque,
    key_str: [*]const u8,
    len: usize,
) bool {
    @setEvalBranchQuota(10_000);
    const key = std.meta.stringToEnum(Key, key_str[0..len]) orelse return false;
    return c_get.get(self, key, ptr);
}

/// Sync with ghostty_config_command_kind_e. This visitor only reads loaded
/// config values; it never resolves a shell, captures process env, or logs data.
const CommandKind = enum(c_int) { none = 0, shell = 1, direct = 2 };
const CommandCallback = *const fn (?*anyopaque, CommandKind, usize, usize, [*]const u8, usize) callconv(.c) void;
const EnvCallback = *const fn (?*anyopaque, [*]const u8, usize, [*]const u8, usize) callconv(.c) void;

export fn ghostty_config_visit_launch(
    self: *const Config,
    initial: bool,
    command_callback: ?CommandCallback,
    env_callback: ?EnvCallback,
    userdata: ?*anyopaque,
) bool {
    const visit_command = command_callback orelse return false;
    const visit_env = env_callback orelse return false;
    const command = if (initial) self.@"initial-command" orelse self.command else self.command;
    if (command) |cmd| {
        switch (cmd) {
            .shell => |text| visit_command(userdata, .shell, 0, 1, text.ptr, text.len),
            .direct => |args| {
                if (args.len == 0) visit_command(userdata, .direct, 0, 0, "", 0);
                for (args, 0..) |arg, index| {
                    visit_command(userdata, .direct, index, args.len, arg.ptr, arg.len);
                }
            },
        }
    } else visit_command(userdata, .none, 0, 0, "", 0);
    var it = self.env.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        visit_env(userdata, key.ptr, key.len, value.ptr, value.len);
    }
    return true;
}

/// Fixed launch-field allowlist, with borrowed slices and no process reads.
export fn ghostty_config_visit_launch_fields(
    self: ?*const Config,
    callback: ?EnvCallback,
    userdata: ?*anyopaque,
) bool {
    const cfg = self orelse return false;
    const visit_field = callback orelse return false;
    if (cfg.@"working-directory") |value| {
        const name = "working-directory";
        visit_field(userdata, name, name.len, value.ptr, value.len);
    }
    const name = "term";
    visit_field(userdata, name, name.len, cfg.term.ptr, cfg.term.len);
    return true;
}

test "launch fields visitor preserves exact borrowed strings and fixed allowlist" {
    const testing = std.testing;
    const Capture = struct {
        const Entry = struct {
            key: [64]u8 = undefined,
            key_len: usize = 0,
            value: [64]u8 = undefined,
            value_len: usize = 0,
        };
        entries: [4]Entry = undefined,
        len: usize = 0,
        fn field(raw: ?*anyopaque, key: [*]const u8, key_len: usize, value: [*]const u8, value_len: usize) callconv(.c) void {
            const capture: *@This() = @ptrCast(@alignCast(raw.?));
            capture.entries[capture.len] = .{ .key_len = key_len, .value_len = value_len };
            @memcpy(capture.entries[capture.len].key[0..key_len], key[0..key_len]);
            @memcpy(capture.entries[capture.len].value[0..value_len], value[0..value_len]);
            capture.len += 1;
        }
    };
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    // These slices deliberately need no NUL terminator.
    const cwd = [_]u8{ '/', 'a', ' ', 0xc3, 0xa9 };
    const term = [_]u8{ 'v', 't', '1', '0', '0' };
    cfg.@"working-directory" = &cwd;
    cfg.term = &term;
    try cfg.env.parseCLI(cfg._arena.?.allocator(), "UNRELATED=not visited");
    var capture: Capture = .{};
    try testing.expect(!ghostty_config_visit_launch_fields(null, Capture.field, &capture));
    try testing.expect(!ghostty_config_visit_launch_fields(&cfg, null, &capture));
    try testing.expectEqual(@as(usize, 0), capture.len);
    try testing.expect(ghostty_config_visit_launch_fields(&cfg, Capture.field, &capture));
    try testing.expectEqual(@as(usize, 2), capture.len);
    try testing.expectEqualStrings("working-directory", capture.entries[0].key[0..capture.entries[0].key_len]);
    try testing.expectEqualStrings(&cwd, capture.entries[0].value[0..capture.entries[0].value_len]);
    try testing.expectEqualStrings("term", capture.entries[1].key[0..capture.entries[1].key_len]);
    try testing.expectEqualStrings(&term, capture.entries[1].value[0..capture.entries[1].value_len]);
    try testing.expectEqualStrings(&cwd, cfg.@"working-directory".?);
    try testing.expectEqualStrings(&term, cfg.term);
    try testing.expectEqualStrings("not visited", cfg.env.map.get("UNRELATED").?);
    cfg.@"working-directory" = null;
    capture = .{};
    try testing.expect(ghostty_config_visit_launch_fields(&cfg, Capture.field, &capture));
    try testing.expectEqual(@as(usize, 1), capture.len);
    try testing.expectEqualStrings("term", capture.entries[0].key[0..capture.entries[0].key_len]);
    cfg.@"working-directory" = "";
    cfg.term = "";
    capture = .{};
    try testing.expect(ghostty_config_visit_launch_fields(&cfg, Capture.field, &capture));
    try testing.expectEqual(@as(usize, 2), capture.len);
    try testing.expectEqual(@as(usize, 0), capture.entries[0].value_len);
    try testing.expectEqual(@as(usize, 0), capture.entries[1].value_len);
}

export fn ghostty_config_trigger(
    self: *Config,
    str: [*]const u8,
    len: usize,
) inputpkg.Binding.Trigger.C {
    return config_trigger_(self, str[0..len]) catch |err| err: {
        log.err("error finding trigger err={}", .{err});
        break :err .{};
    };
}

fn config_trigger_(
    self: *Config,
    str: []const u8,
) !inputpkg.Binding.Trigger.C {
    const action = try inputpkg.Binding.Action.parse(str);
    const trigger: inputpkg.Binding.Trigger = self.keybind.set.getTrigger(action) orelse .{};
    return trigger.cval();
}

export fn ghostty_config_diagnostics_count(self: *Config) u32 {
    return @intCast(self._diagnostics.items().len);
}

export fn ghostty_config_get_diagnostic(self: *Config, idx: u32) Diagnostic {
    const items = self._diagnostics.items();
    if (idx >= items.len) return .{};
    const message = self._diagnostics.precompute.messages.items[idx];
    return .{ .message = message.ptr };
}

export fn ghostty_config_open_path() c.String {
    const path = edit.openPath(state.alloc) catch |err| {
        log.err("error opening config in editor err={}", .{err});
        return .empty;
    };

    return .fromSlice(path);
}

/// Sync with ghostty_diagnostic_s
const Diagnostic = extern struct {
    message: [*:0]const u8 = "",
};

test "ghostty_config_get: bool" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.maximize = true;

    var out = false;
    const key = "maximize";
    try testing.expect(ghostty_config_get(&cfg, &out, key, key.len));
    try testing.expect(out);
}

test "ghostty_config_get: enum" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"window-theme" = .dark;

    var out: [*:0]const u8 = undefined;
    const key = "window-theme";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    const str = std.mem.sliceTo(out, 0);
    try testing.expectEqualStrings("dark", str);
}

test "ghostty_config_get: optional null returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"unfocused-split-fill" = null;

    var out: Config.Color.C = undefined;
    const key = "unfocused-split-fill";
    try testing.expect(!ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
}

test "ghostty_config_get: unknown key returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var out = false;
    const key = "not-a-real-key";
    try testing.expect(!ghostty_config_get(&cfg, &out, key, key.len));
}

test "ghostty_config_get: optional string null returns true" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.title = null;

    var out: ?[*:0]const u8 = undefined;
    const key = "title";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    try testing.expect(out == null);
}

test "ghostty_config_get: float" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"background-opacity" = 0.42;

    var out: f64 = 0;
    const key = "background-opacity";
    try testing.expect(ghostty_config_get(&cfg, &out, key, key.len));
    try testing.expectApproxEqAbs(@as(f64, 0.42), out, 0.000001);
}

test "ghostty_config_get: struct cval conversion" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.background = .{ .r = 12, .g = 34, .b = 56 };

    var out: Config.Color.C = undefined;
    const key = "background";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    try testing.expectEqual(@as(u8, 12), out.r);
    try testing.expectEqual(@as(u8, 34), out.g);
    try testing.expectEqual(@as(u8, 56), out.b);
}

test "launch config visitor preserves command selection and explicit env without mutation" {
    const testing = std.testing;
    const Capture = struct {
        const Entry = struct {
            kind: CommandKind = .none,
            index: usize = 0,
            count: usize = 0,
            key: [64]u8 = undefined,
            key_len: usize = 0,
            value: [64]u8 = undefined,
            value_len: usize = 0,
        };
        entries: [8]Entry = undefined,
        len: usize = 0,
        fn command(raw: ?*anyopaque, kind: CommandKind, index: usize, count: usize, ptr: [*]const u8, len: usize) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.entries[self.len] = .{ .kind = kind, .index = index, .count = count, .value_len = len };
            @memcpy(self.entries[self.len].value[0..len], ptr[0..len]);
            self.len += 1;
        }
        fn env(raw: ?*anyopaque, key: [*]const u8, key_len: usize, value: [*]const u8, value_len: usize) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.entries[self.len] = .{ .key_len = key_len, .value_len = value_len };
            @memcpy(self.entries[self.len].key[0..key_len], key[0..key_len]);
            @memcpy(self.entries[self.len].value[0..value_len], value[0..value_len]);
            self.len += 1;
        }
    };
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    var capture: Capture = .{};
    try testing.expect(!ghostty_config_visit_launch(&cfg, false, null, Capture.env, &capture));
    try testing.expect(!ghostty_config_visit_launch(&cfg, false, Capture.command, null, &capture));
    try testing.expectEqual(@as(usize, 0), capture.len);
    try testing.expect(ghostty_config_visit_launch(&cfg, false, Capture.command, Capture.env, &capture));
    try testing.expectEqual(@as(usize, 1), capture.len);
    try testing.expectEqual(CommandKind.none, capture.entries[0].kind);
    try testing.expectEqual(@as(usize, 0), capture.entries[0].count);

    const alloc = cfg._arena.?.allocator();
    cfg.command = .{ .shell = "printf '%s' \"$VALUE\"" };
    const args = [_][:0]const u8{ "/bin/example", "one argument", "", "hé" };
    cfg.@"initial-command" = .{ .direct = &args };
    try cfg.env.parseCLI(alloc, "EXPLICIT=old");
    try cfg.env.parseCLI(alloc, "EXPLICIT=exact value");
    try cfg.env.parseCLI(alloc, "REMOVED=value");
    try cfg.env.parseCLI(alloc, "REMOVED=");
    capture = .{};
    try testing.expect(ghostty_config_visit_launch(&cfg, true, Capture.command, Capture.env, &capture));
    try testing.expectEqual(@as(usize, 5), capture.len);
    for (args, 0..) |arg, i| {
        const entry = capture.entries[i];
        try testing.expectEqual(CommandKind.direct, entry.kind);
        try testing.expectEqual(i, entry.index);
        try testing.expectEqual(args.len, entry.count);
        try testing.expectEqualStrings(arg, entry.value[0..entry.value_len]);
    }
    const env = capture.entries[4];
    try testing.expectEqualStrings("EXPLICIT", env.key[0..env.key_len]);
    try testing.expectEqualStrings("exact value", env.value[0..env.value_len]);

    for ([_]bool{ false, true }) |initial| {
        if (initial) cfg.@"initial-command" = null;
        capture = .{};
        try testing.expect(ghostty_config_visit_launch(&cfg, initial, Capture.command, Capture.env, &capture));
        try testing.expectEqual(@as(usize, 2), capture.len);
        try testing.expectEqual(CommandKind.shell, capture.entries[0].kind);
        try testing.expectEqualStrings(cfg.command.?.shell, capture.entries[0].value[0..capture.entries[0].value_len]);
    }
    try testing.expectEqualStrings("exact value", cfg.env.map.get("EXPLICIT").?);
    try testing.expectEqual(@as(usize, 1), cfg.env.count());
    cfg.command = .{ .direct = &.{} };
    capture = .{};
    try testing.expect(ghostty_config_visit_launch(&cfg, false, Capture.command, Capture.env, &capture));
    try testing.expectEqual(CommandKind.direct, capture.entries[0].kind);
    try testing.expectEqual(@as(usize, 0), capture.entries[0].count);
}
