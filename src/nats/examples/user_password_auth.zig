//! A server that wants a user and a password. Both come from the
//! configuration, the password as a `confy.Secret`: the logger writes it
//! as [REDACTED], and the program reads it with `expose()` only where the
//! client gets it. The client keeps its own copy of the credentials and
//! wipes it when it is freed.
//!
//! The password travels in plaintext, as this client does not do TLS: use
//! it on a trusted network only.
//!
//! Settings, from the environment or a `.env` file in the working
//! directory:
//!
//!   APP_NATS_URL        the server; nats://127.0.0.1:4222 by default
//!   APP_NATS_USER       the user
//!   APP_NATS_PASSWORD   the password

const std = @import("std");
const confy = @import("confy");
const log = @import("log");
const nats = @import("nats");
const zio = @import("zio");

/// The client logs through std.log; this sends its records to the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    nats: struct {
        url: []const u8 = "nats://127.0.0.1:4222",
        user: []const u8,
        password: confy.Secret,
    },
};

pub fn main(init: std.process.Init) !u8 {
    var config: Config = undefined;
    // A missing user or password stops the program here, and says which.
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{ .env(".env"), .osEnv() },
    });

    // The logger outlives the runtime, so it takes `init.io`, through which
    // any thread may log: the tasks of the runtime too.
    const logger: log.Logger = try .init(init.gpa, init.io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();

    const rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    // The whole configuration may be logged: the password comes out as [REDACTED].
    logger.info("Connecting", .{ .config = config });
    var client: nats.Client = try .init(init.gpa, io, .{
        .servers = &.{config.nats.url},
        .name = "billing",
        .auth = .{ .user_password = .{
            .username = config.nats.user,
            .password = config.nats.password.expose(),
        } },
    });
    defer client.deinit();
    client.connect() catch |err| switch (err) {
        // A wrong user or password. Not worth retrying with the same ones.
        // Returning, rather than exiting, lets `deinit` wipe the client's
        // copy of the credentials.
        error.AuthenticationFailed => {
            logger.err("The server refused the user or the password", .{ .user = config.nats.user });
            return 1;
        },
        else => return err,
    };
    logger.info("Connected", .{ .user = config.nats.user });

    const round_trip = try client.rtt(.{});
    logger.info("Server reached", .{ .rtt_us = round_trip.toMicroseconds() });
    try client.drain(.{});
    return 0;
}
