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
        if (b.graph.environ_map.get("VCPKG_ROOT")) |root| {
            const include_path = b.pathJoin(&.{ root, "installed", "x64-windows", "include" });
            const lib_path = b.pathJoin(&.{ root, "installed", "x64-windows", "lib" });
            exe.root_module.addIncludePath(.{ .cwd_relative = include_path });
            exe.root_module.addLibraryPath(.{ .cwd_relative = lib_path });
        }
    }

    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("sqlite3", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
