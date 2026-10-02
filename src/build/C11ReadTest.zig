const std = @import("std");
const SharedDeps = @import("SharedDeps.zig");
const LibtoolStep = @import("LibtoolStep.zig");

pub fn add(b: *std.Build, deps: *const SharedDeps) !void {
    const lib = b.addLibrary(.{
        .name = "ghostty-c11-read-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c11_read_test.zig"),
            .target = deps.config.target,
            .optimize = .Debug,
        }),
        .use_llvm = true,
    });
    lib.bundle_compiler_rt = true;
    lib.bundle_ubsan_rt = true;
    lib.addIncludePath(b.path("include"));
    var libs = try deps.add(lib);
    try libs.append(b.allocator, lib.getEmittedBin());
    const archive = LibtoolStep.create(b, .{
        .name = "c11-read-test",
        .out_name = "libghostty-c11-read-test.a",
        .sources = libs.items,
    });
    const install_archive = b.addInstallLibFile(archive.output, "libghostty-c11-read-test.a");
    const library_step = b.step("c11-test-library", "Install the test-only Ghostty fixture library");
    library_step.dependOn(&install_archive.step);

    // Use the native SDK/clang for the small AppKit host. This fixture is
    // deliberately native-only, just like its real NSView/Metal surface.
    const compile = b.addSystemCommand(&.{ "xcrun", "clang", "-std=c11", "-fobjc-arc", "-g" });
    compile.addArg("-I");
    compile.addDirectoryArg(b.path("include"));
    compile.addFileArg(b.path("tests/ghostty_patchset/try_read_host.m"));
    compile.addFileArg(b.path("tests/ghostty_patchset/try_read_abi.c"));
    compile.addFileArg(archive.output);
    compile.addArgs(&.{
        "-lc++",        "-framework", "Cocoa",      "-framework", "Metal",
        "-framework",   "QuartzCore", "-framework", "CoreText",   "-framework",
        "CoreGraphics", "-framework", "IOSurface",  "-framework", "Carbon",
        "-framework",   "IOKit",      "-framework", "CoreVideo",  "-o",
    });
    const executable = compile.addOutputFileArg("c11-try-read-test");
    const build_step = b.step("build-c11-read-test", "Build the isolated native try-read ABI fixture");
    build_step.dependOn(&compile.step);
    const run = b.addSystemCommand(&.{"env"});
    run.addFileArg(executable);
    const test_step = b.step("test-c11-read", "Run the native try-read ABI fixture (unlocked macOS GUI required)");
    test_step.dependOn(&run.step);
}
