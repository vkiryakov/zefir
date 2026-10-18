//! The first exchange of every connection, by the handshake specification
//! of 2026: legacy hello, `isMaster` with `helloOk: true`, in OP_MSG to
//! `admin`, with the client's metadata. The reply says what the server
//! is: anything but a standalone mongod of MongoDB 7.0 or later (wire
//! version 21) is `error.Unsupported` before authentication, and the
//! connection closes.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const mongo = @import("mongo");
const bson = mongo.bson;
const wire = mongo.wire;
const Diagnostics = mongo.Diagnostics;
const Connection = @import("Connection.zig");
const time = @import("time.zig");

pub const driver_name = "zefir-mongo-async-driver";
pub const driver_version: []const u8 = @import("build_options").version;
/// MongoDB 7.0, the oldest server the driver works with.
pub const min_wire_version = 21;
/// The longest `client` document a server takes in hello.
pub const max_metadata_len = 512;

/// `os.type` of the metadata, as the handshake specification names it.
pub const os_type = switch (builtin.os.tag) {
    .linux => "Linux",
    .macos, .ios, .maccatalyst, .tvos, .visionos, .watchos, .driverkit => "Darwin",
    .windows => "Windows",
    .freebsd, .netbsd, .openbsd, .dragonfly => "BSD",
    else => "unknown",
};
pub const platform = "Zig " ++ builtin.zig_version_string;

/// The `client` document of hello: the application's name, when there is
/// one, the driver and its version, the system and the platform. A client
/// builds it once; at most 512 bytes, or `error.InvalidArgument`.
pub fn metadata(gpa: Allocator, app_name: ?[]const u8, d: ?*Diagnostics) error{ InvalidArgument, OutOfMemory }!bson.OwnedDocument {
    var b: bson.Builder = .init(gpa);
    defer b.deinit();
    buildMetadata(&b, app_name) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidBson => invalid(d, "appName cannot be written in hello", .{}),
    };
    const doc = b.finish() catch return error.OutOfMemory;
    if (doc.bytes.len > max_metadata_len) {
        doc.deinit();
        return invalid(d, "the metadata of hello takes {d} bytes, and a server takes {d}: shorten appName", .{ doc.bytes.len, max_metadata_len });
    }
    return doc;
}

fn buildMetadata(b: *bson.Builder, app_name: ?[]const u8) bson.Builder.Error!void {
    if (app_name) |name| {
        try b.beginDocument("application");
        try b.putString("name", name);
        try b.end();
    }
    try b.beginDocument("driver");
    try b.putString("name", driver_name);
    try b.putString("version", driver_version);
    try b.end();
    try b.beginDocument("os");
    try b.putString("type", os_type);
    try b.putString("architecture", @tagName(builtin.cpu.arch));
    try b.end();
    try b.putString("platform", platform);
}

/// What hello asks for besides the metadata.
pub const Params = struct {
    /// "<authSource>.<username>": the SCRAM mechanisms the user has.
    sasl_supported_mechs: ?[]const u8 = null,
    /// The first message of a speculative authentication.
    speculative_authenticate: ?bson.RawDocument = null,
};

/// The hello command; the exchange adds `$db: "admin"`.
pub fn command(gpa: Allocator, client_metadata: bson.RawDocument, params: Params) bson.Builder.Error!bson.OwnedDocument {
    var b: bson.Builder = .init(gpa);
    defer b.deinit();
    try b.putInt32("isMaster", 1);
    try b.putBoolean("helloOk", true);
    try b.putDocument("client", client_metadata);
    if (params.sasl_supported_mechs) |user| try b.putString("saslSupportedMechs", user);
    if (params.speculative_authenticate) |first| try b.putDocument("speculativeAuthenticate", first);
    return b.finish();
}

pub const Error = error{
    /// The server closed the connection, its reply broke OP_MSG, or it
    /// answered ok 0; the diagnostics say which.
    Unavailable,
    /// The server is not a standalone mongod of MongoDB 7.0 or later.
    Unsupported,
    OutOfMemory,
    /// The task was canceled, and stays canceled.
    Canceled,
};

/// Sends `hello` on `conn` and checks the reply. The connection keeps the
/// server's limits, its id of the connection and the round trip.
pub fn run(conn: *Connection, hello: bson.RawDocument, gpa: Allocator, d: ?*Diagnostics) Error!void {
    const io = conn.stream.io;
    const start = time.now(io);
    const reply = conn.exchange(.{ .database = "admin", .body = hello }, gpa, null, d) catch |err| {
        if (d) |x| x.phase = .handshake;
        return switch (err) {
            error.Interrupted => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
            error.ConnectionLost => {
                // The end of the stream, or a reset: what a server that
                // wants TLS does to a plain hello.
                const closed = if (conn.stream.err) |cause| cause == error.ConnectionResetByPeer else true;
                if (closed) if (d) |x| x.set(.handshake, null, "the server at {f} closed the connection during hello; a server that requires TLS does so, and v0.1 does not speak TLS", .{conn.address});
                return error.Unavailable;
            },
            else => error.Unavailable,
        };
    };
    defer reply.deinit();
    conn.rtt = start.durationTo(time.now(io));
    conn.hello = try check(reply.raw(), conn.address, gpa, d);
}

/// The hello of `reply`, a standalone mongod of wire version 21 or later.
fn check(reply: bson.RawDocument, address: Connection.Address, gpa: Allocator, d: ?*Diagnostics) error{ Unavailable, Unsupported, OutOfMemory }!wire.Hello {
    wire.checkReply(reply, gpa, d, null) catch |err| {
        // ok 0: the server's error is in the diagnostics.
        if (d) |x| x.phase = .handshake;
        return if (err == error.OutOfMemory) error.OutOfMemory else error.Unavailable;
    };
    var hello = wire.Hello.parse(reply, d) catch return error.Unavailable;
    const standalone_only = "; v0.1 supports standalone mongod only";
    switch (hello.server_type) {
        .standalone => {},
        .mongos => return refuse(d, "the server at {f} is a mongos (Mongos)" ++ standalone_only, .{address}),
        .rs_ghost => return refuse(d, "the server at {f} is a replica set member not initialized yet (RSGhost)" ++ standalone_only, .{address}),
        .rs_primary, .rs_secondary, .rs_arbiter, .rs_other => |kind| return refuse(d, "the server at {f} is a replica set member ({s}, setName={s})" ++ standalone_only, .{
            address, sdamName(kind), hello.set_name orelse "",
        }),
    }
    if (hello.max_wire_version < min_wire_version) {
        return refuse(d, "Server at {f} reports wire version {d}, but this version of zefir-mongo-async-driver requires at least 21 (MongoDB 7.0).", .{ address, hello.max_wire_version });
    }
    // A slice into the reply, which goes.
    hello.set_name = null;
    return hello;
}

/// The name of a server type in the SDAM specification.
fn sdamName(kind: wire.Hello.ServerType) []const u8 {
    return switch (kind) {
        .standalone => "Standalone",
        .mongos => "Mongos",
        .rs_primary => "RSPrimary",
        .rs_secondary => "RSSecondary",
        .rs_arbiter => "RSArbiter",
        .rs_other => "RSOther",
        .rs_ghost => "RSGhost",
    };
}

fn refuse(d: ?*Diagnostics, comptime fmt: []const u8, args: anytype) error{Unsupported} {
    if (d) |x| x.set(.handshake, null, fmt, args);
    return error.Unsupported;
}

fn invalid(d: ?*Diagnostics, comptime fmt: []const u8, args: anytype) error{InvalidArgument} {
    if (d) |x| x.set(null, null, fmt, args);
    return error.InvalidArgument;
}

const testing = std.testing;

test "the metadata names the driver, its version, the system and the platform, and the application when it has a name" {
    const plain = try metadata(testing.allocator, null, null);
    defer plain.deinit();
    const system = .{ .type = os_type, .architecture = @tagName(builtin.cpu.arch) };
    try testing.expectEqualSlices(u8, bson.literal(.{
        .driver = .{ .name = driver_name, .version = driver_version },
        .os = system,
        .platform = platform,
    }).bytes, plain.bytes);

    const named = try metadata(testing.allocator, "orders", null);
    defer named.deinit();
    try testing.expectEqualSlices(u8, bson.literal(.{
        .application = .{ .name = "orders" },
        .driver = .{ .name = driver_name, .version = driver_version },
        .os = system,
        .platform = platform,
    }).bytes, named.bytes);
}

test "with the longest appName the metadata stays within the 512 bytes a server takes" {
    const longest = try metadata(testing.allocator, &@as([128]u8, @splat('a')), null);
    defer longest.deinit();
    try testing.expect(longest.bytes.len <= max_metadata_len);
}

test "hello is isMaster with helloOk and the metadata, then what authentication asks for" {
    const meta = bson.literal(.{ .driver = .{ .name = driver_name } });
    const plain = try command(testing.allocator, meta, .{});
    defer plain.deinit();
    try testing.expectEqualSlices(u8, bson.literal(.{ .isMaster = 1, .helloOk = true, .client = .{ .driver = .{ .name = driver_name } } }).bytes, plain.bytes);

    const first = bson.literal(.{ .saslStart = 1, .mechanism = "SCRAM-SHA-256" });
    const asking = try command(testing.allocator, meta, .{ .sasl_supported_mechs = "admin.app", .speculative_authenticate = first });
    defer asking.deinit();
    try testing.expectEqualSlices(u8, bson.literal(.{
        .isMaster = 1,
        .helloOk = true,
        .client = .{ .driver = .{ .name = driver_name } },
        .saslSupportedMechs = "admin.app",
        .speculativeAuthenticate = .{ .saslStart = 1, .mechanism = "SCRAM-SHA-256" },
    }).bytes, asking.bytes);
}
