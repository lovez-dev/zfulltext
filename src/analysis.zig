const std = @import("std");

pub const Token = struct {
    term: []const u8,
    position: u64,
    length: u8,
};

pub const Tokens = struct {
    allocator: std.mem.Allocator,
    items: []Token,
    logical_length: u64,

    pub fn deinit(self: *Tokens) void {
        for (self.items) |token| self.allocator.free(token.term);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

const Unit = struct { start: usize, end: usize, codepoint: u21 };

fn decode(text: []const u8, offset: usize) error{InvalidUtf8}!Unit {
    const first = text[offset];
    if (first < 0x80) return .{ .start = offset, .end = offset + 1, .codepoint = first };
    const width: usize = if (first >= 0xc2 and first <= 0xdf) 2 else if (first >= 0xe0 and first <= 0xef) 3 else if (first >= 0xf0 and first <= 0xf4) 4 else return error.InvalidUtf8;
    if (width > text.len - offset) return error.InvalidUtf8;
    const mask: u8 = switch (width) {
        2 => 0x1f,
        3 => 0x0f,
        4 => 0x07,
        else => unreachable,
    };
    var value: u21 = @as(u21, first & mask);
    for (1..width) |i| {
        const next = text[offset + i];
        if (next & 0xc0 != 0x80) return error.InvalidUtf8;
        value = (value << 6) | @as(u21, next & 0x3f);
    }
    if ((width == 2 and value < 0x80) or (width == 3 and value < 0x800) or (width == 4 and value < 0x10000) or value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) return error.InvalidUtf8;
    return .{ .start = offset, .end = offset + width, .codepoint = value };
}

pub fn validateUtf8(text: []const u8) error{InvalidUtf8}!void {
    var offset: usize = 0;
    while (offset < text.len) {
        const unit = try decode(text, offset);
        offset = unit.end;
    }
}

fn isHan(c: u21) bool {
    return (c >= 0x3400 and c <= 0x4dbf) or (c >= 0x4e00 and c <= 0x9fff) or
        (c >= 0xf900 and c <= 0xfaff) or (c >= 0x20000 and c <= 0x3134f);
}

fn isSeparator(c: u21) bool {
    const whitespace = c <= 0x20 or c == 0x85 or c == 0xa0 or c == 0x1680 or
        (c >= 0x2000 and c <= 0x200a) or c == 0x2028 or c == 0x2029 or
        c == 0x202f or c == 0x205f or c == 0x3000;
    const punctuation = (c >= 0x7f and c <= 0x9f) or
        (c >= 0x200b and c <= 0x206f) or (c >= 0x3000 and c <= 0x303f) or
        (c >= 0xff00 and c <= 0xff0f) or (c >= 0xff1a and c <= 0xff20) or
        (c >= 0xff3b and c <= 0xff40) or (c >= 0xff5b and c <= 0xff65);
    return whitespace or punctuation;
}

fn emit(allocator: std.mem.Allocator, list: *std.ArrayList(Token), term: []const u8, position: u64, length: u8) !void {
    const owned_term = try allocator.dupe(u8, term);
    errdefer allocator.free(owned_term);
    try list.append(allocator, .{ .term = owned_term, .position = position, .length = length });
}

pub fn analyze(allocator: std.mem.Allocator, text: []const u8, query: bool) !Tokens {
    try validateUtf8(text);
    var output: std.ArrayList(Token) = .empty;
    errdefer {
        for (output.items) |token| allocator.free(token.term);
        output.deinit(allocator);
    }
    var position: u64 = 0;
    var offset: usize = 0;
    while (offset < text.len) {
        const unit = try decode(text, offset);
        if (unit.codepoint < 128 and std.ascii.isAlphanumeric(@intCast(unit.codepoint))) {
            var end = unit.end;
            while (end < text.len and text[end] < 128 and std.ascii.isAlphanumeric(text[end])) : (end += 1) {}
            const word = try allocator.alloc(u8, end - offset);
            errdefer allocator.free(word);
            for (text[offset..end], 0..) |byte, i| word[i] = std.ascii.toLower(byte);
            const next_position = try std.math.add(u64, position, 1);
            try output.append(allocator, .{ .term = word, .position = position, .length = 1 });
            position = next_position;
            offset = end;
            continue;
        }
        if (isHan(unit.codepoint)) {
            var current = unit;
            while (true) {
                const next = if (current.end < text.len) try decode(text, current.end) else null;
                const following_han = if (next) |n| if (isHan(n.codepoint)) n else null else null;
                if (!query or (current.start == offset and following_han == null)) {
                    try emit(allocator, &output, text[current.start..current.end], position, 1);
                }
                position = try std.math.add(u64, position, 1);
                if (following_han) |han| {
                    try emit(allocator, &output, text[current.start..han.end], position - 1, 2);
                    current = han;
                } else break;
            }
            offset = current.end;
            continue;
        }
        if (unit.codepoint < 128 or isSeparator(unit.codepoint)) {
            offset = unit.end;
            continue;
        }
        // Other scripts are conservatively indexed as single codepoint tokens.
        try emit(allocator, &output, text[unit.start..unit.end], position, 1);
        position = try std.math.add(u64, position, 1);
        offset = unit.end;
    }
    return .{ .allocator = allocator, .items = try output.toOwnedSlice(allocator), .logical_length = position };
}

pub fn analyzeDocument(allocator: std.mem.Allocator, text: []const u8) !Tokens {
    return analyze(allocator, text, false);
}

pub fn analyzeQuery(allocator: std.mem.Allocator, text: []const u8) !Tokens {
    return analyze(allocator, text, true);
}

test "mixed ASCII and Han tokens preserve logical positions and ownership" {
    var tokens = try analyzeDocument(std.testing.allocator, "Hi中中文!");
    defer tokens.deinit();
    try std.testing.expectEqual(@as(u64, 4), tokens.logical_length);
    try std.testing.expectEqual(@as(usize, 6), tokens.items.len);
    try std.testing.expectEqualStrings("hi", tokens.items[0].term);
    try std.testing.expectEqual(@as(u64, 0), tokens.items[0].position);
    try std.testing.expectEqualStrings("中", tokens.items[1].term);
    try std.testing.expectEqual(@as(u64, 1), tokens.items[1].position);
    try std.testing.expectEqualStrings("中中", tokens.items[2].term);
    try std.testing.expectEqual(@as(u64, 1), tokens.items[2].position);
    try std.testing.expectEqualStrings("中", tokens.items[3].term);
    try std.testing.expectEqual(@as(u64, 2), tokens.items[3].position);
    try std.testing.expectEqualStrings("中文", tokens.items[4].term);
    try std.testing.expectEqual(@as(u64, 2), tokens.items[4].position);
    try std.testing.expectEqualStrings("文", tokens.items[5].term);
    try std.testing.expectEqual(@as(u64, 3), tokens.items[5].position);
    var query = try analyzeQuery(std.testing.allocator, "中文");
    defer query.deinit();
    try std.testing.expectEqual(@as(usize, 1), query.items.len);
    try std.testing.expectEqualStrings("中文", query.items[0].term);
}

test "single Han query, separators, duplicate terms, and empty text" {
    var one = try analyzeQuery(std.testing.allocator, "中");
    defer one.deinit();
    try std.testing.expectEqualStrings("中", one.items[0].term);
    var repeated = try analyzeDocument(std.testing.allocator, "Go go,go");
    defer repeated.deinit();
    try std.testing.expectEqual(@as(usize, 3), repeated.items.len);
    try std.testing.expectEqualStrings("go", repeated.items[0].term);
    try std.testing.expectEqual(@as(u64, 2), repeated.items[2].position);
    var separated = try analyzeDocument(std.testing.allocator, "a\xc2\xa0b");
    defer separated.deinit();
    try std.testing.expectEqual(@as(usize, 2), separated.items.len);
    try std.testing.expectEqualStrings("a", separated.items[0].term);
    try std.testing.expectEqualStrings("b", separated.items[1].term);
    var empty = try analyzeDocument(std.testing.allocator, "");
    defer empty.deinit();
    try std.testing.expectEqual(@as(u64, 0), empty.logical_length);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
}

test "streaming Han runs preserve final grams and independent token storage" {
    var input = [_]u8{ 0xe4, 0xb8, 0xad, 0xe6, 0x96, 0x87, 0xe5, 0xad, 0x97 };
    var document = try analyzeDocument(std.testing.allocator, &input);
    defer document.deinit();
    var query = try analyzeQuery(std.testing.allocator, &input);
    defer query.deinit();
    @memset(&input, 0);
    try std.testing.expectEqual(@as(usize, 5), document.items.len);
    try std.testing.expectEqual(@as(usize, 2), query.items.len);
    try std.testing.expectEqualStrings("中文", query.items[0].term);
    try std.testing.expectEqualStrings("文字", query.items[1].term);
    try std.testing.expectEqual(@as(u64, 1), query.items[1].position);
    try std.testing.expectEqual(@as(u64, 3), query.logical_length);
    try std.testing.expectEqualStrings("字", document.items[4].term);
}

test "invalid UTF-8 is rejected" {
    try std.testing.expectError(error.InvalidUtf8, validateUtf8(&.{ 0xc0, 0x80 }));
    try std.testing.expectError(error.InvalidUtf8, validateUtf8(&.{ 0xe2, 0x82 }));
}

test "all analyzer allocation failures clean up" {
    const Context = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var tokens = try analyzeDocument(allocator, "Hi 中文 Go");
            tokens.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
    const Mixed = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var document = try analyzeDocument(allocator, "ASCII words 中文字 Ελληνικά");
            defer document.deinit();
            var query = try analyzeQuery(allocator, "ASCII words 中文字 Ελληνικά");
            defer query.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Mixed.run, .{});
}
