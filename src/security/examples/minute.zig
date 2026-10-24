const std = @import("std");
const confy = @import("confy");
const jwt = @import("security").jwt;
const log = @import("log");
const v = @import("validator");

// The settings: the key of the service and its id.
const Config = struct {
    auth: struct {
        // APP_AUTH_SIGNING_KEY: an Ed25519 key in PEM, as openssl writes it.
        signing_key: confy.Secret,
        // APP_AUTH_KEY_ID: its id, the "kid" of every token it signs.
        key_id: []const u8,
    },
};

// The claims of the tokens, besides those that jwt sets and checks itself.
const Claims = struct {
    roles: []const []const u8 = &.{},

    pub const field_rules = .{ .roles = v.maxItems(16) };
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

    // The key signs; its public half, verificationKey(), verifies.
    var key: jwt.SigningKey = try .fromPem(.EdDSA, config.auth.signing_key.expose(), .{ .id = config.auth.key_id });
    defer key.deinit();
    logger.info("Key loaded", .{ .key = key, .algorithm = key.algorithm, .kid = key.id() });
    const signer: jwt.Signer = try .init(&key, .{ .issuer = "orders", .audiences = &.{"orders"} });
    const keys = [_]jwt.Key{key.verificationKey()};
    const verifier: jwt.Verifier = try .init(.{ .keys = &keys, .issuer = "orders", .audiences = &.{"orders"} });

    // The token of user-7, a buyer, as a sign-in gives it: for 15 minutes.
    const token = try signer.sign(Claims, io, gpa, &.{ .roles = &.{"buyer"} }, .{ .subject = "user-7" });
    defer gpa.free(token);

    // A route checks it; what it gives lives in the arena of the request.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const verified = try verifier.verify(Claims, io, arena.allocator(), token, .{});
    logger.info("Token verified", .{
        .subject = verified.registered.subject,
        .roles = verified.claims.roles,
        // jwt.Signer writes "iat" into every token.
        .lifetime_s = verified.registered.expires_at - verified.registered.issued_at.?,
    });

    // The service billing is not among the audiences of the token.
    const billing: jwt.Verifier = try .init(.{ .keys = &keys, .issuer = "orders", .audiences = &.{"billing"} });
    var details: jwt.Details = .{};
    if (billing.verify(Claims, io, arena.allocator(), token, .{ .details = &details })) |_| {
        logger.err("Token taken by billing", .{});
    } else |err| {
        logger.warn("Token refused", .{ .reason = err, .claim = details.claim, .description = jwt.describe(err) });
    }
}
