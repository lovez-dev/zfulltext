const std = @import("std");
const zfulltext = @import("zfulltext");

test {
    _ = @import("index.zig");
    _ = @import("index_query.zig");
    _ = @import("index_failures.zig");
    _ = @import("index_consistency.zig");
}

test "public foundational exports are available" {
    try std.testing.expect(zfulltext.MatchMode.all == .all);
    const options: zfulltext.SearchOptions = .{};
    try std.testing.expectEqual(@as(usize, 10), options.limit);
    const stats: zfulltext.Stats = .{ .document_count = 7, .total_length = 12 };
    try std.testing.expectEqual(@as(u64, 7), stats.document_count);
}
