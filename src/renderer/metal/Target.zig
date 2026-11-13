//! Represents a render target.
//!
//! In this case, an IOSurface-backed MTLTexture.
const Self = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const macos = @import("macos");
const graphics = macos.graphics;
const IOSurface = macos.iosurface.IOSurface;

const mtl = @import("api.zig");

const log = std.log.scoped(.metal);

/// Options for initializing a Target
pub const Options = struct {
    /// MTLDevice
    device: objc.Object,

    /// Desired width
    width: usize,
    /// Desired height
    height: usize,

    /// Pixel format for the MTLTexture
    pixel_format: mtl.MTLPixelFormat,
    /// Storage mode for the MTLTexture
    storage_mode: mtl.MTLResourceOptions.StorageMode,
};

/// The underlying IOSurface.
surface: *IOSurface,

/// The underlying MTLTexture.
texture: objc.Object,

/// When set, `deinit` releases the surface without discarding its pixels.
/// `Metal.keepPresentedContents` sets it on the target whose surface Metal
/// keeps for `presentLastTarget`, so a hidden surface whose swap chain was
/// released still shows its last frame when it is shown again.
keep_contents: bool = false,

/// Current width of this target.
width: usize,
/// Current height of this target.
height: usize,

pub fn init(opts: Options) !Self {
    // We set our surface's color space to Display P3.
    // This allows us to have "Apple-style" alpha blending,
    // since it seems to be the case that Apple apps like
    // Terminal and TextEdit render text in the display's
    // color space using converted colors, which reduces,
    // but does not fully eliminate blending artifacts.
    const colorspace = try graphics.ColorSpace.createNamed(.displayP3);
    defer colorspace.release();

    const surface = try IOSurface.init(.{
        .width = @intCast(opts.width),
        .height = @intCast(opts.height),
        .pixel_format = .@"32BGRA",
        .bytes_per_element = 4,
        .colorspace = colorspace,
    });
    // Free the surface if the texture can't be made. A hidden surface
    // rebuilds its targets on every show, so a leak here would repeat.
    errdefer surface.deinit();

    // Create our descriptor
    const desc = init: {
        const Class = objc.getClass("MTLTextureDescriptor").?;
        const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
        const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
        break :init id_init;
    };
    defer desc.release();

    // Set our properties
    desc.setProperty("width", @as(c_ulong, @intCast(opts.width)));
    desc.setProperty("height", @as(c_ulong, @intCast(opts.height)));
    desc.setProperty("pixelFormat", @intFromEnum(opts.pixel_format));
    desc.setProperty("usage", mtl.MTLTextureUsage{ .render_target = true });
    desc.setProperty(
        "resourceOptions",
        mtl.MTLResourceOptions{
            // Indicate that the CPU writes to this resource but never reads it.
            .cpu_cache_mode = .write_combined,
            .storage_mode = opts.storage_mode,
        },
    );

    const id = (if (builtin.is_test and test_seam.fail_texture) fail: {
        // Hold the surface so the test can check it was freed.
        surface.retain();
        test_seam.surface = surface;
        break :fail null;
    } else opts.device.msgSend(
        ?*anyopaque,
        objc.sel("newTextureWithDescriptor:iosurface:plane:"),
        .{
            desc,
            surface,
            @as(c_ulong, 0),
        },
    )) orelse return error.MetalFailed;

    const texture = objc.Object.fromId(id);

    return .{
        .surface = surface,
        .texture = texture,
        .width = opts.width,
        .height = opts.height,
    };
}

pub fn deinit(self: *Self) void {
    // `IOSurface.deinit` marks the surface purgeable-empty, which discards
    // its pixels for every other owner too (the layer, `last_surface`).
    if (self.keep_contents) self.surface.release() else self.surface.deinit();
    self.texture.release();
}

/// A hidden terminal's kept frame stays in memory, off the footprint:
/// volatile purgeable memory is not charged to the process, and macOS
/// discards it only under memory pressure.
pub fn keepFrameVolatile(surface: *IOSurface) bool {
    if (surface.setPurgeable(macos.iosurface.c.kIOSurfacePurgeableVolatile) == null) {
        log.warn("could not mark the kept frame volatile; it stays on the footprint", .{});
        return false;
    }
    return true;
}

/// Make a kept frame non-volatile again before it is shown. Returns false
/// when macOS discarded it while it was volatile: its pixels are gone.
pub fn restoreKeptFrame(surface: *IOSurface) bool {
    const c = macos.iosurface.c;
    // A failed call leaves the state as it was; keep the frame.
    const old = surface.setPurgeable(c.kIOSurfacePurgeableNonVolatile) orelse return true;
    return old != c.kIOSurfacePurgeableEmpty;
}

/// Test seam: make the texture allocation fail as if Metal returned nil.
const test_seam = struct {
    var fail_texture: bool = false;
    var surface: ?*IOSurface = null;
};

fn testDevice() !objc.Object {
    // The test binary doesn't link Metal; load it here.
    var lib = std.DynLib.open("/System/Library/Frameworks/Metal.framework/Metal") catch
        return error.SkipZigTest;
    defer lib.close();
    const create = lib.lookup(*const fn () callconv(.c) ?*anyopaque, "MTLCreateSystemDefaultDevice") orelse
        return error.SkipZigTest;
    const id = create() orelse return error.SkipZigTest;
    return objc.Object.fromId(id);
}

fn testTarget(device: objc.Object) !Self {
    return Self.init(.{
        .device = device,
        .width = 64,
        .height = 64,
        .pixel_format = .bgra8unorm,
        .storage_mode = .shared,
    });
}

/// The surface's purgeable state, read without changing it.
fn purgeState(surface: *IOSurface) u32 {
    const c = macos.iosurface.c;
    var old: u32 = 0;
    _ = c.IOSurfaceSetPurgeable(@ptrCast(surface), c.kIOSurfacePurgeableKeepCurrent, &old);
    return old;
}

fn fillSurface(surface: *IOSurface, byte: u8) void {
    const c = macos.iosurface.c;
    _ = c.IOSurfaceLock(@ptrCast(surface), 0, null);
    defer _ = c.IOSurfaceUnlock(@ptrCast(surface), 0, null);
    const base: [*]u8 = @ptrCast(c.IOSurfaceGetBaseAddress(@ptrCast(surface)));
    @memset(base[0..c.IOSurfaceGetAllocSize(@ptrCast(surface))], byte);
}

fn surfaceAll(surface: *IOSurface, byte: u8) bool {
    const c = macos.iosurface.c;
    _ = c.IOSurfaceLock(@ptrCast(surface), c.kIOSurfaceLockReadOnly, null);
    defer _ = c.IOSurfaceUnlock(@ptrCast(surface), c.kIOSurfaceLockReadOnly, null);
    const base: [*]const u8 = @ptrCast(c.IOSurfaceGetBaseAddress(@ptrCast(surface)));
    for (base[0..c.IOSurfaceGetAllocSize(@ptrCast(surface))]) |b| if (b != byte) return false;
    return true;
}

test "a kept target's surface keeps its pixels after the target is freed" {
    const c = macos.iosurface.c;
    const device = try testDevice();
    defer device.release();

    // The presented frame: another owner (Metal.last_surface) holds it.
    var kept = try testTarget(device);
    const surface = kept.surface;
    fillSurface(surface, 0xA5);
    surface.retain();
    defer surface.release();
    kept.keep_contents = true;
    kept.deinit();
    try std.testing.expectEqual(@as(u32, c.kIOSurfacePurgeableNonVolatile), purgeState(surface));
    try std.testing.expect(surfaceAll(surface, 0xA5));

    // Any other target is still discarded at once.
    var dropped = try testTarget(device);
    const other = dropped.surface;
    other.retain();
    defer other.release();
    dropped.deinit();
    try std.testing.expectEqual(@as(u32, c.kIOSurfacePurgeableEmpty), purgeState(other));
}

test "a kept frame is volatile while hidden and non-volatile with its pixels when shown" {
    const c = macos.iosurface.c;
    const device = try testDevice();
    defer device.release();

    var target = try testTarget(device);
    const surface = target.surface;
    fillSurface(surface, 0x5A);
    surface.retain();
    defer surface.release();
    target.keep_contents = true;
    target.deinit();

    try std.testing.expect(keepFrameVolatile(surface));
    try std.testing.expectEqual(@as(u32, c.kIOSurfacePurgeableVolatile), purgeState(surface));
    try std.testing.expect(restoreKeptFrame(surface));
    try std.testing.expectEqual(@as(u32, c.kIOSurfacePurgeableNonVolatile), purgeState(surface));
    try std.testing.expect(surfaceAll(surface, 0x5A));
}

test "a kept frame discarded while hidden reports it on show" {
    const c = macos.iosurface.c;
    const device = try testDevice();
    defer device.release();

    var target = try testTarget(device);
    const surface = target.surface;
    surface.retain();
    defer surface.release();
    target.keep_contents = true;
    target.deinit();

    try std.testing.expect(keepFrameVolatile(surface));
    // Stand-in for macOS discarding it under memory pressure.
    _ = surface.setPurgeable(c.kIOSurfacePurgeableEmpty);
    try std.testing.expect(!restoreKeptFrame(surface));
}

test "a target whose texture can't be made frees its surface" {
    const c = macos.iosurface.c;
    const device = try testDevice();
    defer device.release();

    test_seam.fail_texture = true;
    defer test_seam.fail_texture = false;
    try std.testing.expectError(error.MetalFailed, testTarget(device));
    const surface = test_seam.surface.?;
    test_seam.surface = null;
    defer surface.release();
    // Only `IOSurface.deinit` marks a surface empty: the failed init freed it.
    try std.testing.expectEqual(@as(u32, c.kIOSurfacePurgeableEmpty), purgeState(surface));
}
