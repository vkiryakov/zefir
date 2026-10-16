//! A retry that does not create a second user. The client sends an
//! idempotency key with createUser; middleware on a store lets the first
//! call with a key through and refuses the repeats. The memory transport
//! loses the first response, as a network may: the client cannot tell
//! whether the user was created, and retries with the same key.

const std = @import("std");
const confy = @import("confy");
const log = @import("log");
const rpc = @import("rpc");
const api = @import("users-api");
const Store = @import("Store.zig");
const UserHandler = @import("UserHandler.zig");
const UserRepository = @import("UserRepository.zig");

const Config = struct {
    idempotency: struct {
        /// How long the server remembers a key.
        ttl_hours: u32 = 24,
    } = .{},
};

/// Middleware of the server's level: the first call with a key goes on, a
/// call with a key the store holds ends with `already_exists` before the
/// handler runs.
const Idempotency = struct {
    store: *Store,
    ttl: std.Io.Duration,

    pub fn run(self: *Idempotency, ctx: *rpc.Context, next: *rpc.Next) anyerror!void {
        // A call without a key is not protected.
        const key = ctx.metadata().get("idempotency-key") orelse return next.run();
        const route = ctx.route();
        const entry = try std.fmt.allocPrint(ctx.allocator(), "idem:{s}.{s}:{s}", .{ route.service, route.method, key });
        const first = self.store.setIfAbsent(ctx.io(), entry, self.ttl) catch |err| switch (err) {
            error.Canceled => return err,
            // Without the store a repeat cannot be told from a first call:
            // refuse rather than risk a second user (fail-closed).
            else => return ctx.fail(.{ .code = .unavailable, .app_code = "idem.unavailable", .message = "Try again later" }),
        };
        if (!first) {
            return ctx.fail(.{ .code = .already_exists, .app_code = "idem.duplicate_request", .message = "Duplicate request" });
        }
        return next.run();
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });
    const logger: log.Logger = try .init(gpa, io, .{ .format = .text });
    defer logger.deinit();
    const app = logger.scoped("app");

    var store: Store = .init(gpa);
    defer store.deinit();
    var repo: UserRepository = .init(gpa);
    defer repo.deinit();
    var users: UserHandler = .{ .repo = &repo };
    var idempotency: Idempotency = .{ .store = &store, .ttl = .fromSeconds(@as(i64, config.idempotency.ttl_hours) * 3600) };

    var memory: rpc.testing.MemoryTransport = try .init(gpa, .{});
    defer memory.deinit(io);
    var server = try rpc.Server.init(gpa, .{
        .transport = memory.serverTransport(),
        .handlers = .{&users},
        .middleware = .{&idempotency},
    });
    defer server.deinit(io);
    try server.start(io);

    var client = try rpc.Client.init(gpa, .{ .transport = memory.clientTransport() });
    defer client.deinit();

    // The key names the operation, here the sign-up form the user sent: it
    // stays the same on every retry of it.
    const signup: api.CreateUserRequest = .{ .name = "Ada Lovelace", .email = "ada@example.com" };
    const options: rpc.Client.CallOptions = .{
        .timeout = .fromMilliseconds(200),
        .metadata = &.{.{ .key = "idempotency-key", .value = "signup-form-1001" }},
    };

    // The server creates the user, but the response never arrives.
    memory.loseNextResponse();
    try signUp(&client, io, app, signup, options);
    try signUp(&client, io, app, signup, options);
    app.info("Users stored", .{ .count = try repo.count(io) });
}

/// One try to sign up, and a record of its outcome.
fn signUp(client: *rpc.Client, io: std.Io, app: log.Logger, request: api.CreateUserRequest, options: rpc.Client.CallOptions) !void {
    var result = client.call(io, .root, api.UserApi.createUser, request, options) catch |err| switch (err) {
        // The call may have run or not: retry it only with the same key.
        error.DeadlineExceeded, error.ConnectionLost => return app.warn("No response", .{ .reason = err }),
        else => return err,
    };
    defer result.deinit();
    switch (result.outcome) {
        .ok => |user| app.info("User created", .{ .id = user.id }),
        .failure => |failure| app.warn("Call failed", .{ .code = failure.code, .app_code = failure.app_code, .reason = failure.message }),
    }
}
