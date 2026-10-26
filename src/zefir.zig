//! Zefir framework. Umbrella module re-exporting all subsystems.

pub const core = @import("core");
/// The application container, which lives in core: `zefir.App(AppModule)`
/// and the namespace of its types, `zefir.app`.
pub const app = core.app;
pub const App = core.App;
pub const log = @import("log");
pub const confy = @import("confy");
pub const validator = @import("validator");
pub const rpc = @import("rpc");
pub const rpc_nats = @import("rpc-nats");
pub const mongo_bson = @import("mongo-bson");
pub const odm = @import("odm");
pub const scheduler = @import("scheduler");
pub const mongo = @import("mongo");
pub const redis = @import("redis");
pub const nats = @import("nats");
pub const http = @import("http");
pub const security = @import("security");
pub const openapi = @import("openapi");

test {
    @import("std").testing.refAllDecls(@This());
}

test "zefir.app and zefir.App are core's" {
    const std = @import("std");
    comptime {
        std.debug.assert(app == core.app);
        std.debug.assert(App == core.App);
    }
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
    const jwt = security.jwt;
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

test "zefir.log writes an odm.ConnectionConfig and an odm.Provision as [REDACTED]" {
    const std = @import("std");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const logger: log.Logger = try .init(std.testing.allocator, std.testing.io, .{ .output = .{ .writer = &out.writer } });
    defer logger.deinit();
    const config: odm.ConnectionConfig = .{ .uri = "mongodb://app@db:27017/?maxPoolSize=20", .password = "s3cret" };
    const provision: odm.Provision = .{
        .tenant = "acme",
        .connection = .{ .new = .{ .id = "big-1", .uri = "mongodb://acme@big:27017", .password = "s3cret" } },
        .database = "acme",
        .version = 1,
    };
    logger.info("Settings", .{ .settings = config, .event = provision });
    try std.testing.expect(std.mem.find(u8, out.written(), "s3cret") == null);
    try std.testing.expect(std.mem.find(u8, out.written(), "mongodb://") == null);
    try std.testing.expectStringEndsWith(out.written(), ",\"settings\":\"[REDACTED]\",\"event\":\"[REDACTED]\"}\n");
    comptime std.debug.assert(log.isSensitive(odm.ConnectionConfig));
    comptime std.debug.assert(log.isSensitive(odm.Provision));
}

test "odm.Registry is a bean of zefir.App: the stop drains it within the deadline" {
    const std = @import("std");
    const testing = std.testing;
    const io = testing.io;
    // App builds the fake driver, the registry, which a factory makes, and
    // the tenants, whose `start` binds one; at the stop it shuts the
    // registry down, and at its deinit frees it.
    const Tenants = struct {
        registry: *odm.Registry,

        pub fn start(tenants: *@This(), task_io: std.Io) !void {
            try tenants.registry.registerConnection(task_io, "main", .{ .uri = "fake://shop" });
            try tenants.registry.provisionTenant(task_io, .root, .{ .tenant = "acme", .connection = .{ .existing = "main" }, .database = "acme", .version = 1 });
        }
    };
    const Root = struct {
        pub const module: app.Module = .{
            .providers = &.{ odm.testing.FakeDriver, Tenants },
            .factories = &.{Odm},
        };

        pub const Odm = struct {
            pub fn registry(gpa: std.mem.Allocator, task_io: std.Io, driver: *odm.testing.FakeDriver) odm.Registry {
                return .init(gpa, task_io, driver.driver(), .{});
            }
        };
    };
    var application = try App(Root).init(testing.allocator, io, .{}, .{ .shutdown_timeout = .fromSeconds(10) });
    defer application.deinit();
    try application.start();
    const registry: *odm.Registry = application.get(odm.Registry);
    const fake: *odm.testing.FakeDriver = application.get(odm.testing.FakeDriver);
    try testing.expectEqual(@as(usize, 1), fake.counts(io).connected);

    // A session held over the start of the stop: App's stop task shuts the
    // registry down, and its drain waits for the lease.
    var session = try registry.tenant(io, "acme");
    var held = true;
    defer if (held) session.deinit(io);
    application.requestStop();
    const give_up = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(10));
    while (registry.stats(io).draining == 0) {
        if (std.Io.Clock.awake.now(io).nanoseconds >= give_up.nanoseconds) return error.Timeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(app.State.stopping, application.state());
    try testing.expectEqual(@as(usize, 0), fake.counts(io).closed);
    session.deinit(io);
    held = false;
    try application.wait();

    try testing.expectEqual(app.State.stopped, application.state());
    try testing.expectEqual(null, application.failure());
    try testing.expectEqual(@as(usize, 0), registry.stats(io).forced);
    try testing.expectError(error.ShuttingDown, registry.tenant(io, "acme"));
    const counts = fake.counts(io);
    try testing.expectEqual(@as(usize, 1), counts.opened);
    try testing.expectEqual(@as(usize, 1), counts.closed);
    try testing.expectEqual(@as(usize, 1), counts.freed);
}
