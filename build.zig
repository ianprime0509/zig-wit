const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_wit = b.addExecutable(.{
        .name = "translate-wit",
        .root_source_file = .{ .path = "src/translate_wit.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(translate_wit);

    const run_translate_wit = b.addRunArtifact(translate_wit);
    if (b.args) |args| {
        run_translate_wit.addArgs(args);
    }
    b.step("translate-wit", "Run translate-wit").dependOn(&run_translate_wit.step);
}
