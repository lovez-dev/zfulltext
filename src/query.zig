const std = @import("std");
const wiskdb = @import("wiskdb");
const analysis = @import("analysis.zig");
const codec = @import("codec.zig");
const scoring = @import("scoring.zig");
const types = @import("types.zig");

const Query = struct {
    db: *wiskdb.Db,
    options: types.SearchOptions,

    fn check(self: Query) !void {
        try checkCancel(self.db.io, self.options.cancel);
    }
};

const Term = struct {
    postings: []codec.Posting,
    storage: []codec.Posting,
    idf: f64,
};

const RankedHit = struct {
    hit: types.Hit,
    metadata: ?codec.ScoringMetadata,
};

const Cursor = struct {
    term: usize,
    row: usize,
    id: u64,

    fn order(_: void, a: Cursor, b: Cursor) std.math.Order {
        return if (a.id != b.id) std.math.order(a.id, b.id) else std.math.order(a.term, b.term);
    }
};

pub fn checkCancel(io: std.Io, cancel: ?*const types.Cancellation) !void {
    if (cancel) |flag| if (flag.isCancelled()) return error.Canceled;
    try io.checkCancel();
}

pub fn search(db: *wiskdb.Db, allocator: std.mem.Allocator, text: []const u8, options: types.SearchOptions, corpus: codec.CorpusStats, max_document_bytes: usize, has_scoring_metadata: bool) !types.SearchResult {
    const query: Query = .{ .db = db, .options = options };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const tokens = (try analysis.analyzeQuery(scratch, text)).items;
    if (tokens.len == 0) return .{ .hits = &.{}, .total = 0 };

    var by_term: std.StringHashMapUnmanaged(usize) = .empty;
    var terms: std.ArrayList(Term) = .empty;
    defer for (terms.items) |term| allocator.free(term.storage);
    const token_terms = try scratch.alloc(usize, tokens.len);
    for (tokens, token_terms) |token, *term_index| {
        const entry = try by_term.getOrPut(scratch, token.term);
        if (!entry.found_existing) {
            entry.value_ptr.* = terms.items.len;
            const list = try readPostings(query, allocator, token.term, max_document_bytes, corpus.document_count);
            if (list.items.len == 0 and options.mode != .any) {
                allocator.free(list.storage);
                return .{ .hits = &.{}, .total = 0 };
            }
            errdefer allocator.free(list.storage);
            const idf = try scoring.inverseDocumentFrequency(corpus.document_count, list.items.len);
            try terms.append(scratch, .{ .postings = list.items, .storage = list.storage, .idf = idf });
        }
        term_index.* = entry.value_ptr.*;
    }

    var pending: std.PriorityQueue(Cursor, void, Cursor.order) = .initContext({});
    if (options.mode == .any) try pending.ensureTotalCapacityPrecise(scratch, terms.items.len);
    var anchor: usize = 0;
    for (terms.items, 0..) |term, i| {
        if (options.mode == .any) {
            if (term.postings.len != 0) try pending.push(scratch, .{ .term = i, .row = 0, .id = term.postings[0].document_id });
        } else if (term.postings.len < terms.items[anchor].postings.len) anchor = i;
    }
    var candidate: std.ArrayList(Cursor) = .empty;
    try candidate.ensureTotalCapacityPrecise(scratch, terms.items.len);
    var best: std.PriorityQueue(RankedHit, void, worstFirst) = .initContext({});
    const average_length = if (corpus.document_count == 0) 0 else @as(f64, @floatFromInt(corpus.total_length)) / @as(f64, @floatFromInt(corpus.document_count));
    var total: usize = 0;
    var anchor_row: usize = 0;
    const offsets = try scratch.alloc(usize, if (options.mode != .any) terms.items.len else 0);
    @memset(offsets, 0);
    while (true) {
        try query.check();
        const id = if (options.mode == .any) (pending.peek() orelse break).id else blk: {
            const postings = terms.items[anchor].postings;
            if (anchor_row == postings.len) break;
            defer anchor_row += 1;
            break :blk postings[anchor_row].document_id;
        };
        candidate.clearRetainingCapacity();
        if (options.mode != .any) {
            // Preserve term order for phrase lookup and exact BM25 addition order.
            for (terms.items, offsets, 0..) |term, *offset, i| {
                if (i % 64 == 0) try query.check();
                if (i == anchor) {
                    offset.* = anchor_row - 1;
                } else {
                    const tail = term.postings[offset.*..];
                    if (tail.len != 0 and tail[0].document_id < id)
                        offset.* += 1 + std.sort.lowerBound(codec.Posting, tail[1..], id, comparePosting);
                    if (offset.* == term.postings.len or term.postings[offset.*].document_id != id) break;
                }
                candidate.appendAssumeCapacity(.{ .term = i, .row = offset.*, .id = id });
                offset.* += 1;
            }
        } else while (pending.peek()) |current| {
            if (current.id != id) break;
            _ = pending.pop();
            candidate.appendAssumeCapacity(current);
            const postings = terms.items[current.term].postings;
            const next = current.row + 1;
            if (next < postings.len) try pending.push(scratch, .{ .term = current.term, .row = next, .id = postings[next].document_id });
        }
        const matches = candidate.items;
        if (options.mode != .any and matches.len != terms.items.len) continue;
        if (options.mode == .phrase and !try matchesPhrase(query, tokens, token_terms, terms.items, matches)) continue;
        const metadata = if (has_scoring_metadata) try readScoringMetadata(query, id, max_document_bytes) else null;
        const length = if (metadata) |value| value.logical_length else (try readDocumentMetadata(query, id, max_document_bytes)).logical_length;
        if (length > corpus.total_length) return error.CorruptRecord;
        const hit = try scoreCandidate(query, id, length, average_length, terms.items, matches);
        total = std.math.add(usize, total, 1) catch return error.ResultCountOverflow;
        if (options.limit == 0) continue;
        if (best.count() < options.limit) {
            try best.push(scratch, .{ .hit = hit, .metadata = metadata });
        } else if (hitLessThan({}, hit, best.peek().?.hit)) {
            _ = best.pop();
            try best.push(scratch, .{ .hit = hit, .metadata = metadata });
        }
    }
    // Validate complete records only for returned hits, rather than every
    // candidate. This retains document validation on retrieval without making
    // frequent-term scoring proportional to the size of candidate bodies.
    for (best.items) |ranked| {
        try query.check();
        const document = try readDocumentMetadata(query, ranked.hit.id, max_document_bytes);
        if (ranked.metadata) |metadata| {
            if (metadata.text_bytes != document.text_bytes or metadata.logical_length != document.logical_length)
                return error.CorruptRecord;
        }
    }
    try query.check();
    const hits = try allocator.alloc(types.Hit, best.items.len);
    for (hits, best.items) |*hit, ranked| hit.* = ranked.hit;
    std.mem.sortUnstable(types.Hit, hits, {}, hitLessThan);
    return .{ .hits = hits, .total = total };
}

const PostingList = struct { items: []codec.Posting, storage: []codec.Posting };

fn readPostings(query: Query, allocator: std.mem.Allocator, term: []const u8, max_document_bytes: usize, document_count: u64) !PostingList {
    try query.check();
    const prefix = try codec.postingPrefix(allocator, term);
    defer allocator.free(prefix);
    const end = try codec.prefixEnd(allocator, prefix);
    defer allocator.free(end);
    const rows = try query.db.scan(prefix, end);
    defer query.db.freeScan(rows);
    try query.check();
    if (rows.len > document_count) return error.CorruptRecord;
    // One shared allocation holds descriptors followed by all position arrays.
    var position_count: usize = 0;
    for (rows, 0..) |row, i| {
        if (i % 64 == 0) try query.check();
        const count = try codec.postingPositionCount(row.value, max_document_bytes);
        position_count = std.math.add(usize, position_count, count) catch return error.CorruptRecord;
    }
    const position_bytes = std.math.mul(usize, position_count, @sizeOf(u64)) catch return error.CorruptRecord;
    const extra = std.math.divCeil(usize, position_bytes, @sizeOf(codec.Posting)) catch return error.CorruptRecord;
    const storage_count = std.math.add(usize, rows.len, extra) catch return error.CorruptRecord;
    const storage = try allocator.alloc(codec.Posting, storage_count);
    errdefer allocator.free(storage);
    const postings = storage[0..rows.len];
    const positions = std.mem.bytesAsSlice(u64, std.mem.sliceAsBytes(storage[rows.len..]))[0..position_count];
    var position_offset: usize = 0;
    var previous_id: ?u64 = null;
    for (rows, postings, 0..) |row, *posting, i| {
        if (i % 64 == 0) try query.check();
        if (row.key.len != prefix.len + 8 or !std.mem.startsWith(u8, row.key, prefix)) return error.CorruptRecord;
        const id = std.mem.readInt(u64, row.key[prefix.len..][0..8], .big);
        if (previous_id) |previous| if (id <= previous) return error.CorruptRecord;
        const count = try codec.postingPositionCount(row.value, max_document_bytes);
        posting.* = try codec.decodePostingInto(row.value, positions[position_offset..][0..count]);
        position_offset += count;
        if (posting.document_id != id or posting.positions[posting.positions.len - 1] >= max_document_bytes) return error.CorruptRecord;
        previous_id = id;
    }
    return .{ .items = postings, .storage = storage };
}

fn matchesPhrase(query: Query, tokens: []const analysis.Token, token_terms: []const usize, terms: []const Term, matches: []const Cursor) !bool {
    // Every term is present, in term-index order. Use the least frequent
    // occurrence list in this document as the anchor for the relative offsets.
    var anchor: usize = 0;
    for (token_terms, 0..) |term, i| {
        if (positionsFor(terms, matches[term]).len < positionsFor(terms, matches[token_terms[anchor]]).len) anchor = i;
    }
    var steps: usize = 0;
    starts: for (positionsFor(terms, matches[token_terms[anchor]])) |position| {
        if (steps % 64 == 0) try query.check();
        steps +%= 1;
        if (position < tokens[anchor].position) continue;
        const start = position - tokens[anchor].position;
        for (tokens, token_terms) |token, term| {
            if (steps % 64 == 0) try query.check();
            steps +%= 1;
            const wanted = std.math.add(u64, start, token.position) catch continue :starts;
            const positions = positionsFor(terms, matches[term]);
            const i = std.sort.lowerBound(u64, positions, wanted, comparePosition);
            if (i == positions.len or positions[i] != wanted) continue :starts;
        }
        return true;
    }
    return false;
}

fn positionsFor(terms: []const Term, cursor: Cursor) []const u64 {
    return terms[cursor.term].postings[cursor.row].positions;
}

fn comparePosting(id: u64, posting: codec.Posting) std.math.Order {
    return std.math.order(id, posting.document_id);
}

fn comparePosition(key: u64, element: u64) std.math.Order {
    return std.math.order(key, element);
}

fn readScoringMetadata(query: Query, id: u64, max_document_bytes: usize) !?codec.ScoringMetadata {
    const key = codec.scoringKey(id);
    const value = try query.db.get(&key) orelse return null;
    defer query.db.allocator.free(value);
    try query.check();
    return try codec.ScoringMetadata.decode(value, max_document_bytes);
}

fn readDocumentMetadata(query: Query, id: u64, max_document_bytes: usize) !codec.ScoringMetadata {
    const key = codec.documentKeyBytes(id);
    const value = try query.db.get(&key) orelse return error.CorruptRecord;
    defer query.db.allocator.free(value);
    try query.check();
    return codec.decodeDocumentMetadata(value, max_document_bytes);
}

fn scoreCandidate(query: Query, id: u64, length: u64, average_length: f64, terms: []const Term, matches: []const Cursor) !types.Hit {
    var score: f64 = 0;
    for (matches, 0..) |cursor, i| {
        if (i % 64 == 0) try query.check();
        const positions = positionsFor(terms, cursor);
        if (positions[positions.len - 1] >= length) return error.CorruptRecord;
        if (query.options.limit != 0) score += try scoring.bm25(terms[cursor.term].idf, positions.len, length, average_length, query.options.k1, query.options.b);
    }
    return .{ .id = id, .score = score };
}

fn hitLessThan(_: void, a: types.Hit, b: types.Hit) bool {
    return scoring.lessThan({}, .{ .id = a.id, .score = a.score }, .{ .id = b.id, .score = b.score });
}

fn worstFirst(_: void, a: RankedHit, b: RankedHit) std.math.Order {
    return if (hitLessThan({}, b.hit, a.hit)) .lt else if (hitLessThan({}, a.hit, b.hit)) .gt else .eq;
}
