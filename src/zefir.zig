//! Zefir framework. Umbrella module re-exporting all subsystems.

pub const core = @import("core");
pub const log = @import("log");
pub const confy = @import("confy");
pub const validator = @import("validator");
pub const rpc = @import("rpc");
pub const rpc_nats = @import("rpc-nats");
pub const orm = @import("orm");
pub const mongo = @import("mongo");
pub const redis = @import("redis");
pub const nats = @import("nats");
pub const http = @import("http");

test {
    @import("std").testing.refAllDecls(@This());
}

test "zefir.log writes a confy.Secret as one [REDACTED], wherever it sits" {
    const std = @import("std");
    const Config = struct {
        host: []const u8,
        password: confy.Secret,
        tokens: []const confy.Secret,
        backup: ?confy.Secret,
        db: struct { key: confy.Secret },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const logger: log.Logger = try .init(std.testing.allocator, std.testing.io, .{ .output = .{ .writer = &out.writer } });
    defer logger.deinit();
    const secret: confy.Secret = .init("s3cret");
    const tokens = [_]confy.Secret{ secret, secret };
    var config: Config = .{ .host = "db", .password = secret, .tokens = &tokens, .backup = secret, .db = .{ .key = secret } };
    _ = &config;
    logger.info("Config", .{ .config = config, .direct = secret });
    try std.testing.expect(std.mem.find(u8, out.written(), "s3cret") == null);
    try std.testing.expectStringEndsWith(out.written(), ",\"config\":{\"host\":\"db\",\"password\":\"[REDACTED]\",\"tokens\":\"[REDACTED]\"," ++
        "\"backup\":\"[REDACTED]\",\"db\":{\"key\":\"[REDACTED]\"}},\"direct\":\"[REDACTED]\"}\n");
    comptime std.debug.assert(log.isSensitive(confy.Secret));
}
