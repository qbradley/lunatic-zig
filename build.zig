const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
        },
    });

    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSmall,
    });

    const exe = b.addExecutable(.{
        .name = "lunatic-test",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
        .linkage = .dynamic,
    });
    exe.export_symbol_names = &.{
        "child1",
        "child2",
    };
    exe.install();

    const run_cmd = b.addSystemCommand(&.{
        "lunatic",
        "run",
        exe.out_filename,
    });
    run_cmd.cwd = std.fmt.allocPrint(b.allocator, "{s}/bin", .{b.install_path}) catch unreachable;
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app with lunatic");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing.
    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
