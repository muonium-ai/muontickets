const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseSafe)") orelse .ReleaseSafe;

    const exe = b.addExecutable(.{
        .name = "mt-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    if (target.result.os.tag == .windows) {
        const vcpkg_root = std.process.getEnvVarOwned(b.allocator, "VCPKG_ROOT") catch null;
        if (vcpkg_root) |root| {
            const include_path = std.fs.path.join(b.allocator, &[_][]const u8{ root, "installed", "x64-windows", "include" }) catch unreachable;
            const lib_path = std.fs.path.join(b.allocator, &[_][]const u8{ root, "installed", "x64-windows", "lib" }) catch unreachable;
            exe.addIncludePath(.{ .cwd_relative = include_path });
            exe.addLibraryPath(.{ .cwd_relative = lib_path });
        }
    }

    exe.linkLibC();
    exe.linkSystemLibrary("sqlite3");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
