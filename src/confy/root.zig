//! zefir-confy — configuration.

const std = @import("std");

const ConfyErrors = @import("errors.zig").ConfyErrors;
const ConfigSource = @import("source.zig").ConfigSource;

pub const Options = struct { sources: []const ConfigSource };

pub fn load(allocator: std.mem.Allocator, config: anytype, options: Options) ConfyErrors!void {
    // Check config, it must be pointer
    const T = ConfigType(@TypeOf(config));
    _ = T;
    _ = allocator;
    _ = options;
}

fn ConfigType(comptime CfgPtr: type) type {
    const info = @typeInfo(CfgPtr);
    if (info != .pointer or
        info.pointer.size != .one or
        info.pointer.is_const or
        @typeInfo(info.pointer.child) != .@"struct")
    {
        @compileError("Congy.load: expected a mutable pointer to a struct, like &config, got " ++ @typeName(CfgPtr));
    }

    return info.pointer.child;
}

test "confy placeholder" {
    const TestAppCfg = struct { port: u16 };
    var app_cfg: TestAppCfg = .{ .port = 3040 };
    const allocator = std.testing.allocator;
    const buf = try allocator.alloc(u8, 10);
    defer allocator.free(buf);

    try load(allocator, &app_cfg, .{ .sources = &.{
        .json("dev.json"),
        .json("local.json"),
        .env(".env"),
        .os_env(),
    } });
    try std.testing.expect(true);
}

test "ConfigType will return the struct type" {
    const ConfigTest = struct { port: u16 };
    const cfg: ConfigTest = undefined;

    const T = @TypeOf(&cfg);
    const t_info = @typeInfo(T);

    std.debug.print("{}\n", .{t_info});

    //try std.testing.expect(ConfigType()))
}
