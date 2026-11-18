const std = @import("std");
const zft = @import("zfulltext");
const TempIndex = @import("index.zig").TempIndex;
const t = std.testing;

const documents = [_][]const u8{
    "",                "amber",             "blue",                  "amber blue", "blue amber", "amber amber blue",
    "blue green blue", "green amber green", "blue amber blue amber",
};
const queries = [_][]const u8{ "amber", "green blue", "amber blue", "blue amber", "amber amber", "black amber", "black" };

// The fixtures contain only lowercase ASCII words with single spaces between
// them. The oracle uses exact word and contiguous string matches, not the index analyzer.
fn containsWord(text: []const u8, word: []const u8) bool {
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |candidate| {
        if (std.mem.eql(u8, candidate, word)) return true;
    }
    return false;
}

fn matches(text: []const u8, query: []const u8, mode: zft.MatchMode) bool {
    if (mode == .phrase) {
        var start: usize = 0;
        while (std.mem.findPos(u8, text, start, query)) |pos| {
            const end = pos + query.len;
            if ((pos == 0 or text[pos - 1] == ' ') and (end == text.len or text[end] == ' ')) return true;
            start = pos + 1;
        }
        return false;
    }
    var words = std.mem.tokenizeScalar(u8, query, ' ');
    while (words.next()) |word| {
        if (containsWord(text, word)) {
            if (mode == .any) return true;
        } else if (mode == .all) return false;
    }
    return mode == .all;
}

test "Index agrees with a simple ASCII oracle across 96 mutations" {
    const tmp = try TempIndex.init();
    defer tmp.deinit();
    const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{ .create_if_missing = true });
    defer index.deinit();

    var model: [8]?[]const u8 = @splat(null);
    var prng = std.Random.DefaultPrng.init(0xeab39adb);
    const random = prng.random();
    for (0..96) |round| {
        const id = random.uintLessThan(usize, model.len);
        if (random.uintLessThan(u8, 4) == 0) {
            try t.expectEqual(model[id] != null, try index.delete(id));
            model[id] = null;
        } else {
            const text = documents[random.uintLessThan(usize, documents.len)];
            try index.upsert(id, text);
            model[id] = text;
        }

        var expected_stats: zft.Stats = .{ .document_count = 0, .total_length = 0 };
        for (model, 0..) |text, doc_id| {
            const actual = try index.get(t.allocator, doc_id);
            if (actual) |stored| {
                var doc = stored;
                defer doc.deinit(t.allocator);
                try t.expectEqual(doc_id, doc.id);
                try t.expectEqualStrings(text orelse return error.UnexpectedDocument, doc.text);
            } else try t.expect(text == null);
            if (text) |present| {
                expected_stats.document_count += 1;
                if (present.len > 0) expected_stats.total_length += 1 + std.mem.count(u8, present, " ");
            }
        }
        try t.expectEqual(expected_stats, try index.stats());

        const query = queries[round % queries.len];
        for ([_]zft.MatchMode{ .all, .any, .phrase }) |mode| {
            var expected: [model.len]bool = @splat(false);
            var total: usize = 0;
            for (model, 0..) |text, doc_id| {
                expected[doc_id] = if (text) |present| matches(present, query, mode) else false;
                total += @intFromBool(expected[doc_id]);
            }
            var result = try index.search(t.allocator, query, .{ .mode = mode, .limit = model.len });
            defer result.deinit(t.allocator);
            try t.expectEqual(total, result.total);
            try t.expectEqual(total, result.hits.len);
            for (result.hits) |hit| {
                try t.expect(hit.id < model.len and expected[hit.id]);
                expected[hit.id] = false;
            }
        }
    }
}

const ReplaceWork = struct {
    const versions = [2][]const u8{ "alpha beta alpha", "alpha beta beta beta extra" };
    const rounds = 64;

    index: *zft.Index,
    start: std.Io.Semaphore = .{},
    result: anyerror!void = {},

    fn write(self: *ReplaceWork) void {
        self.start.waitUncancelable(t.io);
        for (0..rounds) |round| {
            self.index.upsert(1, versions[(round + 1) % versions.len]) catch |err| {
                self.result = err;
                return;
            };
        }
    }
};

fn sharedHitScore(index: *zft.Index, mode: zft.MatchMode) !f64 {
    var result = try index.search(t.allocator, "alpha beta", .{ .mode = mode });
    defer result.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), result.total);
    try t.expectEqual(@as(usize, 1), result.hits.len);
    try t.expectEqual(@as(u64, 1), result.hits[0].id);
    return result.hits[0].score;
}

test "Concurrent searches see a complete document version during replacements" {
    const tmp = try TempIndex.init();
    defer tmp.deinit();
    const index = try zft.Index.open(t.allocator, t.io, &tmp.path, .{ .create_if_missing = true });
    defer index.deinit();
    // A second document keeps IDF and average-length normalization meaningful.
    try index.upsert(2, "alpha");
    try index.upsert(1, ReplaceWork.versions[1]);
    const second = try sharedHitScore(index, .all);
    try index.upsert(1, ReplaceWork.versions[0]);
    const first = try sharedHitScore(index, .all);
    try t.expect(first != second);

    var work: ReplaceWork = .{ .index = index };
    {
        const writer = try std.Thread.spawn(.{}, ReplaceWork.write, .{&work});
        defer writer.join();
        work.start.post(t.io);
        for (0..ReplaceWork.rounds * 2) |round| {
            const score = try sharedHitScore(index, if (round % 2 == 0) .all else .phrase);
            try t.expect(score == first or score == second);
            const stats = try index.stats();
            try t.expectEqual(@as(u64, 2), stats.document_count);
            try t.expect(stats.total_length == 4 or stats.total_length == 6);
        }
    }
    try work.result;
}
