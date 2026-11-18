const std = @import("std");
const zft = @import("zfulltext");
const wiskdb = @import("wiskdb");
const t = std.testing;
const TempIndex = @import("index.zig").TempIndex;

fn expectOpenError(path: []const u8, options: zft.Options, expected: anyerror) !void {
    const index = zft.Index.open(t.allocator, t.io, path, options) catch |err| {
        try t.expectEqual(expected, err);
        return;
    };
    index.deinit();
    return error.TestExpectedError;
}

test "Index.open rejects unrelated and corrupt indexes without resetting existing files" {
    const allocator = t.allocator;
    const empty = try TempIndex.init();
    defer empty.deinit();
    try expectOpenError(&empty.path, .{}, error.NotAnIndex);
    const created = try zft.Index.open(allocator, t.io, &empty.path, .{ .create_if_missing = true });
    try created.close();
    created.deinit();

    const unrelated = try TempIndex.init();
    defer unrelated.deinit();
    const dir = try std.Io.Dir.cwd().openDir(t.io, &unrelated.path, .{ .iterate = true });
    defer dir.close(t.io);
    try dir.writeFile(t.io, .{ .sub_path = "not-an-index", .data = "sentinel" });
    try expectOpenError(&unrelated.path, .{ .create_if_missing = true }, error.NotAnIndex);
    const preserved = try dir.readFileAlloc(t.io, "not-an-index", allocator, .unlimited);
    defer allocator.free(preserved);
    try t.expectEqualStrings("sentinel", preserved);

    const corrupt = try TempIndex.init();
    defer corrupt.deinit();
    const corrupt_dir = try std.Io.Dir.cwd().openDir(t.io, &corrupt.path, .{ .iterate = true });
    defer corrupt_dir.close(t.io);
    try corrupt_dir.writeFile(t.io, .{ .sub_path = "CURRENT", .data = "not-a-manifest" });
    try expectOpenError(&corrupt.path, .{ .create_if_missing = true }, error.CorruptRecord);
}

test "Index.open retries after a bootstrap allocation failure" {
    const tmp = try TempIndex.init();
    defer tmp.deinit();
    try t.expectError(error.OutOfMemory, zft.Index.testing.failBootstrap(t.allocator, t.io, &tmp.path));

    const dir = try std.Io.Dir.cwd().openDir(t.io, &tmp.path, .{ .iterate = true });
    defer dir.close(t.io);
    _ = try dir.statFile(t.io, "CURRENT", .{});
    try expectOpenError(&tmp.path, .{}, error.NotAnIndex);
    {
        const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{ .create_if_missing = true });
        defer index.deinit();
        try t.expectEqual(zft.Stats{ .document_count = 0, .total_length = 0 }, try index.stats());
        try index.upsert(1, "term");
        try index.close();
    }
    try t.expectError(error.FileNotFound, dir.statFile(t.io, ".zfulltext-init", .{}));
    const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{});
    defer index.deinit();
    var doc = (try index.get(t.allocator, 1)) orelse return error.MissingDocument;
    defer doc.deinit(t.allocator);
    try t.expectEqualStrings("term", doc.text);
}

test "Index.open rejects an invalid bootstrap marker without initializing the directory" {
    const tmp = try TempIndex.init();
    defer tmp.deinit();
    const dir = try std.Io.Dir.cwd().openDir(t.io, &tmp.path, .{ .iterate = true });
    defer dir.close(t.io);
    const marker_name = ".zfulltext-init";
    const invalid_marker = "zfulltext bootstrap v1 extra";
    try dir.writeFile(t.io, .{ .sub_path = marker_name, .data = invalid_marker, .flags = .{ .exclusive = true } });
    try expectOpenError(&tmp.path, .{ .create_if_missing = true }, error.CorruptRecord);
    try t.expectError(error.FileNotFound, dir.statFile(t.io, "CURRENT", .{}));
    var buffer: [invalid_marker.len + 1]u8 = undefined;
    try t.expectEqualStrings(invalid_marker, try dir.readFile(t.io, marker_name, &buffer));
}

test "Index.open rejects unrelated files and a missing CURRENT during bootstrap recovery" {
    const tmp = try TempIndex.init();
    defer tmp.deinit();
    try t.expectError(error.OutOfMemory, zft.Index.testing.failBootstrap(t.allocator, t.io, &tmp.path));
    const dir = try std.Io.Dir.cwd().openDir(t.io, &tmp.path, .{ .iterate = true });
    defer dir.close(t.io);

    try dir.writeFile(t.io, .{ .sub_path = "unrelated.txt", .data = "keep", .flags = .{ .exclusive = true } });
    try expectOpenError(&tmp.path, .{ .create_if_missing = true }, error.NotAnIndex);
    var buffer: [5]u8 = undefined;
    try t.expectEqualStrings("keep", try dir.readFile(t.io, "unrelated.txt", &buffer));
    try dir.deleteFile(t.io, "unrelated.txt");

    try dir.deleteFile(t.io, "CURRENT");
    try expectOpenError(&tmp.path, .{ .create_if_missing = true }, error.NotAnIndex);
    try t.expectError(error.FileNotFound, dir.statFile(t.io, "CURRENT", .{}));
    _ = try dir.statFile(t.io, ".zfulltext-init", .{});
}

test "Index.open preserves application rows in a marked store with no schema" {
    const tmp = try TempIndex.init();
    defer tmp.deinit();
    try t.expectError(error.OutOfMemory, zft.Index.testing.failBootstrap(t.allocator, t.io, &tmp.path));
    const dir = try std.Io.Dir.cwd().openDir(t.io, &tmp.path, .{ .iterate = true });
    defer dir.close(t.io);
    {
        var db = try wiskdb.Db.open(t.allocator, t.io, dir, .{});
        defer db.deinit();
        try db.put("unrelated", "sentinel");
        try db.close();
    }
    try expectOpenError(&tmp.path, .{ .create_if_missing = true }, error.NotAnIndex);
    var db = try wiskdb.Db.open(t.allocator, t.io, dir, .{});
    defer db.deinit();
    const value = (try db.get("unrelated")) orelse return error.MissingSentinel;
    defer db.allocator.free(value);
    try t.expectEqualStrings("sentinel", value);
    try t.expect((try db.get(zft.codec.schema_key)) == null);
}

test "Index.search and Index.get reject invalid UTF-8 in an existing document" {
    const tmp = try TempIndex.init();
    defer tmp.deinit();
    const text = "term term";
    {
        const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{ .create_if_missing = true });
        defer index.deinit();
        try index.upsert(1, text);
        try index.close();
    }
    {
        const dir = try std.Io.Dir.cwd().openDir(t.io, &tmp.path, .{ .iterate = true });
        defer dir.close(t.io);
        var db = try wiskdb.Db.open(t.allocator, t.io, dir, .{});
        defer db.deinit();
        const key = try zft.codec.documentKey(t.allocator, 1);
        defer t.allocator.free(key);
        const value = (try db.get(key)) orelse return error.MissingDocument;
        defer db.allocator.free(value);
        const text_offset = zft.codec.document_magic.len + @sizeOf(u8) + @sizeOf(u64) + @sizeOf(u32);
        try t.expectEqualStrings(text, value[text_offset..][0..text.len]);
        const corrupted = try t.allocator.dupe(u8, value);
        defer t.allocator.free(corrupted);
        corrupted[text_offset] = 0xff;
        try db.put(key, corrupted);
        try db.close();
    }
    const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{});
    defer index.deinit();
    try t.expectError(error.InvalidUtf8, index.search(t.allocator, "term", .{}));
    try t.expectError(error.InvalidUtf8, index.get(t.allocator, 1));
}

test "Index rejects invalid limits, writer conflicts and oversized documents" {
    const tmp = try TempIndex.init();
    defer tmp.deinit();
    try expectOpenError(&tmp.path, .{ .max_document_bytes = 0 }, error.InvalidOptions);
    try expectOpenError(&tmp.path, .{ .max_document_bytes = 1024 * 1024 + 1 }, error.InvalidOptions);
    try expectOpenError(&tmp.path, .{ .max_query_bytes = 0 }, error.InvalidOptions);
    try expectOpenError(&tmp.path, .{ .max_query_bytes = 16 * 1024 + 1 }, error.InvalidOptions);
    const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{ .create_if_missing = true, .max_document_bytes = 16 });
    defer index.deinit();
    try expectOpenError(&tmp.path, .{}, error.DbLocked);
    try t.expectError(error.DocumentTooLarge, index.upsert(1, "xxxxxxxxxxxxxxxxx"));
    try t.expectEqual(zft.Stats{ .document_count = 0, .total_length = 0 }, try index.stats());
}

test "Index mutation OOM leaves acknowledged state unchanged" {
    const tmp = try TempIndex.init();
    defer tmp.deinit();
    var failing = t.FailingAllocator.init(t.allocator, .{});
    const allocator = failing.allocator();
    const index = try zft.Index.open(allocator, t.io, &tmp.path, .{ .create_if_missing = true });
    defer index.deinit();
    const fail_index = failing.alloc_index;
    failing.fail_index = fail_index;
    try t.expectError(error.OutOfMemory, index.upsert(1, "new term"));
    failing.fail_index = std.math.maxInt(usize);
    try t.expectEqual(zft.Stats{ .document_count = 0, .total_length = 0 }, try index.stats());
    try t.expect((try index.get(t.allocator, 1)) == null);
}

test "Index.open validates stored schema and statistics records" {
    const tmp = try TempIndex.init();
    defer tmp.deinit();
    const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{ .create_if_missing = true });
    try index.close();
    index.deinit();

    const dir = try std.Io.Dir.cwd().openDir(t.io, &tmp.path, .{ .iterate = true });
    defer dir.close(t.io);
    var db = try wiskdb.Db.open(t.allocator, t.io, dir, .{});
    defer db.deinit();
    try db.put(zft.codec.schema_key, "ZFTI\x01\xff");
    try db.close();
    try expectOpenError(&tmp.path, .{}, error.UnsupportedVersion);

    var repair = try wiskdb.Db.open(t.allocator, t.io, dir, .{});
    defer repair.deinit();
    try repair.put(zft.codec.schema_key, "ZFTI\x01\x01");
    try repair.put(zft.codec.statistics_key, "bad");
    try repair.close();
    try expectOpenError(&tmp.path, .{}, error.CorruptRecord);
}
