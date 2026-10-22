//! Zefir framework. Umbrella module re-exporting all subsystems.

pub const core = @import("core");
pub const log = @import("log");
pub const confy = @import("confy");
pub const validator = @import("validator");
pub const rpc = @import("rpc");
pub const rpc_nats = @import("rpc-nats");
pub const mongo_bson = @import("mongo-bson");
pub const odm = @import("odm");
pub const mongo = @import("mongo");
pub const nats = @import("nats");
pub const http = @import("http");
pub const jwt = @import("jwt");

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

test "zefir.log writes a jwt.Key and a jwt.SigningKey as [REDACTED]" {
    const std = @import("std");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const logger: log.Logger = try .init(std.testing.allocator, std.testing.io, .{ .output = .{ .writer = &out.writer } });
    defer logger.deinit();
    var signing_key: jwt.SigningKey = try .hmac(.HS256, "SECRET-SECRET-SECRET-SECRET-SECRET!", .{ .id = "2026-10" });
    defer signing_key.deinit();
    var key = signing_key.verificationKey();
    defer key.deinit();
    logger.info("Keys", .{ .key = key, .signing_key = signing_key });
    try std.testing.expect(std.mem.find(u8, out.written(), "SECRET") == null);
    try std.testing.expectStringEndsWith(out.written(), ",\"key\":\"[REDACTED]\",\"signing_key\":\"[REDACTED]\"}\n");
    comptime std.debug.assert(log.isSensitive(jwt.Key));
    comptime std.debug.assert(log.isSensitive(jwt.SigningKey));
}
