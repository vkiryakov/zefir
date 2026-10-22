//! The errors of calls, against a server: what each says, and whether the
//! command may have run. A counter that is a list, a number that is text,
//! calls that break the client's rules, and a transaction that the server
//! drops whole. Each run starts afresh.
//!
//! Settings, from the environment:
//!
//!   APP_REDIS_URL        the server; redis://127.0.0.1:6379 by default
//!   APP_REDIS_PASSWORD   the password of the user of the URL, or of the
//!                        user default, if the server wants one
//!
//! In tests/redis, `zig build example-errors` runs it against the servers
//! of the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const redis = @import("redis");
const zio = @import("zio");
const cmd = redis.cmd;

pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    redis: struct {
        url: []const u8 = "redis://127.0.0.1:6379",
        password: ?confy.Secret = null,
    } = .{},
};

pub fn main(init: std.process.Init) !void {
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });
    const logger: log.Logger = try .init(init.gpa, init.io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();
    const app = logger.scoped("app");
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    var client: redis.Client = try .init(init.gpa, io, .{
        .url = config.redis.url,
        .password = if (config.redis.password) |password| password.expose() else null,
    });
    defer client.deinit();
    try client.connect(io, within(io, .fromSeconds(10)), null);
    defer client.close(io);

    const op: redis.OperationContext = .of(within(io, .fromSeconds(10)));
    _ = try client.run(io, op, cmd.del(&.{ "motd", "orders:paid", "stock:coffee" }), .{});
    try client.run(io, op, cmd.set("motd", "Fresh beans from Ethiopia", .{}), .{});
    _ = try client.run(io, op, cmd.rpush("orders:paid", .{"ann"}), .{});

    var d: redis.Diagnostics = .{};

    // ServerError: the server refused the command, with its code first. A
    // list is no counter.
    if (client.run(io, op, cmd.incr("orders:paid"), .{ .diagnostics = &d })) |_| {
        app.info("Counted", .{});
    } else |err| report(app, "A count", err, &d);

    // UnexpectedReply: the reply does not fit the type that the call named,
    // a number here. The client read the reply to its end, so the
    // connection goes back to the pool.
    if (client.run(io, op, cmd.get(i64, "motd"), .{ .diagnostics = &d })) |_| {
        app.info("A number", .{});
    } else |err| report(app, "A read", err, &d);

    // InvalidArgument: the client stops a call that breaks its rules before
    // anything goes out: a delete of no keys; a command that would change
    // the connection for the calls after it.
    if (client.run(io, op, cmd.del(&.{}), .{ .diagnostics = &d })) |_| {
        app.info("Deleted", .{});
    } else |err| report(app, "A delete", err, &d);
    if (client.run(io, op, cmd.raw(void, .{ "SELECT", 1 }), .{ .diagnostics = &d })) |_| {
        app.info("Selected", .{});
    } else |err| report(app, "A raw command", err, &d);

    // EXECABORT: the server refused a command of a transaction as it queued
    // it, and dropped the whole transaction. The class of ServerError says
    // that it may have run; its code says that none of it did.
    var conn = try client.acquire(io, op);
    defer conn.release(io);
    if (conn.transaction(io, op, .{
        cmd.set("stock:coffee", 10, .{}),
        cmd.raw(void, .{ "RESTOCK", "coffee" }),
    }, .{ .diagnostics = &d })) |_| {
        app.info("Restocked", .{});
    } else |err| {
        report(app, "A transaction", err, &d);
        if (d.refused()) |refused| app.info("Refused", .{ .command = d.command, .code = refused.code });
        app.info("Dropped whole", .{ .stock_set = try client.run(io, op, cmd.exists(&.{"stock:coffee"}), .{}) });
    }
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}

/// Logs `err` of `what`, the server's code, if a server gave it, the
/// details, and whether the command may have run.
fn report(app: log.Logger, comptime what: []const u8, err: redis.Error, d: *const redis.Diagnostics) void {
    app.warn(what ++ " failed", .{ .reason = err, .outcome = redis.outcome(err), .code = d.code(), .details = d.message() });
}
