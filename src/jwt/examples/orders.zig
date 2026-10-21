//! The orders service of the guide on the backend in memory, with Ann's
//! app as its client: she signs in, and the app calls with her token,
//! without it, and with a forged one.

const std = @import("std");
const confy = @import("confy");
const http = @import("http");
const jwt = @import("jwt");
const log = @import("log");
const auth = @import("auth.zig");
const errors = @import("errors.zig");
const LoginController = @import("LoginController.zig");
const OrdersController = @import("OrdersController.zig");

const Config = struct {
    auth: struct {
        // APP_AUTH_SIGNING_KEY: the private key of orders, Ed25519 in PEM.
        signing_key: confy.Secret,
        // APP_AUTH_KEY_ID: its id, the "kid" of its tokens.
        key_id: []const u8,
        // While the key changes: the public key that signed before and its
        // id, APP_AUTH_PREVIOUS_KEY and APP_AUTH_PREVIOUS_KEY_ID.
        previous: ?struct {
            key: []const u8,
            key_id: []const u8,
        },
    },
    users: struct {
        // APP_USERS_ANN: the secret Ann signs in with.
        ann: confy.Secret,
    },
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

    var signing_key: jwt.SigningKey = try .fromPem(.EdDSA, config.auth.signing_key.expose(), .{ .id = config.auth.key_id });
    defer signing_key.deinit();
    // Its tokens are meant for orders and for billing.
    const signer: jwt.Signer = try .init(&signing_key, .{ .issuer = "orders", .audiences = &.{ "orders", "billing" } });
    // Orders checks the tokens of its key and, while the key changes, those
    // of the previous one, until the last of them expires.
    var keys: [2]jwt.Key = undefined;
    keys[0] = signing_key.verificationKey();
    var key_count: usize = 1;
    if (config.auth.previous) |previous| {
        keys[1] = try .fromPem(.EdDSA, previous.key, .{ .id = previous.key_id });
        key_count = 2;
    }
    const verifier: jwt.Verifier = try .init(.{ .keys = keys[0..key_count], .issuer = "orders", .audiences = &.{"orders"} });

    // The objects of the service: main owns them, the server borrows them.
    const users = [_]LoginController.User{
        .{ .name = "ann", .secret = config.users.ann, .id = "user-7", .roles = &.{"buyer"} },
    };
    var login: LoginController = .{ .signer = &signer, .users = &users };
    var orders: OrdersController = .{};
    var jwt_auth: auth.JwtAuth = .{ .verifier = &verifier, .logger = logger.scoped("auth") };
    var app_errors: errors.AppErrors = .{};
    var backend: http.testing.Backend = .init(gpa);
    defer backend.deinit();
    var server = try http.Server.init(gpa, .{
        .backend = backend.backend(),
        .prefix = "/api",
        .controllers = .{ &login, &orders },
        .middleware = .{&jwt_auth},
        .error_handler = &app_errors,
    });
    defer server.deinit(io);
    try server.start(io);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    var app: App = .{ .backend = &backend, .io = io, .arena = arena.allocator(), .out = &stdout.interface };

    _ = try app.signIn("guess", "with a wrong secret");
    const token = (try app.signIn(config.users.ann.expose(), "with her secret")) orelse return error.SignInRefused;
    try app.getOrders(null, "without a token");
    try app.getOrders(token, "with Ann's token");
    // A forged token: one character of the signature is another.
    const forged = try app.arena.dupe(u8, token);
    const at = std.mem.findScalarLast(u8, forged, '.').? + 1;
    forged[at] = if (forged[at] == 'A') 'B' else 'A';
    try app.getOrders(forged, "with Ann's token, its signature changed");
}

/// Ann's app: it says what it sends and what comes back, but never the
/// token, a credential.
const App = struct {
    backend: *http.testing.Backend,
    io: std.Io,
    arena: std.mem.Allocator,
    out: *std.Io.Writer,

    /// POST /api/login as Ann: her token, or null when refused.
    fn signIn(app: *App, secret: []const u8, how: []const u8) !?[]const u8 {
        try app.out.print("POST /api/login as ann, {s}\n", .{how});
        try app.out.flush();
        const body = try std.json.Stringify.valueAlloc(app.arena, LoginController.LoginRequest{ .user = "ann", .secret = secret }, .{});
        var res = try app.backend.request(app.io, .{
            .method = .POST,
            .target = "/api/login",
            .headers = &.{.{ "content-type", "application/json" }},
            .body = body,
        });
        defer res.deinit();
        if (res.status != 200) {
            try app.show(&res);
            return null;
        }
        const answer = try std.json.parseFromSliceLeaky(LoginController.LoginResponse, app.arena, res.body, .{ .allocate = .alloc_always });
        try app.out.print("→ 200 token_type={s} expires_in={d}\n", .{ answer.token_type, answer.expires_in });
        try app.out.flush();
        return answer.access_token;
    }

    /// GET /api/orders, with `token` in `Authorization: Bearer` if any.
    fn getOrders(app: *App, token: ?[]const u8, how: []const u8) !void {
        try app.out.print("GET /api/orders {s}\n", .{how});
        try app.out.flush();
        const authorization: [1][2][]const u8 = .{.{ "authorization", if (token) |t| try std.fmt.allocPrint(app.arena, "Bearer {s}", .{t}) else "" }};
        var res = try app.backend.request(app.io, .{
            .method = .GET,
            .target = "/api/orders",
            .headers = if (token == null) &.{} else &authorization,
        });
        defer res.deinit();
        try app.show(&res);
    }

    /// The status, then `WWW-Authenticate` of a 401 or else the body.
    fn show(app: *App, res: *const http.testing.Response) !void {
        if (res.status == 401) {
            try app.out.print("→ 401 WWW-Authenticate: {s}\n", .{res.header("www-authenticate") orelse ""});
        } else {
            try app.out.print("→ {d} {s}\n", .{ res.status, res.body });
        }
        try app.out.flush();
    }
};
