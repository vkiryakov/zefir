const Tree = @import("tree.zig").Tree;
const DotEnv = @import("parsers/dotenv.zig");
const Env = @import("parsers/env.zig");
const Json = @import("parsers/json.zig");

pub const ConfigSource = union(enum) {
    dotenv: []const u8,
    json_file: []const u8,
    environment,

    pub fn json(path: []const u8) ConfigSource {
        return .{ .json_file = path };
    }

    pub fn env(path: []const u8) ConfigSource {
        return .{ .dotenv = path };
    }

    pub fn os_env() ConfigSource {
        return .environment;
    }

    pub fn pase(self: ConfigSource, tree: *Tree) !void {
        switch (self) {
            .dotenv => |path| try DotEnv.parse(path, tree),
            .json_file => |path| try Json.parse(path, tree),
            .environment => try Env.load(tree),
        }
    }
};
