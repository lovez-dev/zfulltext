const std = @import("std");
const analysis = @import("analysis.zig");

pub const format_version: u8 = 1;
pub const document_magic = "ZFTD";
pub const posting_magic = "ZFTP";
pub const statistics_magic = "ZFTS";
pub const schema_key = "\x00zfulltext/schema";
pub const statistics_key = "\x00zfulltext/statistics";

pub const DocumentRecord = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    logical_length: u64,
    tokens: []analysis.Token,

    pub fn deinit(self: *DocumentRecord) void {
        self.allocator.free(self.text);
        for (self.tokens) |token| self.allocator.free(token.term);
        self.allocator.free(self.tokens);
        self.* = undefined;
    }
};

pub const Posting = struct {
    document_id: u64,
    positions: []u64,

    pub fn deinit(self: *Posting, allocator: std.mem.Allocator) void {
        allocator.free(self.positions);
        self.* = undefined;
    }
};

pub const CorpusStats = struct { document_count: u64, total_length: u64 };

pub const ScoringMetadata = struct {
    text_bytes: u32,
    logical_length: u32,

    pub fn encode(self: ScoringMetadata) [8]u8 {
        var value: [8]u8 = undefined;
        std.mem.writeInt(u32, value[0..4], self.text_bytes, .big);
        std.mem.writeInt(u32, value[4..8], self.logical_length, .big);
        return value;
    }

    pub fn decode(value: []const u8, max_bytes: usize) !ScoringMetadata {
        if (value.len != 8) return error.CorruptRecord;
        const text_bytes = std.mem.readInt(u32, value[0..4], .big);
        const logical_length = std.mem.readInt(u32, value[4..8], .big);
        if (text_bytes > max_bytes) return error.RecordTooLarge;
        if (logical_length > text_bytes) return error.CorruptRecord;
        return .{ .text_bytes = text_bytes, .logical_length = logical_length };
    }
};

pub fn scoringKey(document_id: u64) [9]u8 {
    return documentNamespaceKey(0x11, document_id);
}

fn documentNamespaceKey(prefix: u8, document_id: u64) [9]u8 {
    var key: [9]u8 = undefined;
    key[0] = prefix;
    std.mem.writeInt(u64, key[1..9], document_id, .big);
    return key;
}

const Writer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn writeU8(self: *Writer, value: u8) !void {
        try self.bytes.append(self.allocator, value);
    }
    fn writeU32(self: *Writer, value: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .big);
        try self.bytes.appendSlice(self.allocator, &buf);
    }
    fn writeU64(self: *Writer, value: u64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, value, .big);
        try self.bytes.appendSlice(self.allocator, &buf);
    }
    fn blob(self: *Writer, value: []const u8) !void {
        if (value.len > std.math.maxInt(u32)) return error.RecordTooLarge;
        try self.writeU32(@intCast(value.len));
        try self.bytes.appendSlice(self.allocator, value);
    }
};

const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn take(self: *Reader, count: usize) error{CorruptRecord}![]const u8 {
        if (count > self.bytes.len -| self.offset) return error.CorruptRecord;
        const result = self.bytes[self.offset .. self.offset + count];
        self.offset += count;
        return result;
    }
    fn readU8(self: *Reader) error{CorruptRecord}!u8 {
        return (try self.take(1))[0];
    }
    fn readU32(self: *Reader) error{CorruptRecord}!u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .big);
    }
    fn readU64(self: *Reader) error{CorruptRecord}!u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .big);
    }
    fn blob(self: *Reader, allocator: std.mem.Allocator, max: usize) ![]u8 {
        const n = try self.readU32();
        if (n > max) return error.RecordTooLarge;
        return try allocator.dupe(u8, try self.take(n));
    }
    fn finished(self: *const Reader) bool {
        return self.offset == self.bytes.len;
    }
};

fn expectHeader(reader: *Reader, magic: []const u8) !void {
    if (!std.mem.eql(u8, try reader.take(magic.len), magic)) return error.CorruptRecord;
    if (try reader.readU8() != format_version) return error.UnsupportedVersion;
}

pub fn encodeDocument(allocator: std.mem.Allocator, text: []const u8, tokens: []const analysis.Token, logical_length: u64) ![]u8 {
    if (tokens.len > std.math.maxInt(u32)) return error.RecordTooLarge;
    var writer: Writer = .{ .allocator = allocator };
    errdefer writer.bytes.deinit(allocator);
    try writer.bytes.appendSlice(allocator, document_magic);
    try writer.writeU8(format_version);
    try writer.writeU64(logical_length);
    try writer.blob(text);
    try analysis.validateUtf8(text);
    try writer.writeU32(@intCast(tokens.len));
    for (tokens) |token| {
        if (token.term.len == 0 or token.length == 0 or token.position > logical_length or token.length > logical_length - token.position) return error.InvalidDocument;
        try analysis.validateUtf8(token.term);
        try writer.blob(token.term);
        try writer.writeU64(token.position);
        try writer.writeU8(token.length);
    }
    return try writer.bytes.toOwnedSlice(allocator);
}

pub fn decodeDocument(allocator: std.mem.Allocator, bytes: []const u8, max_bytes: usize) !DocumentRecord {
    var reader: Reader = .{ .bytes = bytes };
    try expectHeader(&reader, document_magic);
    const logical_length = try reader.readU64();
    const text_len = try reader.readU32();
    if (text_len > max_bytes) return error.RecordTooLarge;
    const text = try allocator.dupe(u8, try reader.take(text_len));
    errdefer allocator.free(text);
    if (logical_length > text.len) return error.CorruptRecord;
    try analysis.validateUtf8(text);
    const count = try reader.readU32();
    if (count > max_bytes or count > bytes.len / 13) return error.CorruptRecord;
    const tokens = try allocator.alloc(analysis.Token, count);
    var initialized: usize = 0;
    errdefer {
        for (tokens[0..initialized]) |token| allocator.free(token.term);
        allocator.free(tokens);
    }
    var previous_position: u64 = 0;
    for (tokens) |*token| {
        const decoded = try decodeToken(allocator, &reader, max_bytes, logical_length, initialized, previous_position);
        token.* = decoded;
        previous_position = decoded.position;
        initialized += 1;
    }
    if (!reader.finished()) return error.CorruptRecord;
    return .{ .allocator = allocator, .text = text, .logical_length = logical_length, .tokens = tokens };
}

// Read the document metadata used for scoring without allocating text or tokens.
pub fn decodeDocumentLength(bytes: []const u8, max_bytes: usize) !u64 {
    return (try decodeDocumentMetadata(bytes, max_bytes)).logical_length;
}

pub fn decodeDocumentMetadata(bytes: []const u8, max_bytes: usize) !ScoringMetadata {
    var reader: Reader = .{ .bytes = bytes };
    try expectHeader(&reader, document_magic);
    const logical_length = try reader.readU64();
    const text_len = try reader.readU32();
    if (text_len > max_bytes) return error.RecordTooLarge;
    if (logical_length > text_len) return error.CorruptRecord;
    const text = try reader.take(text_len);
    try analysis.validateUtf8(text);
    const count = try reader.readU32();
    if (count > text_len or count > (bytes.len - reader.offset) / 14 or
        (logical_length == 0) != (count == 0)) return error.CorruptRecord;
    var previous_position: u64 = 0;
    for (0..count) |i| {
        const term_len = try reader.readU32();
        if (term_len == 0 or term_len > max_bytes) return error.CorruptRecord;
        const term = try reader.take(term_len);
        try analysis.validateUtf8(term);
        const position = try reader.readU64();
        const length = try reader.readU8();
        if (length == 0 or position > logical_length or length > logical_length - position or
            (i != 0 and position < previous_position)) return error.CorruptRecord;
        previous_position = position;
    }
    if (!reader.finished()) return error.CorruptRecord;
    return .{ .text_bytes = text_len, .logical_length = @intCast(logical_length) };
}

fn decodeToken(allocator: std.mem.Allocator, reader: *Reader, max_bytes: usize, logical_length: u64, initialized: usize, previous_position: u64) !analysis.Token {
    const term = try reader.blob(allocator, max_bytes);
    errdefer allocator.free(term);
    try analysis.validateUtf8(term);
    const position = try reader.readU64();
    const length = try reader.readU8();
    if (term.len == 0 or length == 0 or position > logical_length or length > logical_length - position or (initialized != 0 and position < previous_position)) return error.CorruptRecord;
    return .{ .term = term, .position = position, .length = length };
}

pub fn encodePosting(allocator: std.mem.Allocator, document_id: u64, positions: []const u64) ![]u8 {
    if (positions.len == 0 or positions.len > std.math.maxInt(u32)) return error.InvalidPosting;
    var writer: Writer = .{ .allocator = allocator };
    errdefer writer.bytes.deinit(allocator);
    try writer.bytes.appendSlice(allocator, posting_magic);
    try writer.writeU8(format_version);
    try writer.writeU64(document_id);
    try writer.writeU32(@intCast(positions.len));
    var previous: ?u64 = null;
    for (positions) |position| {
        if (previous) |last| if (position <= last) return error.InvalidPosting;
        try writer.writeU64(position);
        previous = position;
    }
    return try writer.bytes.toOwnedSlice(allocator);
}

pub fn decodePosting(allocator: std.mem.Allocator, bytes: []const u8, max_positions: usize) !Posting {
    const count = try postingPositionCount(bytes, max_positions);
    const positions = try allocator.alloc(u64, count);
    errdefer allocator.free(positions);
    return decodePostingInto(bytes, positions);
}

/// Validate a posting header and exact payload size without allocating.
pub fn postingPositionCount(bytes: []const u8, max_positions: usize) !usize {
    var reader: Reader = .{ .bytes = bytes };
    try expectHeader(&reader, posting_magic);
    _ = try reader.readU64();
    const count = try reader.readU32();
    if (count == 0 or count > max_positions or count != (bytes.len - reader.offset) / 8 or (bytes.len - reader.offset) % 8 != 0)
        return error.CorruptRecord;
    return count;
}

/// Decode into caller storage; the returned positions remain valid with that storage.
/// The caller frees the original storage, rather than calling Posting.deinit.
pub fn decodePostingInto(bytes: []const u8, positions: []u64) !Posting {
    var reader: Reader = .{ .bytes = bytes };
    try expectHeader(&reader, posting_magic);
    const document_id = try reader.readU64();
    const count = try reader.readU32();
    if (count == 0 or count != positions.len) return error.CorruptRecord;
    for (positions, 0..) |*position, i| {
        position.* = try reader.readU64();
        if (i != 0 and position.* <= positions[i - 1]) return error.CorruptRecord;
    }
    if (!reader.finished()) return error.CorruptRecord;
    return .{ .document_id = document_id, .positions = positions };
}

test "posting caller storage validates header count positions and truncation" {
    const allocator = std.testing.allocator;
    const encoded = try encodePosting(allocator, std.math.maxInt(u64), &.{ 0, 3, 127 });
    defer allocator.free(encoded);
    try std.testing.expectEqual(@as(usize, 3), try postingPositionCount(encoded, 3));
    var storage: [3]u64 = undefined;
    const posting = try decodePostingInto(encoded, &storage);
    try std.testing.expect(posting.positions.ptr == &storage);
    try std.testing.expectEqual(std.math.maxInt(u64), posting.document_id);
    try std.testing.expectEqualSlices(u64, &.{ 0, 3, 127 }, posting.positions);
    try std.testing.expectError(error.CorruptRecord, postingPositionCount(encoded, 2));
    try std.testing.expectError(error.CorruptRecord, decodePostingInto(encoded, storage[0..2]));
    for (0..encoded.len) |len| {
        try std.testing.expectError(error.CorruptRecord, postingPositionCount(encoded[0..len], 3));
        try std.testing.expectError(error.CorruptRecord, decodePostingInto(encoded[0..len], &storage));
    }
    const duplicate = try allocator.dupe(u8, encoded);
    defer allocator.free(duplicate);
    @memcpy(duplicate[duplicate.len - 8 ..], duplicate[duplicate.len - 16 ..][0..8]);
    try std.testing.expectError(error.CorruptRecord, decodePostingInto(duplicate, &storage));
    const trailing = try allocator.alloc(u8, encoded.len + 1);
    defer allocator.free(trailing);
    @memcpy(trailing[0..encoded.len], encoded);
    trailing[encoded.len] = 0;
    try std.testing.expectError(error.CorruptRecord, postingPositionCount(trailing, 3));
    try std.testing.expectError(error.CorruptRecord, decodePostingInto(trailing, &storage));
}

pub fn documentKey(allocator: std.mem.Allocator, document_id: u64) ![]u8 {
    return allocator.dupe(u8, &documentKeyBytes(document_id));
}

pub fn documentKeyBytes(document_id: u64) [9]u8 {
    return documentNamespaceKey(0x10, document_id);
}

/// Encode a term as escaped bytes, a two-byte terminator, and a big-endian ID.
pub fn postingKey(allocator: std.mem.Allocator, term: []const u8, document_id: u64) ![]u8 {
    var key: std.ArrayList(u8) = .empty;
    errdefer key.deinit(allocator);
    for (term) |byte| {
        try key.append(allocator, byte);
        if (byte == 0) try key.append(allocator, 0xff);
    }
    try key.appendSlice(allocator, &.{ 0, 0 });
    var id: [8]u8 = undefined;
    std.mem.writeInt(u64, &id, document_id, .big);
    try key.appendSlice(allocator, &id);
    return try key.toOwnedSlice(allocator);
}

pub fn postingPrefix(allocator: std.mem.Allocator, term: []const u8) ![]u8 {
    var key: std.ArrayList(u8) = .empty;
    errdefer key.deinit(allocator);
    for (term) |byte| {
        try key.append(allocator, byte);
        if (byte == 0) try key.append(allocator, 0xff);
    }
    try key.appendSlice(allocator, &.{ 0, 0 });
    return try key.toOwnedSlice(allocator);
}

pub fn encodeStats(allocator: std.mem.Allocator, stats: CorpusStats) ![]u8 {
    var writer: Writer = .{ .allocator = allocator };
    errdefer writer.bytes.deinit(allocator);
    try writer.bytes.appendSlice(allocator, statistics_magic);
    try writer.writeU8(format_version);
    try writer.writeU64(stats.document_count);
    try writer.writeU64(stats.total_length);
    return try writer.bytes.toOwnedSlice(allocator);
}

pub fn decodeStats(bytes: []const u8) !CorpusStats {
    var reader: Reader = .{ .bytes = bytes };
    try expectHeader(&reader, statistics_magic);
    const stats = CorpusStats{ .document_count = try reader.readU64(), .total_length = try reader.readU64() };
    if (!reader.finished() or (stats.document_count == 0 and stats.total_length != 0)) return error.CorruptRecord;
    return stats;
}

/// Exclusive upper bound for the bytewise range beginning with a term prefix.
pub fn prefixEnd(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    const end = try allocator.dupe(u8, prefix);
    errdefer allocator.free(end);
    var i = end.len;
    while (i > 0) {
        i -= 1;
        if (end[i] != 0xff) {
            end[i] += 1;
            return try allocator.realloc(end, i + 1);
        }
    }
    return error.NoPrefixEnd;
}

test "document round trip preserves bytes, terms, positions, and u64 extremes" {
    const tokens = [_]analysis.Token{
        .{ .term = "word", .position = 0, .length = 1 },
        .{ .term = "中", .position = 4, .length = 1 },
    };
    const encoded = try encodeDocument(std.testing.allocator, "raw text", &tokens, 5);
    defer std.testing.allocator.free(encoded);
    var decoded = try decodeDocument(std.testing.allocator, encoded, 100);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("raw text", decoded.text);
    try std.testing.expectEqual(@as(u64, 5), decoded.logical_length);
    const metadata = try decodeDocumentMetadata(encoded, 100);
    try std.testing.expectEqual(@as(u32, 8), metadata.text_bytes);
    try std.testing.expectEqual(@as(u32, 5), metadata.logical_length);
    try std.testing.expectEqual(decoded.logical_length, try decodeDocumentLength(encoded, 100));
    try std.testing.expectEqualStrings("中", decoded.tokens[1].term);
}

test "scoring metadata validates bounds and preserves unsigned IDs" {
    const value = (ScoringMetadata{ .text_bytes = 100, .logical_length = 42 }).encode();
    const decoded = try ScoringMetadata.decode(&value, 100);
    try std.testing.expectEqual(@as(u32, 42), decoded.logical_length);
    try std.testing.expectEqual(@as(u32, 100), decoded.text_bytes);
    try std.testing.expectError(error.RecordTooLarge, ScoringMetadata.decode(&value, 99));
    try std.testing.expectError(error.CorruptRecord, ScoringMetadata.decode(value[0..7], 100));
    const invalid = (ScoringMetadata{ .text_bytes = 2, .logical_length = 3 }).encode();
    try std.testing.expectError(error.CorruptRecord, ScoringMetadata.decode(&invalid, 100));
    const empty = (ScoringMetadata{ .text_bytes = 0, .logical_length = 0 }).encode();
    try std.testing.expectEqual(@as(u32, 0), (try ScoringMetadata.decode(&empty, 100)).logical_length);
    const low = scoringKey(0);
    const high = scoringKey(std.math.maxInt(u64));
    const doc = documentKeyBytes(0);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), std.mem.readInt(u64, high[1..9], .big));
    try std.testing.expect(std.mem.order(u8, &low, &high) == .lt);
    try std.testing.expect(!std.mem.eql(u8, &doc, &low));
}

test "posting encoding validates sorted positions and truncation" {
    const positions = [_]u64{ 0, 4, 9 };
    const encoded = try encodePosting(std.testing.allocator, std.math.maxInt(u64), &positions);
    defer std.testing.allocator.free(encoded);
    var decoded = try decodePosting(std.testing.allocator, encoded, 20);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.math.maxInt(u64), decoded.document_id);
    try std.testing.expectEqual(@as(u64, 9), decoded.positions[2]);
    try std.testing.expectError(error.CorruptRecord, decodePosting(std.testing.allocator, encoded[0 .. encoded.len - 1], 20));
    try std.testing.expectError(error.InvalidPosting, encodePosting(std.testing.allocator, 1, &.{ 2, 2 }));
}

test "posting keys have unambiguous zero escaping and unsigned ID order" {
    const a = try postingKey(std.testing.allocator, &.{ 'x', 0 }, 7);
    defer std.testing.allocator.free(a);
    const b = try postingKey(std.testing.allocator, &.{ 'x', 0, 0 }, 1);
    defer std.testing.allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
    const low = try postingKey(std.testing.allocator, "x", 1);
    defer std.testing.allocator.free(low);
    const high = try postingKey(std.testing.allocator, "x", std.math.maxInt(u64));
    defer std.testing.allocator.free(high);
    try std.testing.expect(std.mem.order(u8, low, high) == .lt);
    const prefix = try postingPrefix(std.testing.allocator, "x");
    defer std.testing.allocator.free(prefix);
    const end = try prefixEnd(std.testing.allocator, prefix);
    defer std.testing.allocator.free(end);
    try std.testing.expect(std.mem.order(u8, prefix, low) == .lt);
    try std.testing.expect(std.mem.order(u8, low, end) == .lt);
}

test "statistics codec and keys preserve explicit formats" {
    const encoded = try encodeStats(std.testing.allocator, .{ .document_count = 3, .total_length = 99 });
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeStats(encoded);
    try std.testing.expectEqual(@as(u64, 3), decoded.document_count);
    try std.testing.expectEqual(@as(u64, 99), decoded.total_length);
    try std.testing.expectError(error.CorruptRecord, decodeStats(encoded[0 .. encoded.len - 1]));
    const key = try documentKey(std.testing.allocator, std.math.maxInt(u64));
    defer std.testing.allocator.free(key);
    try std.testing.expectEqual(@as(usize, 9), key.len);
    try std.testing.expectEqual(@as(u8, 0x10), key[0]);
}

test "document decode rejects oversized and malformed records" {
    try std.testing.expectError(error.CorruptRecord, decodeDocument(std.testing.allocator, "ZFTD", 100));
    const tokens = [_]analysis.Token{};
    const encoded = try encodeDocument(std.testing.allocator, "text", &tokens, 0);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(error.RecordTooLarge, decodeDocument(std.testing.allocator, encoded, 2));
}

test "codec allocation failures release partial buffers" {
    const Context = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const tokens = [_]analysis.Token{.{ .term = "one", .position = 0, .length = 1 }};
            const encoded = try encodeDocument(allocator, "one", &tokens, 1);
            defer allocator.free(encoded);
            var decoded = try decodeDocument(allocator, encoded, 100);
            decoded.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
}
