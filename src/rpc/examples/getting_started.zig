//! The users service and a client of it, in one program: the handler of
//! UserApi served by `rpc.Server`, and `rpc.Client` calling it, both on
//! the memory transport, which carries calls inside the process.

const std = @import("std");
const core = @import("core");
const log = @import("log");
const rpc = @import("rpc");
const api = @import("users-api");
const UserHandler = @import("UserHandler.zig");
const UserRepository = @import("UserRepository.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const logger: log.Logger = try .init(gpa, io, .{ .format = .text });
    defer logger.deinit();
    const app = logger.scoped("app");

    var repo: UserRepository = .init(gpa);
    defer repo.deinit();
    var users: UserHandler = .{ .repo = &repo };

    // Both sides of the calls in one process; a service on NATS takes
    // rpc_nats.Transport here instead.
    var memory: rpc.testing.MemoryTransport = try .init(gpa, .{});
    defer memory.deinit(io);

    var server = try rpc.Server.init(gpa, .{
        .transport = memory.serverTransport(),
        .handlers = .{&users},
    });
    defer server.deinit(io); // stops the server, after the client's deinit
    try server.start(io);

    var client = try rpc.Client.init(gpa, .{ .transport = memory.clientTransport() });
    defer client.deinit();
    // The caller's context. It has no deadline, so every call gets the
    // client's default timeout, 3 seconds.
    const ctx: core.Context = .root;

    // A success: `.ok` holds the method's response type, api.User.
    var created = try client.call(io, ctx, api.UserApi.createUser, .{ .name = "Ada Lovelace", .email = "ada@example.com" }, .{});
    defer created.deinit();
    const ada = switch (created.outcome) {
        .ok => |user| user,
        .failure => |failure| return logFailure(app, "createUser", failure, created.sent),
    };
    app.info("User created", .{ .id = ada.id, .name = ada.name });

    var found = try client.call(io, ctx, api.UserApi.getUser, .{ .id = ada.id }, .{});
    defer found.deinit();
    switch (found.outcome) {
        .ok => |user| app.info("User found", .{ .id = user.id, .email = user.email }),
        .failure => |failure| logFailure(app, "getUser", failure, found.sent),
    }

    // A failure of the service is a value, not an error: here the
    // contract's UserNotFound.
    var missing = try client.call(io, ctx, api.UserApi.getUser, .{ .id = 42 }, .{});
    defer missing.deinit();
    switch (missing.outcome) {
        .ok => |user| app.info("User found", .{ .id = user.id, .email = user.email }),
        .failure => |failure| logFailure(app, "getUser", failure, missing.sent),
    }

    // A request against the rules of CreateUserRequest is not sent: the
    // failure lists every violation.
    var invalid = try client.call(io, ctx, api.UserApi.createUser, .{ .name = "", .email = "ada-at-example.com" }, .{});
    defer invalid.deinit();
    switch (invalid.outcome) {
        .ok => |user| app.info("User created", .{ .id = user.id, .name = user.name }),
        .failure => |failure| logFailure(app, "createUser", failure, invalid.sent),
    }

    var again = try client.call(io, ctx, api.UserApi.createUser, .{ .name = "Ada", .email = "ADA@example.com" }, .{});
    defer again.deinit();
    switch (again.outcome) {
        .ok => |user| app.info("User created", .{ .id = user.id, .name = user.name }),
        .failure => |failure| logFailure(app, "createUser", failure, again.sent),
    }

    // Fields with defaults may be left out: offset 0, limit 20.
    var page = try client.call(io, ctx, api.UserApi.listUsers, .{}, .{});
    defer page.deinit();
    switch (page.outcome) {
        .ok => |list| app.info("Users listed", .{ .total = list.total, .first = list.users[0].name }),
        .failure => |failure| logFailure(app, "listUsers", failure, page.sent),
    }

    // A method whose response is void: `.ok` holds nothing.
    var deleted = try client.call(io, ctx, api.UserApi.deleteUser, .{ .id = ada.id }, .{});
    defer deleted.deinit();
    switch (deleted.outcome) {
        .ok => app.info("User deleted", .{ .id = ada.id }),
        .failure => |failure| logFailure(app, "deleteUser", failure, deleted.sent),
    }
}

/// Logs a failure: the server's, or the client's own for a request it did
/// not send (`sent` false).
fn logFailure(app: log.Logger, method: []const u8, failure: rpc.Failure, sent: bool) void {
    app.warn("Call failed", .{ .method = method, .code = failure.code, .app_code = failure.app_code, .reason = failure.message, .sent = sent });
    for (failure.violations) |violation| {
        app.warn("Violation", .{ .field = violation.field, .code = violation.code, .reason = violation.message });
    }
}
