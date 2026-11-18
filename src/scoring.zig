const std = @import("std");

pub fn validateParameters(k1: f64, b: f64) error{InvalidParameters}!void {
    if (!std.math.isFinite(k1) or !std.math.isFinite(b) or k1 <= 0 or b < 0 or b > 1) return error.InvalidParameters;
}

/// Standard BM25 contribution using natural logarithms and validated corpus counts.
pub fn bm25(idf: f64, tf: u64, document_length: u64, average_length: f64, k1: f64, b: f64) error{InvalidParameters}!f64 {
    try validateParameters(k1, b);
    if (!std.math.isFinite(idf) or idf < 0 or !std.math.isFinite(average_length) or average_length < 0) return error.InvalidParameters;
    if (tf == 0 or idf == 0) return 0;
    const norm: f64 = if (average_length == 0) 1 else 1 - b + b * (@as(f64, @floatFromInt(document_length)) / average_length);
    const tf_f: f64 = @floatFromInt(tf);
    const score = if (k1 >= 1)
        idf * (tf_f * (1 + 1 / k1)) / (tf_f / k1 + norm)
    else
        idf * (tf_f * (k1 + 1)) / (tf_f + k1 * norm);
    if (!std.math.isFinite(score)) return error.InvalidParameters;
    return score;
}

pub fn inverseDocumentFrequency(document_count: u64, document_frequency: u64) error{InvalidCorpus}!f64 {
    if (document_frequency > document_count) return error.InvalidCorpus;
    if (document_count == 0 or document_frequency == 0) return 0;
    const n: f64 = @floatFromInt(document_count);
    const df: f64 = @floatFromInt(document_frequency);
    return @log(1 + (n - df + 0.5) / (df + 0.5));
}

pub const ScoredId = struct { id: u64, score: f64 };

pub fn lessThan(_: void, left: ScoredId, right: ScoredId) bool {
    if (left.score != right.score) return left.score > right.score;
    return left.id < right.id;
}

test "BM25 matches independently calculated values and boundary cases" {
    const idf = try inverseDocumentFrequency(10, 2);
    const score = try bm25(idf, 3, 5, 4, 1.2, 0.75);
    const expected = @log(1 + (10.0 - 2.0 + 0.5) / (2.0 + 0.5)) * (3.0 * 2.2) / (3.0 + 1.2 * (1 - 0.75 + 0.75 * 5.0 / 4.0));
    try std.testing.expectApproxEqRel(expected, score, 1e-12);
    try std.testing.expectEqual(@as(f64, 0), try bm25(1, 0, 10, 0, 1.2, 0.75));
    try std.testing.expectEqual(@as(f64, 0), try inverseDocumentFrequency(0, 0));
    try std.testing.expectError(error.InvalidCorpus, inverseDocumentFrequency(2, 3));
    try std.testing.expectError(error.InvalidParameters, bm25(1, 1, 1, 1, 0, 0.5));
    try std.testing.expectError(error.InvalidParameters, bm25(1, 1, 1, 1, 1, std.math.nan(f64)));
    const huge = try bm25(1, 2, 2, 2, std.math.floatMax(f64), 0);
    try std.testing.expect(std.math.isFinite(huge));
    try std.testing.expectApproxEqAbs(@as(f64, 2), huge, 1e-15);
}

test "score ordering uses ascending unsigned ID for ties" {
    const a: ScoredId = .{ .id = 1, .score = 1.5 };
    const b: ScoredId = .{ .id = std.math.maxInt(u64), .score = 1.5 };
    try std.testing.expect(lessThan({}, a, b));
    try std.testing.expect(!lessThan({}, b, a));
}
