const std = @import("std");
const zft = @import("zfulltext");
const t = std.testing;
const TempIndex = @import("index.zig").TempIndex;

fn expectMatches(index: *zft.Index, text: []const u8, options: zft.SearchOptions, total: usize, ids: []const u64) !void {
    var result = try index.search(t.allocator, text, options);
    defer result.deinit(t.allocator);
    try t.expectEqual(total, result.total);
    try t.expectEqual(ids.len, result.hits.len);
    for (ids, result.hits) |id, hit| try t.expectEqual(id, hit.id);
}

test "Index.search matches all, any, repeated phrases and mixed positions" {
    const tmp = try TempIndex.init();
    defer tmp.deinit();
    const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{ .create_if_missing = true });
    defer index.deinit();
    try index.upsert(1, "Go go 中文 hello");
    try index.upsert(2, "Go 中文 go hello");
    try index.upsert(3, "Go hi hello");
    try index.upsert(4, "中文中文");
    try index.upsert(5, "中 文");

    // Equal IDFs for go and hello. The shorter document outranks the longer
    // ones here even though those contain go twice.
    try expectMatches(index, "GO hello", .{}, 3, &.{ 3, 1, 2 });
    try expectMatches(index, "missing hi", .{}, 0, &.{});
    try expectMatches(index, "missing hi", .{ .mode = .any }, 1, &.{3});
    try expectMatches(index, "中文 hi", .{ .mode = .any }, 4, &.{ 3, 4, 1, 2 });
    try expectMatches(index, "go GO 中文 hello", .{ .mode = .phrase }, 1, &.{1});
    try expectMatches(index, "go go", .{ .mode = .phrase }, 1, &.{1});
    try expectMatches(index, "中文中文", .{ .mode = .phrase }, 1, &.{4});
    try expectMatches(index, "中文", .{}, 3, &.{ 4, 1, 2 });
    try expectMatches(index, "中", .{ .limit = 0 }, 4, &.{});
    try expectMatches(index, "中文 go", .{ .mode = .phrase }, 1, &.{2});
    try expectMatches(index, " -- 。 \n", .{ .mode = .phrase }, 0, &.{});

    try index.upsert(1, "replacement hello");
    try expectMatches(index, "go go", .{ .mode = .phrase }, 0, &.{});
    try expectMatches(index, "中文", .{}, 2, &.{ 4, 2 });
    try t.expect(try index.delete(2));
    try expectMatches(index, "go", .{}, 1, &.{3});
}

test "Index.search computes live BM25 once per distinct term and retains bounded ordered hits" {
    const tmp = try TempIndex.init();
    defer tmp.deinit();
    const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{ .create_if_missing = true });
    defer index.deinit();
    const max_id = std.math.maxInt(u64);
    try index.upsert(max_id, "term");
    try index.upsert(71, "term");
    try index.upsert(20, "term");
    try index.upsert(90, "term term");
    try index.upsert(8, "other");
    try expectMatches(index, "term", .{ .limit = 2 }, 4, &.{ 90, 20 });
    try expectMatches(index, "term", .{}, 4, &.{ 90, 20, 71, max_id });
    try expectMatches(index, "term", .{ .limit = 0 }, 4, &.{});

    var result = try index.search(t.allocator, "term term", .{ .limit = 1 });
    defer result.deinit(t.allocator);
    const expected = @log(1.0 + 1.5 / 4.5) * (2.0 * 2.2) / (2.0 + 1.2 * (0.25 + 0.75 * 2.0 / 1.2));
    try t.expectEqual(@as(u64, 90), result.hits[0].id);
    try t.expectApproxEqAbs(expected, result.hits[0].score, 1e-12);

    try t.expect(try index.delete(8));
    var live = try index.search(t.allocator, "term", .{ .limit = 1 });
    defer live.deinit(t.allocator);
    const expected_live = @log(1.0 + 0.5 / 4.5) * (2.0 * 2.2) / (2.0 + 1.2 * (0.25 + 0.75 * 2.0 / 1.25));
    try t.expectApproxEqAbs(expected_live, live.hits[0].score, 1e-12);
}

test "Index.search keeps BM25 finite at the largest k1" {
    const tmp = try TempIndex.init();
    defer tmp.deinit();
    const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{ .create_if_missing = true });
    defer index.deinit();
    try index.upsert(1, "term term");
    var result = try index.search(t.allocator, "term", .{ .k1 = std.math.floatMax(f64), .b = 0 });
    defer result.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), result.total);
    try t.expectEqual(@as(usize, 1), result.hits.len);
    try t.expectEqual(@as(u64, 1), result.hits[0].id);
    try t.expect(std.math.isFinite(result.hits[0].score));
    try t.expectApproxEqAbs(2 * @log(1.0 + 0.5 / 1.5), result.hits[0].score, 1e-15);
}

test "Index.search validates query options, observes cancellation and cleans caller allocations" {
    const tmp = try TempIndex.init();
    defer tmp.deinit();
    const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{
        .create_if_missing = true,
        .max_document_bytes = 16,
        .max_query_bytes = 16,
        .max_result_count = 4,
    });
    defer index.deinit();
    try index.upsert(1, "中国 good good");
    try index.upsert(2, "good 中国");
    try t.expectError(error.QueryTooLarge, index.search(t.allocator, "xxxxxxxxxxxxxxxxx", .{ .limit = 1 }));
    try t.expectError(error.InvalidUtf8, index.search(t.allocator, "\xff", .{ .limit = 1 }));
    try t.expectError(error.InvalidLimit, index.search(t.allocator, "good", .{ .limit = 5 }));
    try t.expectError(error.InvalidParameters, index.search(t.allocator, "good", .{ .limit = 1, .k1 = std.math.nan(f64) }));
    try t.expectError(error.InvalidParameters, index.search(t.allocator, "good", .{ .limit = 1, .b = 1.01 }));
    var flag: zft.Cancellation = .{};
    flag.cancel();
    try t.expectError(error.Canceled, index.search(t.allocator, "good", .{ .limit = 1, .cancel = &flag }));
    try t.checkAllAllocationFailures(t.allocator, searchWithAllocator, .{index});
    try index.close();
    try t.expectError(error.IndexClosed, index.search(t.allocator, "good", .{ .limit = 1 }));
}

test "Index enforces a lower read limit when reopening existing documents" {
    const tmp = try TempIndex.init();
    defer tmp.deinit();
    {
        const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{ .create_if_missing = true });
        defer index.deinit();
        try index.upsert(3, "a document that is longer than sixteen bytes");
        try index.close();
    }
    const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{ .max_document_bytes = 16 });
    defer index.deinit();
    try t.expectError(error.RecordTooLarge, index.get(t.allocator, 3));
    try t.expectError(error.RecordTooLarge, index.search(t.allocator, "document", .{ .limit = 1 }));
}

fn searchWithAllocator(allocator: std.mem.Allocator, index: *zft.Index) !void {
    var result = try index.search(allocator, "中国 good", .{ .mode = .phrase, .limit = 1 });
    defer result.deinit(allocator);
    try t.expectEqual(@as(usize, 1), result.total);
    try t.expectEqual(@as(u64, 1), result.hits[0].id);
}
