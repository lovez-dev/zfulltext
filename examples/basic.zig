const std = @import("std");
const zft = @import("zfulltext");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out");
    var path: ["out/example-".len + 24]u8 = undefined;
    while (true) {
        var random: [12]u8 = undefined;
        io.random(&random);
        path = "out/example-".* ++ std.fmt.bytesToHex(random, .lower);
        cwd.createDir(io, &path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        break;
    }
    defer cwd.deleteTree(io, &path) catch {};

    const index = try zft.Index.open(allocator, io, &path, .{ .create_if_missing = true });
    defer index.deinit();

    try index.upsert(1, "Hello from the search example.");
    try index.upsert(2, "在中文和 English 中检索。 Search across languages.");

    var result = try index.search(allocator, "search 中文", .{ .mode = .any, .limit = 10 });
    defer result.deinit(allocator);
    const stdout = std.Io.File.stdout();
    for (result.hits) |hit| {
        const line = try std.fmt.allocPrint(allocator, "match id={d}, score={d:.3}\n", .{ hit.id, hit.score });
        defer allocator.free(line);
        try stdout.writeStreamingAll(io, line);
    }

    try index.upsert(1, "Updated searchable text.");
    _ = try index.delete(2);
    var document = (try index.get(allocator, 1)) orelse return error.MissingDocument;
    defer document.deinit(allocator);
    const line = try std.fmt.allocPrint(allocator, "document {d}: {s}\n", .{ document.id, document.text });
    defer allocator.free(line);
    try stdout.writeStreamingAll(io, line);
    try index.close();
}
