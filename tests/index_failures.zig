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

test "Search results and get reject invalid UTF-8 in stored text" {
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

test "Search rejects legacy documents with invalid UTF-8" {
    const tmp = try TempIndex.init();
    defer tmp.deinit();
    {
        const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{ .create_if_missing = true });
        defer index.deinit();
        try index.upsert(1, "term");
        try index.close();
    }
    {
        const dir = try std.Io.Dir.cwd().openDir(t.io, &tmp.path, .{ .iterate = true });
        defer dir.close(t.io);
        var db = try wiskdb.Db.open(t.allocator, t.io, dir, .{});
        defer db.deinit();
        const key = zft.codec.documentKeyBytes(1);
        const value = (try db.get(&key)) orelse return error.MissingDocument;
        defer db.allocator.free(value);
        const corrupt = try t.allocator.dupe(u8, value);
        defer t.allocator.free(corrupt);
        corrupt[zft.codec.document_magic.len + 1 + 8 + 4] = 0xff;
        try db.put(&key, corrupt);
        try db.delete(&zft.codec.scoringKey(1));
        try db.put(zft.codec.schema_key, "ZFTI\x01\x01");
        try db.close();
    }
    const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{});
    defer index.deinit();
    try t.expectError(error.InvalidUtf8, index.search(t.allocator, "term", .{}));
}

test "Legacy scoring metadata upgrades atomically and survives replacements and deletes" {
    const tmp = try TempIndex.init();
    defer tmp.deinit();
    const texts = [_][]const u8{ "term term", "term filler filler filler", "rare filler" };
    var expected_hits: [2]zft.Hit = undefined;
    {
        const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{ .create_if_missing = true });
        defer index.deinit();
        for (texts, 0..) |text, id| try index.upsert(id, text);
        var result = try index.search(t.allocator, "term", .{});
        defer result.deinit(t.allocator);
        try t.expectEqual(@as(usize, 2), result.hits.len);
        @memcpy(&expected_hits, result.hits);
        try index.close();
    }
    // Make a real legacy store: no metadata records and the original schema.
    {
        const dir = try std.Io.Dir.cwd().openDir(t.io, &tmp.path, .{ .iterate = true });
        defer dir.close(t.io);
        var db = try wiskdb.Db.open(t.allocator, t.io, dir, .{});
        defer db.deinit();
        for (0..texts.len) |id| try db.delete(&zft.codec.scoringKey(id));
        try db.put(zft.codec.schema_key, "ZFTI\x01\x01");
        try db.close();
    }
    {
        var failing = t.FailingAllocator.init(t.allocator, .{});
        const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{});
        defer index.deinit();
        var original = try index.search(t.allocator, "term", .{});
        defer original.deinit(t.allocator);
        try t.expectEqualDeep(expected_hits[0..], original.hits);
        failing.fail_index = failing.alloc_index;
        try t.expectError(error.OutOfMemory, zft.Index.testing.upsertWithAllocator(index, failing.allocator(), 0, texts[0]));
        failing.fail_index = std.math.maxInt(usize);
        // This replacement upgrades only one document; the others stay legacy.
        try index.upsert(0, texts[0]);
        var mixed = try index.search(t.allocator, "term", .{});
        defer mixed.deinit(t.allocator);
        try t.expectEqualDeep(expected_hits[0..], mixed.hits);
        try index.close();
    }
    {
        const dir = try std.Io.Dir.cwd().openDir(t.io, &tmp.path, .{ .iterate = true });
        defer dir.close(t.io);
        var db = try wiskdb.Db.open(t.allocator, t.io, dir, .{});
        defer db.deinit();
        const header = (try db.get(zft.codec.schema_key)) orelse return error.MissingSchema;
        defer db.allocator.free(header);
        try t.expectEqualStrings("ZFTI\x02\x01", header);
        const metadata = (try db.get(&zft.codec.scoringKey(0))) orelse return error.MissingMetadata;
        defer db.allocator.free(metadata);
        try t.expectEqual(@as(u32, 2), (try zft.codec.ScoringMetadata.decode(metadata, 100)).logical_length);
        try t.expect((try db.get(&zft.codec.scoringKey(1))) == null);
        try db.close();
    }
    {
        const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{});
        defer index.deinit();
        var reopened = try index.search(t.allocator, "term", .{});
        defer reopened.deinit(t.allocator);
        try t.expectEqualDeep(expected_hits[0..], reopened.hits);
        try index.upsert(0, "replacement");
        try t.expect(try index.delete(0));
        try t.expect(try index.delete(1));
        try t.expect(!(try index.delete(0)));
        try index.close();
    }
    {
        const dir = try std.Io.Dir.cwd().openDir(t.io, &tmp.path, .{ .iterate = true });
        defer dir.close(t.io);
        var db = try wiskdb.Db.open(t.allocator, t.io, dir, .{});
        defer db.deinit();
        try t.expect((try db.get(&zft.codec.scoringKey(0))) == null);
        try t.expect((try db.get(&zft.codec.scoringKey(1))) == null);
        try db.close();
    }
}

test "Search rejects corrupt scoring metadata while get still validates the document" {
    const tmp = try TempIndex.init();
    defer tmp.deinit();
    {
        const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{ .create_if_missing = true });
        defer index.deinit();
        try index.upsert(1, "term");
        try index.close();
    }
    {
        const dir = try std.Io.Dir.cwd().openDir(t.io, &tmp.path, .{ .iterate = true });
        defer dir.close(t.io);
        var db = try wiskdb.Db.open(t.allocator, t.io, dir, .{});
        defer db.deinit();
        try db.put(&zft.codec.scoringKey(1), "malformed");
        try db.close();
    }
    const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{});
    defer index.deinit();
    try t.expectError(error.CorruptRecord, index.search(t.allocator, "term", .{}));
    var doc = (try index.get(t.allocator, 1)) orelse return error.MissingDocument;
    defer doc.deinit(t.allocator);
    try t.expectEqualStrings("term", doc.text);
}

test "Search rejects scoring metadata inconsistent with returned document bytes or length" {
    const cases = [_]struct {
        text: []const u8,
        text_bytes: u32,
        logical_length: u32 = 2,
    }{
        .{ .text = "term term", .text_bytes = 8 },
        .{ .text = "term term", .text_bytes = 10 },
        .{ .text = "term term", .text_bytes = 9, .logical_length = 3 },
        .{ .text = "term \xe4\xb8\xad", .text_bytes = 6 },
    };
    for (cases) |case| {
        const tmp = try TempIndex.init();
        defer tmp.deinit();
        var expected: zft.Hit = undefined;
        {
            const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{ .create_if_missing = true });
            defer index.deinit();
            try index.upsert(1, case.text);
            try index.upsert(2, "filler filler");
            var result = try index.search(t.allocator, "term", .{ .limit = 1 });
            defer result.deinit(t.allocator);
            try t.expectEqual(@as(usize, 1), result.total);
            try t.expectEqual(@as(usize, 1), result.hits.len);
            expected = result.hits[0];
            try index.close();
        }
        {
            const dir = try std.Io.Dir.cwd().openDir(t.io, &tmp.path, .{ .iterate = true });
            defer dir.close(t.io);
            var db = try wiskdb.Db.open(t.allocator, t.io, dir, .{});
            defer db.deinit();
            // Each record passes its own bounds checks but disagrees with the document.
            const encoded = (zft.codec.ScoringMetadata{
                .text_bytes = case.text_bytes,
                .logical_length = case.logical_length,
            }).encode();
            _ = try zft.codec.ScoringMetadata.decode(&encoded, 100);
            try db.put(&zft.codec.scoringKey(1), &encoded);
            try db.close();
        }
        const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{});
        defer index.deinit();
        for ([_]zft.MatchMode{ .all, .any, .phrase }) |mode| {
            if (index.search(t.allocator, "term", .{ .mode = mode, .limit = 1 })) |result| {
                var unexpected = result;
                unexpected.deinit(t.allocator);
                return error.TestExpectedError;
            } else |err| try t.expectEqual(error.CorruptRecord, err);
        }
        var doc = (try index.get(t.allocator, 1)) orelse return error.MissingDocument;
        defer doc.deinit(t.allocator);
        try t.expectEqualStrings(case.text, doc.text);
        try index.upsert(1, case.text);
        var repaired = try index.search(t.allocator, "term", .{ .limit = 1 });
        defer repaired.deinit(t.allocator);
        try t.expectEqual(@as(usize, 1), repaired.total);
        try t.expectEqual(@as(usize, 1), repaired.hits.len);
        try t.expectEqualDeep(expected, repaired.hits[0]);
    }
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
    const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{ .create_if_missing = true });
    defer index.deinit();
    const fail_index = failing.alloc_index;
    failing.fail_index = fail_index;
    try t.expectError(error.OutOfMemory, zft.Index.testing.upsertWithAllocator(index, allocator, 1, "new term"));
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
