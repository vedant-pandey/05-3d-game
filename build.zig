const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "_05_3d_game",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.linkLibC();
    exe.linkLibCpp();

    exe.addIncludePath(b.path("vendor/volk"));
    exe.addIncludePath(b.path("vendor/vma"));

    exe.addCSourceFile(.{
        .file = b.path("vendor/volk/volk.c"),
        .flags = &[_][]const u8{"-std=c99"},
    });

    exe.addCSourceFile(.{
        .file = b.path("vendor/vma/vma_impl.cpp"),
        .flags = &[_][]const u8{"-std=c++17"},
    });

    exe.linkSystemLibrary("vulkan");

    const sdl3 = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("sdl3", sdl3.module("sdl3"));

    const zmath = b.dependency("zmath", .{});
    exe.root_module.addImport("zmath", zmath.module("root"));

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
