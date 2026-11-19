# Architecture

zfulltext is an embedded full-text search library. Applications supply an allocator and a Zig `std.Io` backend. wiskdb owns persistence; zfulltext owns analysis, index consistency, retrieval, and scoring. mox and zlap are consumers rather than runtime dependencies of the search API.

## Boundaries

- `src/root.zig`: supported package exports.
- `src/types.zig`: options, result types, cancellation, and resource contracts.
- `src/analysis.zig`: UTF-8 validation, ASCII normalization, document/query token streams, and logical positions.
- `src/codec.zig`: versioned binary records, collision-free key encoding, and defensive decoding.
- `src/scoring.zig`: BM25 calculation and deterministic ordering.
- `src/index.zig`: stable database allocation, mutation/read locking, atomic document replacement, and lifecycle.
- `src/query.zig`: shortest-list intersections for all/phrase queries, ordered posting union for any queries, positional phrase verification, BM25 candidate scoring, cancellation, and bounded Top-K selection. Index owns storage and consistent locking; query owns analyzed query terms and reads a consistent posting snapshot under the Index lock.
- `tests/`: public API, persistence, consistency, failure, and differential tests.
- `examples/basic.zig`: complete runnable consumer, including all cleanup.
- `bench/main.zig`: zlap benchmarks with deterministic runtime workloads.
- `docs/api.md`: public API and behavioral/lifecycle constraints.

Posting scans still materialize the complete range in wiskdb. Query decoding uses one caller-owned allocation per term for posting descriptors and positions; it releases these buffers before returning. Top-K entries retain the metadata already read for scoring and compare it against complete document records without a second metadata lookup. The query-wide read lock keeps both reads in one logical index state.

No generic storage abstraction, plugin framework, custom thread pool, RPC service, or distributed protocol is required. No Groonga source is copied or translated.

## Index layout

Each index uses its own wiskdb directory. Namespace keys separate schema/configuration, corpus statistics, documents, scoring metadata, and postings. Posting keys have a collision-free encoded term prefix followed by an unsigned 64-bit big-endian document ID. Range bounds must handle the full byte alphabet and ID range without accidental overlap.

A posting represents one term in one document and stores its occurrence count and sorted positions. Repeating a token never creates duplicate document postings. Document records keep text plus analyzed metadata used to remove their postings without changing the analyzer. Statistics store live document count and total logical document length. Values use a checked, versioned binary codec; truncated, overflowing, inconsistent, or unknown formats return errors rather than panic. The namespace schema header records the storage-layout and analyzer versions independently of the unchanged record-codec version. Layout 2 adds scoring metadata under a `0x11` prefix followed by a big-endian document ID. The eight-byte value contains big-endian `u32` text-byte and logical-length fields. This stays inline in storage so BM25 does not fetch or parse complete document records. Bounds and corpus/posting consistency are validated on reads.

Layout 1 remains readable without rewriting data. Its first successful upsert publishes layout 2 in the same atomic batch as the document and metadata, preventing older binaries from writing stale metadata. Layout 2 can contain legacy documents without metadata; search falls back to validated document decoding for those IDs. Upsert refreshes metadata and delete removes it. Unknown layouts fail explicitly. Search validates the records it reads, then validates complete documents for the returned Top-K and checks that their text-byte counts and logical lengths agree with any scoring metadata. Other candidate bodies are not read when metadata is present. `get` continues to validate the complete document record, including UTF-8.

One writer computes the full document replacement while holding the exclusive index lock, then sends document, scoring metadata, posting deletions/insertions, and corpus statistics in one wiskdb writeBatch. Publish in-memory statistics only after a successful write. Failures that may follow persistence must poison further use or otherwise reconcile state; never assume an error proves no write occurred. Oversized documents/batches fail explicitly. Delete of an absent document is a no-op.

The initial schema and statistics are written in one batch. An exclusive, versioned bootstrap marker is synced and published before opening fresh storage. A valid marker permits retry after wiskdb creates a valid manifest but before the schema batch commits, provided no unrelated files or application records are present. The schema is synced before marker removal. This recovery path does not recreate a missing manifest in a non-empty directory.

## Query consistency

Every search holds a shared index lock across all posting reads, document lengths, and statistics. Writers hold the exclusive lock. All index changes must use this instance; the underlying database is not exposed for writes. This supplies query-level consistency although wiskdb captures a fresh snapshot for each get/scan call. Results contain owned ID/score pairs and are independent after return.

Initial posting scans materialize data. Top-K retained hits are bounded, but candidate processing and posting buffers are not bounded by K. Document this distinction and cap document/query sizes and result limits. Measure frequent-term scans and write waiting before adding a stable wiskdb read view, streaming cursor, block compression, skip lists, or WAND.

## Text and ranking

ASCII letters are lowercased and ASCII letters/digits form words. Han runs emit single characters and adjacent bigrams for documents; queries prefer bigrams within runs and use a unigram for a one-character run. See [API: Analysis](api.md#analysis) for separators and non-Han tokenization. Token positions count logical units: ASCII words and Unicode characters. Query token offsets are preserved for phrase verification. Whitespace and punctuation separate runs. No NFC/NFKC, stemming, language dictionaries, or full Unicode case folding is promised.

All/any/phrase query modes are structured options rather than a textual query language. Empty or separator-only queries return no matches. Ranking uses BM25 with live corpus statistics and per-document logical length; duplicate query terms do not accidentally multiply scores. Phrase candidates must satisfy relative positions, including repeated terms. Results sort by descending score, then ascending document ID.

## Runtime and integration

Index and its database stay at a stable address. The allocator and std.Io backend outlive the index and support concurrent database/background activity. Each query uses its caller allocator, which must support that call's allocations; returned values describe their release method. Finish all calls before close/deinit. Cancellation is cooperative and never publishes a partial document.

A mox handler runs on its event-loop thread. An application can submit search/index operations to a bounded worker facility and return results through the owning loop. Keep job input/result buffers alive until completion or acknowledged cancellation, and drain jobs before closing the index. A production HTTP adapter and a second I/O runtime are outside this library's initial scope.

## Development

Use the toolchain in .zigversion. Dependencies are pinned to exact commits and package hashes: wiskdb 5527ac12984826fae9eb800d5508f40e09ca2769 and zlap a5a8149c80900eab4058c570c1bc9c63a54ae68b.

Run `zig build check`, `zig build test`, `zig build example`, or `zig build bench -Dbench=true`. Tests check persistence through a real wiskdb directory, compare search and mutations against an independent ASCII model, and verify that search scores are consistent while a writer replaces a document. The benchmark measures analysis, document codec round trips, and search over a prebuilt corpus. Corpus setup is excluded from timed reads, and zlap's batch-average percentiles are not individual-request tail latencies. Tests, the example, and benchmarks create isolated working directories under `out/` and clean them up after closing the index.
