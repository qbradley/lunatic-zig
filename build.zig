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

    const bincode_zig = b.dependency("bincode-zig", .{
        .target = target,
        .optimize = optimize,
    });

    b.addModule(.{
        .name = "lunatic-zig",
        .source_file = .{ .path = "src/lunatic.zig" },
        .dependencies = &.{
            .{ .name = "bincode-zig", .module = bincode_zig.module("bincode-zig") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "lunatic-test",
        .root_source_file = .{ .path = "test/main.zig" },
        .target = target,
        .optimize = optimize,
        .linkage = .dynamic,
    });
    exe.export_symbol_names = &.{
        "child1",
        "child2",
    };
    exe.addModule("lunatic-zig", b.modules.get("lunatic-zig").?);
    exe.addModule("bincode-zig", bincode_zig.module("bincode-zig"));
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
}
