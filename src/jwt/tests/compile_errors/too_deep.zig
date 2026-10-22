//! Must not compile: claims that nest deeper than jwt.max_json_depth, 32
//! levels with the object of the payload, which sign could write and
//! verify would refuse: 32 lists in one another.
const jwt = @import("jwt");

const Claims = struct {
    deep: []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const u32 = &.{},
};

test {
    comptime jwt.assertClaims(Claims);
}
