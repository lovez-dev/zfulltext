const std = @import("std");
const wiskdb = @import("wiskdb");

pub const Options = struct {
    create_if_missing: bool = false,
    durability: wiskdb.Durability = .sync,
    max_document_bytes: usize = 1024 * 1024,
    max_query_bytes: usize = 16 * 1024,
    max_result_count: usize = 10_000,
};

pub const MatchMode = enum { all, any, phrase };

pub const SearchOptions = struct {
    mode: MatchMode = .all,
    limit: usize = 10,
    k1: f64 = 1.2,
    b: f64 = 0.75,
    cancel: ?*const Cancellation = null,
};

pub const Cancellation = struct {
    cancelled: std.atomic.Value(bool) = .init(false),

    pub fn cancel(self: *Cancellation) void {
        self.cancelled.store(true, .release);
    }

    pub fn isCancelled(self: *const Cancellation) bool {
        return self.cancelled.load(.acquire);
    }
};

pub const Document = struct {
    id: u64,
    text: []const u8,

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const Stats = struct { document_count: u64, total_length: u64 };
pub const Hit = struct { id: u64, score: f64 };

pub const SearchResult = struct {
    hits: []Hit,
    total: usize,

    pub fn deinit(self: *SearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.hits);
        self.* = undefined;
    }
};

test "Cancellation is an atomic one-way flag" {
    var cancellation: Cancellation = .{};
    try std.testing.expect(!cancellation.isCancelled());
    cancellation.cancel();
    try std.testing.expect(cancellation.isCancelled());
}
