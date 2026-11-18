# API

This document defines the implementation contract. Public names below must compile in the example and public API tests. Keep this document synchronized with implemented behavior.

## Package and lifecycle

Import `@import("zfulltext")`. `Index.open(allocator, io, path, options) !*Index` opens a dedicated wiskdb index. Set `create_if_missing` (false by default) to initialize a missing or empty directory or retry an interrupted initialization. A retry can create a missing schema only when the original bootstrap marker is valid, only expected storage artifacts are present, and wiskdb has no application records. If any storage artifacts exist, `CURRENT` and its referenced manifest must be valid. Unrelated or corrupt state is rejected, not reset. Do not modify the index directory externally or race initial opens of the same path; an already open index holds wiskdb's exclusive directory lock.

`Options` includes `durability: wiskdb.Durability = .sync` and positive `max_document_bytes` / `max_query_bytes` limits (default 1 MiB / 16 KiB). The schema and analyzer version are persisted and validated on every open. New indexes use layout 2 with compact per-document scoring metadata. Layout 1 indexes remain readable; their first successful upsert atomically upgrades the layout, and older binaries then reject the index. Existing documents use the original scoring path until upserted; opening an old index alone does not accelerate those documents. There is no automatic bulk migration.

`close(self) !void` finishes persistence and closes storage; calling it again succeeds. Closed indexes reject data operations. `deinit(self) void` releases the stable Index allocation and any remaining resources; call exactly once, after all concurrent callers have finished, even if close failed. `defer index.deinit(); try index.close();` is the standard pattern. Database errors that leave the acknowledged state uncertain cause subsequent data calls to fail until close/reopen. No concurrent close/deinit is supported.

Allocator and I/O context must outlive the index and permit concurrent activity by wiskdb callers/background workers. Input slices are borrowed only until a method returns. The database is not exposed for direct mutation.

## Documents

- `upsert(self, id: u64, text: []const u8) !void`: insert or atomically replace a document and its postings/statistics. All u64 IDs are valid. Empty text is a valid document of zero logical length.
- `delete(self, id: u64) !bool`: delete a document and its postings/statistics; return false if absent.
- `get(self, allocator, id: u64) !?Document`: return an owned `Document { id: u64, text: []const u8 }`. Release with `document.deinit(allocator)`.
- `stats(self) !Stats`: `Stats { document_count: u64, total_length: u64 }`, consistent at the call's read point.

The first format uses one searchable text field per document. Callers can compose their own IDs and store external application metadata separately; cross-database atomicity is not provided.

## Search

`search(self, allocator, query: []const u8, options: SearchOptions) !SearchResult` returns owned `hits: []Hit` and `total: usize`, where `Hit { id: u64, score: f64 }`. `total` counts all matches before truncation. Release with `result.deinit(allocator)`.

SearchOptions fields:

- `mode: MatchMode = .all`, where MatchMode is `enum { all, any, phrase }`.
- `limit: usize = 10`: retained hits, bounded by a documented hard maximum; zero is a valid count-only query.
- `k1: f64 = 1.2`, `b: f64 = 0.75`: finite BM25 parameters with k1 > 0 and 0 <= b <= 1. Reject invalid values.
- `cancel: ?*const Cancellation = null`: optional caller-owned cooperative cancellation flag.

Cancellation starts clear, supports `cancel()`, and remains alive until search returns. Return error.Canceled when observed. Check cancellation at entry, after acquiring locks, and periodically while processing postings/candidates. Blocking wiskdb calls may delay observation; no hard deadline is promised. Integrate native std.Io cancellation where supported without undermining atomic writes.

All searches observe one logical state across terms and corpus statistics. All mode requires every distinct analyzed query term. Any mode requires at least one. Phrase mode requires the query's relative positions, including repeated terms, and ranks qualifying documents using the same BM25 terms. Empty/separator-only queries return zero matches. Sort by descending score with ascending ID as tie-breaker.

## Analysis

Documents emit normalized ASCII word tokens and Han unigram/bigram tokens. Query Han runs of two or more characters use bigrams, while a single Han character uses a unigram. Document length counts ASCII words and Unicode token units rather than the number of emitted grams. Preserve relative logical positions across ASCII/Han transitions. Invalid UTF-8 fails. ASCII case folding is deterministic. Full Unicode normalization/case folding and dictionary-based segmentation are outside this format.

The analyzer treats ASCII letters and digits as word characters and lowercases ASCII uppercase letters. Han includes the CJK Unified Ideographs and extensions recognized by the implementation. Han runs create one single-character document token per logical character and each adjacent two-character gram; query runs create only adjacent bigrams unless the run is one character. Whitespace, ASCII punctuation, Unicode space, and the common Unicode punctuation blocks are separators. Other non-ASCII, non-Han codepoints are conservatively emitted as one token each. They are neither normalized nor case-folded. A logical position advances once per ASCII word or non-Han/Han character, and bigram positions begin at the first character's position.

The low-level `analysis.analyzeDocument` and `analysis.analyzeQuery` results own each term string and their token slice; call `Tokens.deinit()`. `codec` functions allocate returned buffers with the supplied allocator. `scoring.bm25` and `scoring.inverseDocumentFrequency` are pure calculations; the caller supplies validated corpus values.

## Limits and errors

Set explicit limits for document bytes, query bytes, and result count. The implementation caps configured document/query/result limits at 1 MiB / 16 KiB / 10,000. Additionally reject a document replacement whose encoded atomic write exceeds wiskdb's batch capacity. Do not silently split a document mutation across batches. Resource allocation failures are propagated, and every partial allocation is cleaned. Malformed persisted records return a corruption/format error when read. Search validates postings, compact scoring metadata, and complete document records for the returned hits. Bodies of other candidates with metadata are not read. `get` validates complete document records, including UTF-8. Legacy documents without scoring metadata use complete document validation during scoring. Opening an incompatible schema returns an explicit version error.

The sync default uses wiskdb's sync acknowledgment. Weaker durability modes inherit wiskdb's documented crash-loss behavior. Namespace durability depends on the platform's directory-sync support; no universal power-loss guarantee is made. Finish callers before close. Persistent files belong to wiskdb; do not edit them externally.

## Installation and use

Build with Zig 0.17.1. Export one zfulltext module from build.zig. Runtime dependency: wiskdb; benchmark-only dependency: zlap. Enable the optional benchmark with `zig build bench -Dbench=true`; the runnable example is `zig build example`. Consumer installation instructions and complete cleanup are shown in README.md.
