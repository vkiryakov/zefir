//! Must compile: claims as deep as jwt.max_json_depth allows, 31 lists in
//! one another under the object of the payload.
const jwt = @import("security").jwt;

const Claims = struct {
    deep: []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const []const u32 = &.{},
};

test {
    comptime jwt.assertClaims(Claims);
}
