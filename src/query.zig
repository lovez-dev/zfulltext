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
    idf: f64,
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
    const token_terms = try scratch.alloc(usize, tokens.len);
    for (tokens, token_terms) |token, *term_index| {
        const entry = try by_term.getOrPut(scratch, token.term);
        if (!entry.found_existing) {
            entry.value_ptr.* = terms.items.len;
            const postings = try readPostings(query, scratch, token.term, max_document_bytes, corpus.document_count);
            if (postings.len == 0 and options.mode != .any) return .{ .hits = &.{}, .total = 0 };
            const idf = try scoring.inverseDocumentFrequency(corpus.document_count, postings.len);
            try terms.append(scratch, .{ .postings = postings, .idf = idf });
        }
        term_index.* = entry.value_ptr.*;
    }

    var pending: std.PriorityQueue(Cursor, void, Cursor.order) = .initContext({});
    try pending.ensureTotalCapacityPrecise(scratch, terms.items.len);
    for (terms.items, 0..) |term, i| {
        if (term.postings.len != 0) try pending.push(scratch, .{ .term = i, .row = 0, .id = term.postings[0].document_id });
    }
    var candidate: std.ArrayList(Cursor) = .empty;
    try candidate.ensureTotalCapacityPrecise(scratch, terms.items.len);
    var best: std.PriorityQueue(types.Hit, void, worstFirst) = .initContext({});
    const average_length = if (corpus.document_count == 0) 0 else @as(f64, @floatFromInt(corpus.total_length)) / @as(f64, @floatFromInt(corpus.document_count));
    var total: usize = 0;
    while (pending.peek()) |first| {
        try query.check();
        candidate.clearRetainingCapacity();
        while (pending.peek()) |current| {
            if (current.id != first.id) break;
            _ = pending.pop();
            candidate.appendAssumeCapacity(current);
            const postings = terms.items[current.term].postings;
            const next = current.row + 1;
            if (next < postings.len) try pending.push(scratch, .{ .term = current.term, .row = next, .id = postings[next].document_id });
        }
        const matches = candidate.items;
        if (options.mode != .any and matches.len != terms.items.len) continue;
        if (options.mode == .phrase and !try matchesPhrase(query, tokens, token_terms, terms.items, matches)) continue;
        const length = try readScoringLength(query, first.id, max_document_bytes, has_scoring_metadata);
        if (length > corpus.total_length) return error.CorruptRecord;
        const hit = try scoreCandidate(query, first.id, length, average_length, terms.items, matches);
        total = std.math.add(usize, total, 1) catch return error.ResultCountOverflow;
        if (options.limit == 0) continue;
        if (best.count() < options.limit) {
            try best.push(scratch, hit);
        } else if (hitLessThan({}, hit, best.peek().?)) {
            _ = best.pop();
            try best.push(scratch, hit);
        }
    }
    // Validate complete records only for returned hits, rather than every
    // candidate. This retains document validation on retrieval without making
    // frequent-term scoring proportional to the size of candidate bodies.
    for (best.items) |hit| {
        try query.check();
        const length = try readDocumentLength(query, hit.id, max_document_bytes);
        if (length != try readScoringLength(query, hit.id, max_document_bytes, has_scoring_metadata)) return error.CorruptRecord;
    }
    try query.check();
    const hits = try allocator.dupe(types.Hit, best.items);
    std.mem.sortUnstable(types.Hit, hits, {}, hitLessThan);
    return .{ .hits = hits, .total = total };
}

fn readPostings(query: Query, allocator: std.mem.Allocator, term: []const u8, max_document_bytes: usize, document_count: u64) ![]codec.Posting {
    try query.check();
    const prefix = try codec.postingPrefix(allocator, term);
    defer allocator.free(prefix);
    const end = try codec.prefixEnd(allocator, prefix);
    defer allocator.free(end);
    const rows = try query.db.scan(prefix, end);
    defer query.db.freeScan(rows);
    try query.check();
    if (rows.len > document_count) return error.CorruptRecord;
    const postings = try allocator.alloc(codec.Posting, rows.len);
    var previous_id: ?u64 = null;
    for (rows, postings, 0..) |row, *posting, i| {
        if (i % 64 == 0) try query.check();
        if (row.key.len != prefix.len + 8 or !std.mem.startsWith(u8, row.key, prefix)) return error.CorruptRecord;
        const id = std.mem.readInt(u64, row.key[prefix.len..][0..8], .big);
        if (previous_id) |previous| if (id <= previous) return error.CorruptRecord;
        posting.* = try codec.decodePosting(allocator, row.value, max_document_bytes);
        if (posting.document_id != id or posting.positions[posting.positions.len - 1] >= max_document_bytes) return error.CorruptRecord;
        previous_id = id;
    }
    return postings;
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

fn comparePosition(key: u64, element: u64) std.math.Order {
    return std.math.order(key, element);
}

fn readScoringLength(query: Query, id: u64, max_document_bytes: usize, has_scoring_metadata: bool) !u64 {
    if (has_scoring_metadata) {
        const metadata_key = codec.scoringKey(id);
        if (try query.db.get(&metadata_key)) |value| {
            defer query.db.allocator.free(value);
            try query.check();
            return (try codec.ScoringMetadata.decode(value, max_document_bytes)).logical_length;
        }
    }
    // Older documents can be read without rebuilding or rewriting the index.
    return readDocumentLength(query, id, max_document_bytes);
}

fn readDocumentLength(query: Query, id: u64, max_document_bytes: usize) !u64 {
    const key = codec.documentKeyBytes(id);
    const value = try query.db.get(&key) orelse return error.CorruptRecord;
    defer query.db.allocator.free(value);
    try query.check();
    return codec.decodeDocumentLength(value, max_document_bytes);
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

fn worstFirst(_: void, a: types.Hit, b: types.Hit) std.math.Order {
    return if (hitLessThan({}, b, a)) .lt else if (hitLessThan({}, a, b)) .gt else .eq;
}
