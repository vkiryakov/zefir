//! The users service with authentication and middleware on all three
//! levels: the server's (a rate limit on a store), the handler's (an audit
//! of every call that succeeded) and the methods' (the permissions to
//! change users). A client calls it as an anonymous caller, as the
//! reporting job and as the admin console, whose token comes from a
//! provider.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const rpc = @import("rpc");
const api = @import("users-api");
const mw = @import("middleware.zig");
const Store = @import("Store.zig");
const TokenAuthenticator = @import("TokenAuthenticator.zig");
const UserRepository = @import("UserRepository.zig");

const Config = struct {
    auth: struct {
        admin_token: confy.Secret,
        reporting_token: confy.Secret,
    },
    rate: struct {
        per_minute: u32 = 3,
    } = .{},
};

/// The handler of UserApi, as in UserHandler.zig, with the settings of
/// this service: an identity for every method but getUser, the audit of
/// every call, and the permissions of the methods that change users.
const UserHandler = struct {
    repo: *UserRepository,
    /// A field that the handler's level names as `.audit`.
    audit: *mw.Audit,

    pub const rpc_handler = rpc.implement(api.UserApi, .{
        .defaults = .{ .auth = .required },
        .middleware = .{.audit},
        .methods = .{
            .getUser = .{ .auth = .optional },
            .createUser = .{ .middleware = .{mw.requirePermission("users.write")} },
            .deleteUser = .{ .middleware = .{mw.requirePermission("users.delete")} },
        },
    });

    pub fn createUser(self: *UserHandler, ctx: *rpc.Context, req: api.CreateUserRequest) UserRepository.Error!api.User {
        return self.repo.insert(ctx.operation(), ctx.io(), ctx.allocator(), req.name, req.email);
    }

    pub fn getUser(self: *UserHandler, ctx: *rpc.Context, req: api.GetUserRequest) UserRepository.Error!api.User {
        return self.repo.find(ctx.operation(), ctx.io(), ctx.allocator(), req.id);
    }

    pub fn listUsers(self: *UserHandler, ctx: *rpc.Context, req: api.ListUsersRequest) UserRepository.Error!api.ListUsersResponse {
        return self.repo.list(ctx.operation(), ctx.io(), ctx.allocator(), req.offset, req.limit);
    }

    pub fn deleteUser(self: *UserHandler, ctx: *rpc.Context, req: api.DeleteUserRequest) UserRepository.Error!void {
        return self.repo.remove(ctx.operation(), ctx.io(), req.id);
    }
};

/// The tokens of the admin console, which change: a real console gets them
/// from an OAuth server and a new one before the old one expires. The
/// client asks for the credentials of a call right before sending it.
const AdminTokens = struct {
    token: confy.Secret,
    /// How many times the client asked.
    asked: std.atomic.Value(u32) = .init(0),

    fn provider(self: *AdminTokens) rpc.CredentialsProvider {
        return .{ .ptr = self, .get = get };
    }

    /// The credentials of one call. `ctx` carries the call's deadline;
    /// strings made for it come from `arena`, which lives until the call is
    /// sent; `error.Unavailable` ends the call unsent.
    fn get(ptr: *anyopaque, _: std.Io, _: core.Context, _: std.mem.Allocator) (error{ Unavailable, OutOfMemory } || std.Io.Cancelable)!rpc.Credentials {
        const self: *AdminTokens = @ptrCast(@alignCast(ptr));
        _ = self.asked.fetchAdd(1, .monotonic);
        return .{ .bearer = self.token.expose() };
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
    _ = try repo.insert(.root, io, init.arena.allocator(), "Ada Lovelace", "ada@example.com");

    // The objects of the service: main owns them, the server borrows them.
    var audit: mw.Audit = .{ .logger = logger.scoped("audit") };
    var users: UserHandler = .{ .repo = &repo, .audit = &audit };
    var auth: TokenAuthenticator = .{ .admin_token = config.auth.admin_token, .reporting_token = config.auth.reporting_token };
    var limiter: mw.RateLimiter = .{ .store = &store, .per_minute = config.rate.per_minute };

    var memory: rpc.testing.MemoryTransport = try .init(gpa, .{});
    defer memory.deinit(io);
    var server = try rpc.Server.init(gpa, .{
        .transport = memory.serverTransport(),
        .handlers = .{&users},
        .authenticator = &auth,
        // The server's level: around every call of every handler.
        .middleware = .{&limiter},
    });
    defer server.deinit(io);
    try server.start(io);

    // One client; every call brings the credentials of its caller.
    var client = try rpc.Client.init(gpa, .{ .transport = memory.clientTransport() });
    defer client.deinit();
    var admin_tokens: AdminTokens = .{ .token = config.auth.admin_token };
    const anonymous: rpc.Credentials = .none;
    const forged: rpc.Credentials = .{ .bearer = "guessed-token" };
    const reporting: rpc.Credentials = .{ .bearer = config.auth.reporting_token.expose() };
    const admin: rpc.Credentials = .{ .provider = admin_tokens.provider() };

    try call(&client, io, app, "anonymous", anonymous, api.UserApi.getUser, .{ .id = 1 });
    try call(&client, io, app, "anonymous", anonymous, api.UserApi.listUsers, .{});
    try call(&client, io, app, "forged", forged, api.UserApi.getUser, .{ .id = 1 });
    try call(&client, io, app, "reporting", reporting, api.UserApi.listUsers, .{});
    try call(&client, io, app, "reporting", reporting, api.UserApi.deleteUser, .{ .id = 1 });
    try call(&client, io, app, "admin", admin, api.UserApi.createUser, .{ .name = "Alan Turing", .email = "alan@example.com" });
    try call(&client, io, app, "admin", admin, api.UserApi.deleteUser, .{ .id = 1 });
    app.info("Admin tokens given", .{ .count = admin_tokens.asked.load(.monotonic) });
    // The third and the fourth call of the reporting job within a minute.
    try call(&client, io, app, "reporting", reporting, api.UserApi.getUser, .{ .id = 2 });
    try call(&client, io, app, "reporting", reporting, api.UserApi.getUser, .{ .id = 2 });

    // Without its store the rate limit lets calls through.
    store.up.store(false, .release);
    app.info("Store down", .{});
    try call(&client, io, app, "reporting", reporting, api.UserApi.getUser, .{ .id = 2 });
}

/// One call as `caller`, with its credentials, and a record of the outcome.
fn call(
    client: *rpc.Client,
    io: std.Io,
    app: log.Logger,
    caller: []const u8,
    credentials: rpc.Credentials,
    comptime method: anytype,
    request: @TypeOf(method).Request,
) !void {
    var result = try client.call(io, .root, method, request, .{ .credentials = credentials });
    defer result.deinit();
    const name = @TypeOf(method).name;
    // Null when the rate limit did not count the call, and after a failure
    // of the engine itself, such as the deadline: it carries no metadata.
    const remaining = result.metadata().get("ratelimit-remaining");
    switch (result.outcome) {
        .ok => app.info("Call succeeded", .{ .caller = caller, .method = name, .remaining = remaining }),
        .failure => |failure| app.warn("Call failed", .{ .caller = caller, .method = name, .code = failure.code, .app_code = failure.app_code, .reason = failure.message, .remaining = remaining }),
    }
}
