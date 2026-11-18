# zfulltext

A small Zig library for persistent, local full-text search. Each index uses its own wiskdb directory and supports atomic document updates, all/any/phrase queries, deterministic BM25 ranking, bounded top results, cancellation, and English/CJK tokenization. The first release stores one searchable text field per document.

## Installation

Use Zig 0.17.1. For a local checkout, add this entry to `.dependencies` in your application's `build.zig.zon`, using a path relative to that manifest:

```zig
.zfulltext = .{ .path = "../zfulltext" },
```

Import the package module in your application's `build.zig`:

```zig
const zfulltext = b.dependency("zfulltext", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zfulltext", zfulltext.module("zfulltext"));
```

The library uses pinned wiskdb at runtime. zfulltext's own zlap dependency is only enabled by `zig build bench -Dbench=true`; the pinned wiskdb package may still resolve zlap as a transitive build dependency.

New indexes store compact scoring metadata. Older layout-1 indexes remain readable, and their first successful upsert upgrades the layout atomically; older binaries then cannot reopen the index. Legacy documents gain the faster scoring path when upserted. See [index compatibility](docs/api.md#package-and-lifecycle).

## Usage

See [`examples/basic.zig`](examples/basic.zig) for a runnable create/insert/query/update/delete/get/cleanup flow. From the repository root run `zig build example`. A minimal use looks like:

```zig
const index = try zfulltext.Index.open(allocator, io, "data/search-index", .{ .create_if_missing = true });
defer index.deinit();
try index.upsert(1, "English and 中文 text");
var result = try index.search(allocator, "中文", .{});
defer result.deinit(allocator);
try index.close();
```

Keep the allocator and I/O context alive as long as the index. Finish all calls before close/deinit. Search returns owned hit arrays; get returns owned document text. Configure document, query, and retained-hit limits with `Options` / `SearchOptions`. Read [the API contract](docs/api.md) for errors, limits, lifecycle, analysis, and BM25 behavior.

## License

MIT. See [`LICENSE`](LICENSE).
