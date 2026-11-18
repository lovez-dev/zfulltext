const std = @import("std");
const zft = @import("zfulltext");
const zlap = @import("zlap");

const queries = [_][]const u8{ "common", "frequent rare", "中文", "needle phrase", "frequent common" };

const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    index: *zft.Index,
    query_index: usize = 0,
};

var active: ?*Context = null;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out");
    var path: ["out/bench-".len + 24]u8 = undefined;
    while (true) {
        var random: [12]u8 = undefined;
        io.random(&random);
        path = "out/bench-".* ++ std.fmt.bytesToHex(random, .lower);
        cwd.createDir(io, &path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        break;
    }
    const index = zft.Index.open(allocator, io, &path, .{ .create_if_missing = true }) catch |err| {
        cwd.deleteTree(io, &path) catch {};
        return err;
    };
    defer {
        index.deinit();
        cwd.deleteTree(io, &path) catch {};
    }

    // Setup is deliberately outside the timed workload. Documents have a
    // repeatable mix of common and rare English terms plus Han text.
    for (0..256) |i| {
        const text = try std.fmt.allocPrint(allocator, "common frequent common document {d} {s} 中文检索", .{
            i,
            if (i % 32 == 0) "needle phrase" else if (i % 7 == 0) "rare" else "ordinary",
        });
        defer allocator.free(text);
        try index.upsert(i, text);
    }

    var context: Context = .{ .io = io, .allocator = allocator, .index = index };
    active = &context;
    defer active = null;

    const config: zlap.Config = .{
        .warmup_batches = 1,
        .batch_size = 20,
        .batch_repeats = 1,
        .sample_count = 10,
        .min_sample_ns = 0,
        .rounds = 1,
        .allocator = allocator,
    };

    const analyzer = try zlap.runConfigured(io, config, analyzerWorkload);
    analyzer.print("analysis.analyzeQuery (mixed English/Han)");
    const codec = try zlap.runConfigured(io, config, codecWorkload);
    codec.print("document codec round-trip (mixed English/Han)");
    const search = try zlap.runConfigured(io, config, searchWorkload);
    search.print("Index.search (prebuilt 256-document corpus, mixed-frequency query cycle)");

    try index.close();
}

fn analyzerWorkload(allocator: std.mem.Allocator, operations: usize) !void {
    for (0..operations) |i| try analyzeOne(allocator, queries[i % queries.len]);
}

fn analyzeOne(allocator: std.mem.Allocator, input: []const u8) !void {
    var tokens = try zft.analysis.analyzeQuery(allocator, input);
    defer tokens.deinit();
    std.mem.doNotOptimizeAway(tokens.logical_length);
    for (tokens.items) |token| std.mem.doNotOptimizeAway(token.term);
}

fn codecWorkload(allocator: std.mem.Allocator, operations: usize) !void {
    for (0..operations) |i| try codecOne(allocator, queries[i % queries.len]);
}

fn codecOne(allocator: std.mem.Allocator, input: []const u8) !void {
    var analyzed = try zft.analysis.analyzeDocument(allocator, input);
    defer analyzed.deinit();
    const encoded = try zft.codec.encodeDocument(allocator, input, analyzed.items, analyzed.logical_length);
    defer allocator.free(encoded);
    var decoded = try zft.codec.decodeDocument(allocator, encoded, 16 * 1024);
    defer decoded.deinit();
    std.mem.doNotOptimizeAway(decoded.logical_length);
    for (decoded.tokens) |token| std.mem.doNotOptimizeAway(token.term);
}

fn searchWorkload(allocator: std.mem.Allocator, operations: usize) !void {
    const context = active orelse return error.MissingBenchmarkContext;
    for (0..operations) |_| try searchOne(context, allocator);
}

fn searchOne(context: *Context, allocator: std.mem.Allocator) !void {
    const query = queries[context.query_index % queries.len];
    context.query_index +%= 1;
    var result = try context.index.search(allocator, query, .{ .mode = .all, .limit = 10 });
    defer result.deinit(allocator);
    for (result.hits) |hit| {
        std.mem.doNotOptimizeAway(hit.id);
        std.mem.doNotOptimizeAway(hit.score);
    }
    std.mem.doNotOptimizeAway(result.total);
}
