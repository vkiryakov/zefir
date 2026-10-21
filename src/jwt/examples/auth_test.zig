//! Tests of the orders service without a network: `http.testing.Backend`
//! serves the same server, controllers and middleware from memory. The
//! key is made for the tests, and `jwt.testing.FixedClock` sets the time
//! that the server, the signer and the verifier read, so a test can let a
//! token expire without waiting.

const std = @import("std");
const http = @import("http");
const jwt = @import("jwt");
const log = @import("log");
const auth = @import("auth.zig");
const errors = @import("errors.zig");
const LoginController = @import("LoginController.zig");
const OrdersController = @import("OrdersController.zig");

const testing = std.testing;

/// The time of the tests: 2026-10-22, 12:00 UTC, in seconds of Unix time.
const noon = 1_792_670_400;

/// What a test sets of the service, as `main` reads it from the settings.
const Options = struct {
    /// The id of the key of orders, which the test makes on the spot.
    key_id: []const u8 = "2026-10",
    /// While the key changes, the public key that signed before.
    previous: ?jwt.Key = null,
};

/// The service as `main` builds it, on the backend in memory, with a key
/// of its own and the clock at noon.
const Service = struct {
    clock: jwt.testing.FixedClock,
    key: jwt.SigningKey,
    keys: [2]jwt.Key,
    signer: jwt.Signer,
    verifier: jwt.Verifier,
    /// What the log of `JwtAuth` wrote, a record per line.
    records: std.Io.Writer.Allocating,
    logger: log.Logger,
    users: [1]LoginController.User,
    login: LoginController,
    orders: OrdersController,
    jwt_auth: auth.JwtAuth,
    app_errors: errors.AppErrors,
    backend: http.testing.Backend,
    server: http.Server,

    /// Starts the service; `s` stays where it is until `stop`.
    fn start(s: *Service, options: Options) !void {
        s.clock = try .init(testing.io, noon);
        errdefer s.clock.deinit();
        const io = s.clock.io();
        // A key of the tests alone, made on the spot.
        s.key = try .generate(io, .EdDSA, .{ .id = options.key_id });
        errdefer s.key.deinit();
        s.signer = try .init(&s.key, .{ .issuer = "orders", .audiences = &.{ "orders", "billing" } });
        // As in main: the key of orders, and the previous one, if any.
        s.keys[0] = s.key.verificationKey();
        var key_count: usize = 1;
        if (options.previous) |previous| {
            s.keys[1] = previous;
            key_count = 2;
        }
        s.verifier = try .init(.{ .keys = s.keys[0..key_count], .issuer = "orders", .audiences = &.{"orders"} });
        s.records = .init(testing.allocator);
        errdefer s.records.deinit();
        s.logger = try .init(testing.allocator, io, .{ .format = .text, .output = .{ .writer = &s.records.writer } });
        errdefer s.logger.deinit();
        s.users = .{.{ .name = "ann", .secret = .init("ann-secret"), .id = "user-7", .roles = &.{"buyer"} }};
        s.login = .{ .signer = &s.signer, .users = &s.users };
        s.orders = .{};
        s.jwt_auth = .{ .verifier = &s.verifier, .logger = s.logger.scoped("auth") };
        s.app_errors = .{};
        s.backend = .init(testing.allocator);
        s.server = try .init(testing.allocator, .{
            .backend = s.backend.backend(),
            .prefix = "/api",
            .controllers = .{ &s.login, &s.orders },
            .middleware = .{&s.jwt_auth},
            .error_handler = &s.app_errors,
        });
        errdefer s.server.deinit(io);
        try s.server.start(io);
    }

    fn stop(s: *Service) void {
        s.server.deinit(s.clock.io());
        s.backend.deinit();
        s.logger.deinit();
        s.records.deinit();
        s.keys[0].deinit();
        s.key.deinit();
        s.clock.deinit();
    }

    /// POST /api/login as Ann with `secret`, and with `token` in
    /// `Authorization: Bearer` when her app still holds one.
    fn signIn(s: *Service, secret: []const u8, token: ?[]const u8) !http.testing.Response {
        const body = try std.json.Stringify.valueAlloc(testing.allocator, LoginController.LoginRequest{ .user = "ann", .secret = secret }, .{});
        defer testing.allocator.free(body);
        const authorization = try std.fmt.allocPrint(testing.allocator, "Bearer {s}", .{token orelse ""});
        defer testing.allocator.free(authorization);
        const headers: [2][2][]const u8 = .{ .{ "content-type", "application/json" }, .{ "authorization", authorization } };
        return s.backend.request(s.clock.io(), .{
            .method = .POST,
            .target = "/api/login",
            .headers = headers[0..if (token == null) 1 else 2],
            .body = body,
        });
    }

    /// Ann's token, which the caller frees.
    fn tokenOfAnn(s: *Service) ![]u8 {
        var res = try s.signIn("ann-secret", null);
        defer res.deinit();
        try testing.expectEqual(200, res.status);
        const answer = try std.json.parseFromSliceLeaky(LoginController.LoginResponse, res.arena.allocator(), res.body, .{});
        return testing.allocator.dupe(u8, answer.access_token);
    }

    /// GET /api/orders with `token` in `Authorization: Bearer`.
    fn getOrders(s: *Service, token: []const u8) !http.testing.Response {
        const authorization = try std.fmt.allocPrint(testing.allocator, "Bearer {s}", .{token});
        defer testing.allocator.free(authorization);
        return s.backend.request(s.clock.io(), .{
            .method = .GET,
            .target = "/api/orders",
            .headers = &.{.{ "authorization", authorization }},
        });
    }
};

test "POST /api/login gives a token for 15 minutes" {
    var s: Service = undefined;
    try s.start(.{});
    defer s.stop();

    var res = try s.signIn("ann-secret", null);
    defer res.deinit();
    try testing.expectEqual(200, res.status);
    const answer = try std.json.parseFromSliceLeaky(LoginController.LoginResponse, res.arena.allocator(), res.body, .{});
    try testing.expectEqualStrings("Bearer", answer.token_type);
    try testing.expectEqual(15 * 60, answer.expires_in);

    // The token verifies, with the claims of Ann, from noon to 12:15.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const verified = try s.verifier.verify(auth.Claims, s.clock.io(), arena.allocator(), answer.access_token, .{});
    try testing.expectEqualStrings("user-7", verified.registered.subject.?);
    try testing.expectEqual(noon, verified.registered.issued_at.?);
    try testing.expectEqual(15 * 60, verified.registered.expires_at - verified.registered.issued_at.?);
    try testing.expectEqual(1, verified.claims.roles.len);
    try testing.expectEqualStrings("buyer", verified.claims.roles[0]);

    // A wrong secret gets no token.
    var refused = try s.signIn("guess", null);
    defer refused.deinit();
    try testing.expectEqual(401, refused.status);
    try testing.expectEqualStrings("Bearer", refused.header("www-authenticate").?);
}

test "GET /api/orders with the token sees the user" {
    var s: Service = undefined;
    try s.start(.{});
    defer s.stop();
    const token = try s.tokenOfAnn();
    defer testing.allocator.free(token);

    var res = try s.getOrders(token);
    defer res.deinit();
    try testing.expectEqual(200, res.status);
    const mine = try std.json.parseFromSliceLeaky(OrdersController.OrdersResponse, res.arena.allocator(), res.body, .{});
    try testing.expectEqualStrings("user-7", mine.user);
    try testing.expectEqualStrings("buyer", mine.roles[0]);
}

test "without a token the request is anonymous, and a protected route says 401" {
    var s: Service = undefined;
    try s.start(.{});
    defer s.stop();

    var res = try s.backend.request(s.clock.io(), .{ .method = .GET, .target = "/api/orders" });
    defer res.deinit();
    try testing.expectEqual(401, res.status);
    try testing.expectEqualStrings("Bearer", res.header("www-authenticate").?);
    // Nothing was refused: no token came.
    try testing.expectEqualStrings("", s.records.written());
}

test "an expired token is 401 invalid_token with its description" {
    var s: Service = undefined;
    try s.start(.{});
    defer s.stop();
    const token = try s.tokenOfAnn();
    defer testing.allocator.free(token);

    // 15 minutes of its life and the 60 seconds of leeway have passed.
    s.clock.set(noon + 16 * 60);
    var res = try s.getOrders(token);
    defer res.deinit();
    try testing.expectEqual(401, res.status);
    try testing.expectEqualStrings("Bearer error=\"invalid_token\", error_description=\"the token has expired\"", res.header("www-authenticate").?);
    // The log says why, and nothing of the token.
    try testing.expect(std.mem.find(u8, s.records.written(), "Token refused reason=Expired claim=exp") != null);
    try testing.expect(std.mem.find(u8, s.records.written(), token) == null);
}

test "an expired token does not stop POST /api/login" {
    var s: Service = undefined;
    try s.start(.{});
    defer s.stop();
    const token = try s.tokenOfAnn();
    defer testing.allocator.free(token);

    // Ann's app still sends her old token when she signs in again.
    s.clock.set(noon + 16 * 60);
    var res = try s.signIn("ann-secret", token);
    defer res.deinit();
    try testing.expectEqual(200, res.status);
    try testing.expect(std.mem.find(u8, s.records.written(), "Token refused reason=Expired claim=exp") != null);
}

test "with an expired token and a wrong secret, POST /api/login refuses the secret" {
    var s: Service = undefined;
    try s.start(.{});
    defer s.stop();
    const token = try s.tokenOfAnn();
    defer testing.allocator.free(token);

    // Ann's app still sends her old token, and she mistypes her secret: the
    // answer is the sign-in's own, with nothing of the old token.
    s.clock.set(noon + 16 * 60);
    var res = try s.signIn("guess", token);
    defer res.deinit();
    try testing.expectEqual(401, res.status);
    try testing.expectEqualStrings("Bearer", res.header("www-authenticate").?);
    try testing.expectEqualStrings("{\"code\":\"invalid_credentials\",\"message\":\"Wrong user or secret\"}", res.body);
}

test "a token for billing alone is 401 at orders" {
    var s: Service = undefined;
    try s.start(.{});
    defer s.stop();

    const for_billing: jwt.Signer = try .init(&s.key, .{ .issuer = "orders", .audiences = &.{"billing"} });
    const token = try for_billing.sign(auth.Claims, s.clock.io(), testing.allocator, &.{ .roles = &.{"buyer"} }, .{ .subject = "user-7" });
    defer testing.allocator.free(token);
    var res = try s.getOrders(token);
    defer res.deinit();
    try testing.expectEqual(401, res.status);
    try testing.expectEqualStrings("Bearer error=\"invalid_token\", error_description=\"the token is not meant for this service\"", res.header("www-authenticate").?);
}

test "a token of orders without sub is 401 where a user is needed" {
    var s: Service = undefined;
    try s.start(.{});
    defer s.stop();

    // Signed by orders, but for nobody.
    const token = try s.signer.sign(auth.Claims, s.clock.io(), testing.allocator, &.{}, .{});
    defer testing.allocator.free(token);
    var res = try s.getOrders(token);
    defer res.deinit();
    try testing.expectEqual(401, res.status);
    try testing.expectEqualStrings("Bearer error=\"invalid_token\", error_description=\"the token lacks a required claim\"", res.header("www-authenticate").?);
    try testing.expect(std.mem.find(u8, s.records.written(), "Token refused reason=MissingClaim claim=sub") != null);
}

test "after orders changes its key, a token of the old one still passes" {
    // Before the change: Ann signs in with orders on its first key.
    var old_key: jwt.Key = undefined;
    const old_token = old: {
        var before: Service = undefined;
        try before.start(.{});
        defer before.stop();
        old_key = before.key.verificationKey();
        break :old try before.tokenOfAnn();
    };
    defer testing.allocator.free(old_token);

    // Step 2 of the change: orders restarts with a new key, and with the
    // public key of the old one as the previous key.
    var s: Service = undefined;
    try s.start(.{ .key_id = "2026-11", .previous = old_key });
    defer s.stop();
    const new_token = try s.tokenOfAnn();
    defer testing.allocator.free(new_token);
    for ([_][]const u8{ old_token, new_token }) |token| {
        var res = try s.getOrders(token);
        defer res.deinit();
        try testing.expectEqual(200, res.status);
    }
}
