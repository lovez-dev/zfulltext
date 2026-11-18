const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const wiskdb = b.dependency("wiskdb", .{ .target = target, .optimize = optimize });
    const zfulltext = b.addModule("zfulltext", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zfulltext.addImport("wiskdb", wiskdb.module("wiskdb"));

    const tests_module = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_module.addImport("zfulltext", zfulltext);
    tests_module.addImport("wiskdb", wiskdb.module("wiskdb"));
    const tests = b.addTest(.{ .root_module = tests_module });
    const run_tests = b.addRunArtifact(tests);
    const analysis_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/analysis.zig"), .target = target, .optimize = optimize }) });
    const codec_module = b.createModule(.{ .root_source_file = b.path("src/codec.zig"), .target = target, .optimize = optimize });
    const codec_tests = b.addTest(.{ .root_module = codec_module });
    const scoring_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/scoring.zig"), .target = target, .optimize = optimize }) });
    const types_module = b.createModule(.{ .root_source_file = b.path("src/types.zig"), .target = target, .optimize = optimize });
    types_module.addImport("wiskdb", wiskdb.module("wiskdb"));
    const types_tests = b.addTest(.{ .root_module = types_module });
    const analysis_run = b.addRunArtifact(analysis_tests);
    const codec_run = b.addRunArtifact(codec_tests);
    const scoring_run = b.addRunArtifact(scoring_tests);
    const types_run = b.addRunArtifact(types_tests);
    const test_step = b.step("test", "Run unit and public API tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&analysis_run.step);
    test_step.dependOn(&codec_run.step);
    test_step.dependOn(&scoring_run.step);
    test_step.dependOn(&types_run.step);
    const check_step = b.step("check", "Compile the library and all tests");
    check_step.dependOn(&tests.step);
    check_step.dependOn(&analysis_tests.step);
    check_step.dependOn(&codec_tests.step);
    check_step.dependOn(&scoring_tests.step);
    check_step.dependOn(&types_tests.step);

    if (b.isRoot()) try addBenchmark(b, zfulltext, target, optimize);

    const example_module = b.createModule(.{
        .root_source_file = b.path("examples/basic.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_module.addImport("zfulltext", zfulltext);
    const example = b.addExecutable(.{ .name = "zfulltext-basic", .root_module = example_module });
    const run_example = b.addRunArtifact(example);
    b.step("example", "Run the basic full-text search example").dependOn(&run_example.step);
}

fn addBenchmark(b: *std.Build, zfulltext: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) !void {
    const step = b.step("bench", "Run benchmarks (requires -Dbench=true)");
    const enabled = b.option(bool, "bench", "Enable benchmark tooling (zig build bench -Dbench=true)") orelse false;
    if (!enabled) {
        step.dependOn(&b.addFail("Benchmark tooling is disabled; run zig build bench -Dbench=true").step);
        return;
    }
    const zlap = try b.dependencyLazy("zlap", .{ .target = target, .optimize = optimize });
    const bench_module = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_module.addImport("zfulltext", zfulltext);
    bench_module.addImport("zlap", zlap.module("zlap"));
    const bench = b.addExecutable(.{ .name = "zfulltext-bench", .root_module = bench_module });
    step.dependOn(&b.addRunArtifact(bench).step);
}
