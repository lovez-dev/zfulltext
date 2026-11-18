const std = @import("std");
const zft = @import("zfulltext");
const t = std.testing;
const io = t.io;

pub const TempIndex = struct {
    path: ["out/index-".len + 24]u8,

    pub fn init() !TempIndex {
        var result: TempIndex = undefined;
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, "out");
        while (true) {
            var random: [12]u8 = undefined;
            io.random(&random);
            result.path = "out/index-".* ++ std.fmt.bytesToHex(random, .lower);
            cwd.createDir(io, &result.path, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
            return result;
        }
    }

    pub fn deinit(self: TempIndex) void {
        std.Io.Dir.cwd().deleteTree(io, &self.path) catch @panic("cannot clean up test index");
    }
};

test "Index persists CRUD and statistics across close and reopen" {
    const tmp = try TempIndex.init();
    defer tmp.deinit();
    const allocator = t.allocator;
    const id = std.math.maxInt(u64);
    {
        const index = try zft.Index.open(allocator, io, &tmp.path, .{ .create_if_missing = true });
        defer index.deinit();
        try index.upsert(id, "hi 中文");
        try index.upsert(0, "");
        try t.expectEqual(zft.Stats{ .document_count = 2, .total_length = 3 }, try index.stats());
        try index.upsert(id, "good bye");
        try t.expectEqual(zft.Stats{ .document_count = 2, .total_length = 2 }, try index.stats());
        try index.close();
        try index.close();
        try t.expectError(error.IndexClosed, index.stats());
        try t.expectError(error.IndexClosed, index.get(allocator, id));
        try t.expectError(error.IndexClosed, index.upsert(id, ""));
        try t.expectError(error.IndexClosed, index.delete(id));
    }
    {
        const index = try zft.Index.open(allocator, io, &tmp.path, .{});
        defer index.deinit();
        var doc = (try index.get(allocator, id)).?;
        defer doc.deinit(allocator);
        try t.expectEqual(id, doc.id);
        try t.expectEqualStrings("good bye", doc.text);
        var empty = (try index.get(allocator, 0)).?;
        defer empty.deinit(allocator);
        try t.expectEqualStrings("", empty.text);
        try t.expectEqual(zft.Stats{ .document_count = 2, .total_length = 2 }, try index.stats());
        try t.expect(try index.delete(id));
        try t.expect(!try index.delete(id));
        try t.expect((try index.get(allocator, id)) == null);
        try t.expectEqual(zft.Stats{ .document_count = 1, .total_length = 0 }, try index.stats());
        try index.close();
    }
    const index = try zft.Index.open(allocator, io, &tmp.path, .{});
    defer index.deinit();
    try t.expect((try index.get(allocator, id)) == null);
    try t.expectEqual(zft.Stats{ .document_count = 1, .total_length = 0 }, try index.stats());
}
