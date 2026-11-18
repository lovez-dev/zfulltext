pub const Index = @import("index.zig").Index;
pub const Options = @import("types.zig").Options;
pub const MatchMode = @import("types.zig").MatchMode;
pub const SearchOptions = @import("types.zig").SearchOptions;
pub const Cancellation = @import("types.zig").Cancellation;
pub const Document = @import("types.zig").Document;
pub const Stats = @import("types.zig").Stats;
pub const Hit = @import("types.zig").Hit;
pub const SearchResult = @import("types.zig").SearchResult;
pub const analysis = @import("analysis.zig");
pub const codec = @import("codec.zig");
pub const scoring = @import("scoring.zig");

test {
    _ = @import("types.zig");
    _ = analysis;
    _ = codec;
    _ = scoring;
}
