const std = @import("std");
const builtin = @import("builtin");
const wiskdb = @import("wiskdb");
const analysis = @import("analysis.zig");
const codec = @import("codec.zig");
const types = @import("types.zig");
const query = @import("query.zig");
const scoring = @import("scoring.zig");

const schema_magic = "ZFTI";
const analyzer_version: u8 = 1;
const legacy_schema = schema_magic ++ &[_]u8{ 1, analyzer_version };
const schema = schema_magic ++ &[_]u8{ 2, analyzer_version };
const bootstrap_marker_name = ".zfulltext-init";
const bootstrap_marker = "zfulltext bootstrap v1";
const max_document_bytes = 1024 * 1024;
const max_query_bytes = 16 * 1024;
const max_result_count = 10_000;

// Pinned wiskdb WAL batch encoding: 12-byte batch header, 28-byte op header,
// and values at or above the configured threshold stored out of line.
const batch_capacity = 2 * 1024 * 1024;
const value_threshold = 512;

pub const Index = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    db: wiskdb.Db,
    options: types.Options,
    lock: std.Io.RwLock = .init,
    corpus: codec.CorpusStats = .{ .document_count = 0, .total_length = 0 },
    closed: bool = false,
    poisoned: bool = false,
    has_scoring_metadata: bool = true,

    pub const testing = if (builtin.is_test) struct {
        pub fn failBootstrap(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*Index {
            return openImpl(allocator, io, path, .{ .create_if_missing = true }, true);
        }
        pub fn upsertWithAllocator(index: *Index, allocator: std.mem.Allocator, id: u64, text: []const u8) !void {
            _ = try index.mutateWithAllocator(allocator, id, text);
        }
    } else struct {};

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8, options: types.Options) !*Index {
        return openImpl(allocator, io, path, options, false);
    }

    fn openImpl(allocator: std.mem.Allocator, io: std.Io, path: []const u8, options: types.Options, comptime fail_bootstrap: bool) !*Index {
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null or
            options.max_document_bytes == 0 or options.max_document_bytes > max_document_bytes or
            options.max_query_bytes == 0 or options.max_query_bytes > max_query_bytes or
            options.max_result_count == 0 or options.max_result_count > max_result_count)
            return error.InvalidOptions;

        const self = try allocator.create(Index);
        errdefer allocator.destroy(self);
        const cwd = std.Io.Dir.cwd();
        const dir = cwd.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => if (options.create_if_missing)
                try cwd.createDirPathOpen(io, path, .{ .open_options = .{ .iterate = true } })
            else
                return err,
            else => return err,
        };
        errdefer dir.close(io);

        // Recover a marked directory only when every other entry is a known
        // artifact that the pinned wiskdb creates during a fresh open.
        var entries = dir.iterate();
        var has_other_entries = false;
        var has_unrelated_entries = false;
        var bootstrap = false;
        while (try entries.next(io)) |entry| {
            if (std.mem.eql(u8, entry.name, bootstrap_marker_name)) {
                if (entry.kind != .file) return error.CorruptRecord;
                try checkBootstrapMarker(dir, io);
                bootstrap = true;
            } else {
                has_other_entries = true;
                if (!isBootstrapArtifact(entry.name, entry.kind)) has_unrelated_entries = true;
            }
        }
        if (bootstrap and has_unrelated_entries) return error.NotAnIndex;
        if (has_other_entries) {
            // A missing CURRENT would let wiskdb initialize over these files.
            try checkManifest(dir, io);
        } else {
            if (!options.create_if_missing) return error.NotAnIndex;
            if (!bootstrap) try createBootstrapMarker(dir, io);
            _ = try wiskdb.syncDirectory(dir, io);
            bootstrap = true;
        }

        self.* = .{
            .allocator = allocator,
            .io = io,
            .dir = dir,
            .options = options,
            .db = try wiskdb.Db.open(allocator, io, dir, .{
                .durability = options.durability,
                .value_threshold = value_threshold,
            }),
        };
        errdefer self.db.deinit();
        try self.loadSchema(bootstrap and options.create_if_missing, fail_bootstrap);
        if (bootstrap) {
            // Persist the schema before dropping the marker, while holding the DB lock.
            try self.db.sync();
            try dir.deleteFile(io, bootstrap_marker_name);
            _ = try wiskdb.syncDirectory(dir, io);
        }
        return self;
    }

    fn isBootstrapArtifact(name: []const u8, kind: std.Io.File.Kind) bool {
        const manifest_prefix = "MANIFEST-";
        if (std.mem.startsWith(u8, name, manifest_prefix)) {
            const number = name[manifest_prefix.len..];
            if (kind != .file or number.len == 0) return false;
            for (number) |digit| if (!std.ascii.isDigit(digit)) return false;
            _ = std.fmt.parseInt(u64, number, 10) catch return false;
            return true;
        }
        if (std.mem.eql(u8, name, "CURRENT") or std.mem.eql(u8, name, "LOCK")) return kind == .file;
        if (std.mem.eql(u8, name, "WAL") or std.mem.eql(u8, name, "SST") or std.mem.eql(u8, name, "VLOG")) return kind == .directory;
        return false;
    }

    fn createBootstrapMarker(dir: std.Io.Dir, io: std.Io) !void {
        var marker = try dir.createFileAtomic(io, bootstrap_marker_name, .{});
        defer marker.deinit(io);
        try marker.file.writeStreamingAll(io, bootstrap_marker);
        try marker.file.sync(io);
        try marker.link(io);
    }

    fn checkBootstrapMarker(dir: std.Io.Dir, io: std.Io) !void {
        const file = try dir.openFile(io, bootstrap_marker_name, .{ .allow_directory = false, .follow_symlinks = false });
        defer file.close(io);
        var buffer: [bootstrap_marker.len + 1]u8 = undefined;
        const len = try file.readPositionalAll(io, &buffer, 0);
        if (!std.mem.eql(u8, buffer[0..len], bootstrap_marker)) return error.CorruptRecord;
    }

    fn checkManifest(dir: std.Io.Dir, io: std.Io) !void {
        const current = dir.statFile(io, "CURRENT", .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return error.NotAnIndex,
            else => return err,
        };
        if (current.kind != .file) return error.NotAnIndex;
        var buffer: [4097]u8 = undefined;
        const bytes = try dir.readFile(io, "CURRENT", &buffer);
        if (bytes.len == buffer.len) return error.CorruptRecord;
        const name = std.mem.trim(u8, bytes, " \t\r\n");
        const prefix = "MANIFEST-";
        if (!std.mem.startsWith(u8, name, prefix) or name.len == prefix.len) return error.CorruptRecord;
        // A missing manifest can make wiskdb initialize a fresh store.
        for (name[prefix.len..]) |c| if (!std.ascii.isDigit(c)) return error.CorruptRecord;
        _ = std.fmt.parseInt(u64, name[prefix.len..], 10) catch return error.CorruptRecord;
        var entries = dir.iterate();
        var has_manifest = false;
        while (try entries.next(io)) |entry| {
            if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "MANIFEST-")) {
                has_manifest = true;
                break;
            }
        }
        if (!has_manifest) return error.CorruptRecord;
        const manifest = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return error.CorruptRecord,
            else => return err,
        };
        if (manifest.kind != .file or manifest.size == 0) return error.CorruptRecord;
    }

    fn loadSchema(self: *Index, initialize: bool, comptime fail_bootstrap: bool) !void {
        if (try self.db.get(codec.schema_key)) |header| {
            defer self.db.allocator.free(header);
            if (header.len != schema.len or !std.mem.startsWith(u8, header, schema_magic)) return error.CorruptRecord;
            self.has_scoring_metadata = std.mem.eql(u8, header, schema);
            if (!self.has_scoring_metadata and !std.mem.eql(u8, header, legacy_schema)) return error.UnsupportedVersion;
            const value = try self.db.get(codec.statistics_key) orelse return error.CorruptRecord;
            defer self.db.allocator.free(value);
            self.corpus = try codec.decodeStats(value);
        } else {
            if (!initialize) return error.NotAnIndex;
            const entries = try self.db.scanWithOptions(.{ .limit = 1 });
            defer self.db.freeScan(entries);
            if (entries.len != 0) return error.NotAnIndex;
            if (builtin.is_test and fail_bootstrap) return error.OutOfMemory;
            const value = try codec.encodeStats(self.allocator, self.corpus);
            defer self.allocator.free(value);
            try self.db.writeBatch(&.{
                .{ .put = .{ .key = codec.schema_key, .value = schema } },
                .{ .put = .{ .key = codec.statistics_key, .value = value } },
            });
        }
    }

    pub fn close(self: *Index) !void {
        if (self.closed) return;
        self.closed = true;
        defer self.dir.close(self.io);
        try self.db.close();
    }

    pub fn deinit(self: *Index) void {
        self.close() catch {};
        self.allocator.destroy(self);
    }

    pub fn upsert(self: *Index, id: u64, text: []const u8) !void {
        _ = try self.mutate(id, text);
    }

    pub fn delete(self: *Index, id: u64) !bool {
        return self.mutate(id, null);
    }

    pub fn get(self: *Index, allocator: std.mem.Allocator, id: u64) !?types.Document {
        try self.lock.lockShared(self.io);
        defer self.lock.unlockShared(self.io);
        try self.checkUsable();
        var record = (try self.readDocument(allocator, id, self.options.max_document_bytes)) orelse return null;
        const text = record.text;
        record.text = &.{};
        record.deinit();
        return .{ .id = id, .text = text };
    }

    pub fn stats(self: *Index) !types.Stats {
        try self.lock.lockShared(self.io);
        defer self.lock.unlockShared(self.io);
        try self.checkUsable();
        return .{ .document_count = self.corpus.document_count, .total_length = self.corpus.total_length };
    }

    pub fn search(self: *Index, allocator: std.mem.Allocator, text: []const u8, options: types.SearchOptions) !types.SearchResult {
        try query.checkCancel(self.io, options.cancel);
        try self.lock.lockShared(self.io);
        defer self.lock.unlockShared(self.io);
        try query.checkCancel(self.io, options.cancel);
        try self.checkUsable();
        if (text.len > self.options.max_query_bytes) return error.QueryTooLarge;
        if (options.limit > self.options.max_result_count) return error.InvalidLimit;
        try scoring.validateParameters(options.k1, options.b);
        return query.search(&self.db, allocator, text, options, self.corpus, self.options.max_document_bytes, self.has_scoring_metadata);
    }

    fn checkUsable(self: *const Index) !void {
        if (self.closed) return error.IndexClosed;
        if (self.poisoned) return error.IndexPoisoned;
    }

    fn readDocument(self: *Index, allocator: std.mem.Allocator, id: u64, max_bytes: usize) !?codec.DocumentRecord {
        const key = try codec.documentKey(allocator, id);
        defer allocator.free(key);
        return self.readDocumentKey(allocator, key, max_bytes);
    }

    fn readDocumentKey(self: *Index, allocator: std.mem.Allocator, key: []const u8, max_bytes: usize) !?codec.DocumentRecord {
        const value = try self.db.get(key) orelse return null;
        defer self.db.allocator.free(value);
        return try codec.decodeDocument(allocator, value, max_bytes);
    }

    fn mutate(self: *Index, id: u64, text: ?[]const u8) !bool {
        return self.mutateWithAllocator(self.allocator, id, text);
    }

    fn mutateWithAllocator(self: *Index, scratch_allocator: std.mem.Allocator, id: u64, text: ?[]const u8) !bool {
        try self.lock.lock(self.io);
        defer self.lock.unlock(self.io);
        try self.checkUsable();
        if (text) |value| if (value.len > self.options.max_document_bytes) return error.DocumentTooLarge;

        var arena = std.heap.ArenaAllocator.init(scratch_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const key = try codec.documentKey(allocator, id);
        const previous = try self.readDocumentKey(allocator, key, self.options.max_document_bytes);
        if (previous == null and text == null) return false;

        var next = self.corpus;
        if (previous) |record| {
            if (next.document_count == 0 or next.total_length < record.logical_length) return error.CorruptRecord;
            next.document_count -= 1;
            next.total_length -= record.logical_length;
        }
        var batch: Batch = .{};
        // Publish the new schema in the same batch to exclude older writers
        // that would update documents without maintaining their scoring metadata.
        const upgrade_schema = !self.has_scoring_metadata and text != null;
        if (upgrade_schema) try batch.add(allocator, .{ .put = .{ .key = codec.schema_key, .value = schema } });
        const scoring_key = codec.scoringKey(id);
        var metadata: [8]u8 = undefined;
        var new_tokens: []analysis.Token = &.{};
        if (text) |value| {
            const analyzed = try analysis.analyzeDocument(allocator, value);
            new_tokens = analyzed.items;
            next.document_count = std.math.add(u64, next.document_count, 1) catch return error.CorpusTooLarge;
            next.total_length = std.math.add(u64, next.total_length, analyzed.logical_length) catch return error.CorpusTooLarge;
            const encoded = try codec.encodeDocument(allocator, value, new_tokens, analyzed.logical_length);
            try batch.add(allocator, .{ .put = .{ .key = key, .value = encoded } });
            metadata = (codec.ScoringMetadata{
                .text_bytes = @intCast(value.len),
                .logical_length = @intCast(analyzed.logical_length),
            }).encode();
            try batch.add(allocator, .{ .put = .{ .key = &scoring_key, .value = &metadata } });
        } else {
            try batch.add(allocator, .{ .del = key });
            if (self.has_scoring_metadata) try batch.add(allocator, .{ .del = &scoring_key });
        }
        std.mem.sortUnstable(analysis.Token, new_tokens, {}, tokenLessThan);
        const old_tokens: []analysis.Token = if (previous) |record| record.tokens else &.{};
        std.mem.sortUnstable(analysis.Token, old_tokens, {}, tokenLessThan);
        try updatePostings(allocator, &batch, id, old_tokens, new_tokens);
        const encoded_stats = try codec.encodeStats(allocator, next);
        try batch.add(allocator, .{ .put = .{ .key = codec.statistics_key, .value = encoded_stats } });

        self.db.writeBatch(batch.ops.items) catch |err| {
            // An error can be returned after publication, including during sync.
            self.poisoned = true;
            return err;
        };
        self.corpus = next;
        self.has_scoring_metadata = self.has_scoring_metadata or upgrade_schema;
        return previous != null;
    }
};

const Batch = struct {
    ops: std.ArrayList(wiskdb.Op) = .empty,
    encoded_len: usize = 12,

    fn add(self: *Batch, allocator: std.mem.Allocator, op: wiskdb.Op) !void {
        const size = 28 + switch (op) {
            .del => |key| key.len,
            .put => |put| put.key.len + if (put.value.len < value_threshold) put.value.len else @as(usize, 0),
        };
        if (size > batch_capacity - self.encoded_len) return error.BatchTooLarge;
        try self.ops.append(allocator, op);
        self.encoded_len += size;
    }
};

fn tokenLessThan(_: void, a: analysis.Token, b: analysis.Token) bool {
    return switch (std.mem.order(u8, a.term, b.term)) {
        .lt => true,
        .eq => a.position < b.position,
        .gt => false,
    };
}

fn termEnd(tokens: []const analysis.Token, start: usize) usize {
    var end = start + 1;
    while (end < tokens.len and std.mem.eql(u8, tokens[start].term, tokens[end].term)) : (end += 1) {}
    return end;
}

fn updatePostings(allocator: std.mem.Allocator, batch: *Batch, id: u64, old: []const analysis.Token, new: []const analysis.Token) !void {
    var old_start: usize = 0;
    var new_start: usize = 0;
    while (old_start < old.len or new_start < new.len) {
        const order: std.math.Order = if (old_start == old.len) .gt else if (new_start == new.len) .lt else std.mem.order(u8, old[old_start].term, new[new_start].term);
        if (order == .lt) {
            try batch.add(allocator, .{ .del = try codec.postingKey(allocator, old[old_start].term, id) });
        }
        if (order != .lt) {
            const end = termEnd(new, new_start);
            const positions = try allocator.alloc(u64, end - new_start);
            for (positions, new[new_start..end]) |*position, token| position.* = token.position;
            const key = try codec.postingKey(allocator, new[new_start].term, id);
            const value = try codec.encodePosting(allocator, id, positions);
            try batch.add(allocator, .{ .put = .{ .key = key, .value = value } });
            new_start = end;
        }
        if (order != .gt) old_start = termEnd(old, old_start);
    }
}
