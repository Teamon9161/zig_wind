const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wind_module = b.createModule(.{
        .root_source_file = b.path("src/wind.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wind_module.addIncludePath(b.path("src"));
    wind_module.addCSourceFile(.{ .file = b.path("src/wind_com_helpers.c") });
    wind_module.linkSystemLibrary("ole32", .{});
    wind_module.linkSystemLibrary("oleaut32", .{});

    const wsd_example = b.addExecutable(.{
        .name = "wind-wsd",
        .root_module = exampleModule(b, target, optimize, "examples/wsd.zig", wind_module),
    });
    const wsq_example = b.addExecutable(.{
        .name = "wind-wsq",
        .root_module = exampleModule(b, target, optimize, "examples/wsq.zig", wind_module),
    });
    b.installArtifact(wsd_example);
    b.installArtifact(wsq_example);

    const unit_tests = b.addTest(.{ .root_module = wind_module });
    unit_tests.root_module.linkSystemLibrary("ole32", .{});
    unit_tests.root_module.linkSystemLibrary("oleaut32", .{});
    const run_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const run_wsd_step = b.step("run-wsd", "Build and run the WSD example");
    const run_wsd = b.addRunArtifact(wsd_example);
    run_wsd.step.dependOn(b.getInstallStep());
    run_wsd_step.dependOn(&run_wsd.step);

    const run_wsq_step = b.step("run-wsq", "Build and run the WSQ subscription example");
    const run_wsq = b.addRunArtifact(wsq_example);
    run_wsq.step.dependOn(b.getInstallStep());
    run_wsq_step.dependOn(&run_wsq.step);
}

fn exampleModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    source_path: []const u8,
    wind_module: *std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(source_path),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("zig_wind", wind_module);
    module.addIncludePath(b.path("src"));
    module.linkSystemLibrary("ole32", .{});
    module.linkSystemLibrary("oleaut32", .{});
    return module;
}
