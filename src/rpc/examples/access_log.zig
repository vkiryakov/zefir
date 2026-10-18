//! The access log of the users service: middleware of the application on
//! zefir-log, first in the server's chain, that writes a record of every
//! call once the rest of the chain has run. The calls come from a gateway
//! that got a W3C traceparent, so every record carries its trace id.

const std = @import("std");
const core = @import("core");
const log = @import("log");
const rpc = @import("rpc");
const api = @import("users-api");
const UserHandler = @import("UserHandler.zig");
const UserRepository = @import("UserRepository.zig");

/// Middleware of the server with a dependency, the logger: a record of
/// every call, with its route, its outcome, its tenant, its request id and
/// how long it took. Never a body, credentials or the whole metadata: only
/// the keys it names.
const AccessLog = struct {
    logger: log.Logger,

    pub fn run(self: *AccessLog, ctx: *rpc.Context, next: *rpc.Next) anyerror!void {
        const started = std.Io.Clock.awake.now(ctx.io());
        const result = next.run();
        const op = ctx.operation();
        // The failure the client gets: deadline_exceeded once the deadline
        // has passed, cancelled after the client's cancel or the stop,
        // whatever the chain returned; else that of the chain's error.
        const failure: ?rpc.Failure = if (op.isExpired(std.Io.Clock.awake.now(ctx.io())))
            ctx.mapError(error.DeadlineExceeded)
        else if (op.isCancelled())
            ctx.mapError(error.Cancelled)
        else if (result) |_| null else |err| ctx.mapError(err);
        const route = ctx.route();
        // withContext puts the trace and span ids of the call in the record.
        self.logger.withContext(op).info("RPC call served", .{ .rpc = .{
            .service = route.service,
            .version = route.version,
            .method = route.method,
            .code = if (failure) |f| @tagName(f.code) else "ok",
            .app_code = if (failure) |f| f.app_code else "-",
            .tenant = ctx.metadata().get("x-tenant") orelse "-",
            .request_id = log.hex(&ctx.requestId()),
            .duration_ms = started.untilNow(ctx.io(), .awake).toMilliseconds(),
        } });
        // The outcome of the chain goes on as it is.
        return result;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const logger: log.Logger = try .init(gpa, io, .{ .format = .text });
    defer logger.deinit();

    var repo: UserRepository = .init(gpa);
    defer repo.deinit();
    var users: UserHandler = .{ .repo = &repo };

    var access_log: AccessLog = .{ .logger = logger.scoped("rpc") };
    var memory: rpc.testing.MemoryTransport = try .init(gpa, .{});
    defer memory.deinit(io);
    var server = try rpc.Server.init(gpa, .{
        .transport = memory.serverTransport(),
        .handlers = .{&users},
        // First in the chain, it sees the outcome of every link after it.
        .middleware = .{&access_log},
    });
    defer server.deinit(io);
    try server.start(io);

    var client = try rpc.Client.init(gpa, .{ .transport = memory.clientTransport() });
    defer client.deinit();

    // The trace of the request the gateway got, from its traceparent header.
    const trace = try core.w3c.parseTraceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01");
    const ctx = core.Context.root.withTrace(trace);
    const tenant: []const rpc.Metadata.Entry = &.{.{ .key = "x-tenant", .value = "acme" }};

    var created = try client.call(io, ctx, api.UserApi.createUser, .{ .name = "Ada Lovelace", .email = "ada@example.com" }, .{ .metadata = tenant });
    defer created.deinit();
    var missing = try client.call(io, ctx, api.UserApi.getUser, .{ .id = 42 }, .{ .metadata = tenant });
    defer missing.deinit();

    // A long write, such as a migration, holds the table of users: the last
    // call waits for it past its deadline, a second away.
    try repo.mutex.lock(io);
    defer repo.mutex.unlock(io);
    var late = client.call(io, ctx, api.UserApi.getUser, .{ .id = 1 }, .{ .metadata = tenant, .timeout = .fromSeconds(1) }) catch |err| switch (err) {
        // The client gives up at the deadline, the moment the server does.
        error.DeadlineExceeded => return,
        else => return err,
    };
    // Or the server's deadline_exceeded reached it first.
    late.deinit();
}
