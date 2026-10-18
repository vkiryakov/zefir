//! The first exchanges of every connection, by the handshake specification
//! of 2026 and the authentication specification: legacy hello, `isMaster`
//! with `helloOk: true`, in OP_MSG to `admin`, with the client's metadata,
//! then SCRAM when the client has a user. The reply to hello says what the
//! server is: anything but a standalone mongod of MongoDB 7.0 or later
//! (wire version 21) is `error.Unsupported` before authentication, and the
//! connection closes.
//!
//! Authentication takes one round trip less when the server takes the
//! speculative conversation that hello starts: hello carries saslStart of
//! SCRAM-SHA-256, or of the mechanism `authMechanism` sets, and the reply
//! answers it. Otherwise saslStart goes after hello, with the mechanism
//! set, or chosen by the server's list of the user's mechanisms
//! (`saslSupportedMechs`): SCRAM-SHA-256 when the list names it, else
//! SCRAM-SHA-1. The client asks the server to skip the empty exchange at
//! the end, and takes one more round from a server that does not.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mongo = @import("mongo");
const bson = mongo.bson;
const wire = mongo.wire;
const Diagnostics = mongo.Diagnostics;
const Credentials = @import("../OwnedOptions.zig").Credentials;
const Connection = @import("Connection.zig");
const KeyCache = @import("KeyCache.zig");
const scram = @import("scram.zig");
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

/// What every new connection of a client sends in hello, and who it
/// authenticates as.
pub const Setup = struct {
    /// The `client` document of hello, from `metadata`.
    metadata: bson.RawDocument,
    /// The user; null: the connection does not authenticate.
    auth: ?Auth = null,
};

pub const Auth = struct {
    credentials: Credentials,
    /// The client's keys, which every connection of it shares.
    keys: *KeyCache,
};

pub const Error = error{
    /// The server closed the connection, its reply broke OP_MSG, or it
    /// answered hello with ok 0; the diagnostics say which.
    Unavailable,
    /// The server is not a standalone mongod of MongoDB 7.0 or later, or
    /// SCRAM-SHA-256 cannot take the password.
    Unsupported,
    /// The server refused the user, or broke SCRAM: a nonce that is not
    /// the client's, fewer than 4096 iterations, a wrong signature.
    AuthenticationFailed,
    OutOfMemory,
    /// The task was canceled, and stays canceled.
    Canceled,
};

/// Sends hello on `conn`, checks the reply, and authenticates when
/// `setup` names a user. The connection keeps the server's limits, its id
/// of the connection and the round trip of hello.
pub fn run(conn: *Connection, setup: Setup, gpa: Allocator, d: ?*Diagnostics) Error!void {
    const io = conn.stream.io;
    var opening: Opening = try .init(io, gpa, setup.auth, d);
    defer opening.deinit(gpa);
    const hello = command(gpa, setup.metadata, opening.params()) catch |err| return unwritable(err, d);
    defer hello.deinit();
    const start = time.now(io);
    const reply = conn.exchange(.{ .database = "admin", .body = hello.raw() }, gpa, null, d) catch |err| {
        if (d) |x| x.phase = .handshake;
        return switch (err) {
            error.Interrupted => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
            error.ConnectionLost => {
                // The end of the stream, or a reset: what a server that
                // wants TLS does to a plain hello.
                const closed = if (conn.stream.err) |cause| cause == error.ConnectionResetByPeer else true;
                if (closed) if (d) |x| x.set(.handshake, null, "the server at {f} closed the connection during hello; a server that requires TLS does so, and v0.1 does not speak TLS", .{conn.address});
                markOverloaded(d);
                return error.Unavailable;
            },
            else => error.Unavailable,
        };
    };
    defer reply.deinit();
    conn.rtt = start.durationTo(time.now(io));
    conn.hello = try check(reply.raw(), conn.address, gpa, d);
    if (setup.auth) |auth| try authenticate(conn, auth, reply.raw(), &opening, gpa, d);
}

/// Gives `d` the errorLabels that CMAP gives, since 2026, to a network
/// error or a timeout while a connection opens, before authentication:
/// SystemOverloadedError and RetryableError, since the server may be
/// overloaded and the call may go again. They go to `Diagnostics.server`,
/// with code 0: no server answered.
pub fn markOverloaded(d: ?*Diagnostics) void {
    const x = d orelse return;
    x.server = .{ .code = 0, .labels = .initMany(&.{ .system_overloaded_error, .retryable_error }) };
}

/// What hello carries for authentication: the user whose mechanisms the
/// server lists, when no mechanism is set, and the first message of a
/// speculative conversation.
const Opening = struct {
    /// "<database>.<user>", for `saslSupportedMechs`.
    user: ?[]u8 = null,
    conversation: ?scram.Conversation = null,
    /// The speculative saslStart, which names the user's database.
    first: ?bson.OwnedDocument = null,

    fn init(io: Io, gpa: Allocator, auth: ?Auth, d: ?*Diagnostics) Error!Opening {
        const c = (auth orelse return .{}).credentials;
        var o: Opening = .{};
        errdefer o.deinit(gpa);
        if (c.mechanism == null) o.user = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ c.source, c.username });
        // Without a mechanism set, SCRAM-SHA-256, as the specification
        // asks; nothing speculative with a password it cannot take.
        const mechanism = c.mechanism orelse .scram_sha_256;
        scram.checkPassword(mechanism, c.password, null, null) catch return o;
        o.conversation = try startConversation(io, gpa, mechanism, c.username, d);
        o.first = saslStart(gpa, mechanism, o.conversation.?.message(), c.source) catch |err| return unwritable(err, d);
        return o;
    }

    fn params(o: *const Opening) Params {
        return .{
            .sasl_supported_mechs = o.user,
            .speculative_authenticate = if (o.first) |first| first.raw() else null,
        };
    }

    fn deinit(o: *Opening, gpa: Allocator) void {
        if (o.user) |user| gpa.free(user);
        if (o.conversation) |*conversation| conversation.deinit();
        if (o.first) |first| first.deinit();
        o.* = .{};
    }
};

/// The conversation of SCRAM on `conn`: from the speculative one of hello
/// when the server answered it, else from saslStart. It succeeds when the
/// server's signature checks out and the server says it is done.
fn authenticate(conn: *Connection, auth: Auth, hello: bson.RawDocument, opening: *Opening, gpa: Allocator, d: ?*Diagnostics) Error!void {
    const c = auth.credentials;
    var owned: ?scram.Conversation = null;
    defer if (owned) |*conversation| conversation.deinit();
    // The reply that holds the server's first message, when saslStart went.
    var started: ?bson.OwnedDocument = null;
    defer if (started) |reply| reply.deinit();
    var first: Step = undefined;
    if (opening.conversation != null and speculativeAnswer(hello) != null) {
        owned = opening.conversation;
        opening.conversation = null;
        first = try readStep(speculativeAnswer(hello).?, d);
    } else {
        const mechanism = c.mechanism orelse chooseMechanism(hello);
        try scram.checkPassword(mechanism, c.password, .authenticate, d);
        owned = try startConversation(conn.stream.io, gpa, mechanism, c.username, d);
        const body = saslStart(gpa, mechanism, owned.?.message(), null) catch |err| return unwritable(err, d);
        defer body.deinit();
        started = try sasl(conn, c.source, body.raw(), gpa, d);
        first = try readStep(started.?.raw(), d);
    }
    const conversation = &owned.?;
    if (first.done) return authFailed(d, "the server ended the conversation of SCRAM before the client's proof", .{});
    const challenge = try conversation.challenge(gpa, first.payload, d);
    defer challenge.deinit(gpa);
    var digest: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &digest);
    const password = scram.saltingPassword(conversation.mechanism, c.username, c.password, &digest);
    var keys = auth.keys.get(conn.stream.io, conversation.mechanism, password, challenge.salt, challenge.iterations);
    defer keys.wipe();
    const proof = try conversation.prove(first.payload, challenge, keys);
    defer gpa.free(proof);
    const proved = try continueWith(conn, c.source, first.conversation_id, proof, gpa, d);
    defer proved.deinit();
    const last = try readStep(proved.raw(), d);
    try conversation.verify(last.payload, d);
    if (last.done) return;
    // A server that does not skip the empty exchange: one more round.
    const ended = try continueWith(conn, c.source, first.conversation_id, "", gpa, d);
    defer ended.deinit();
    if (!(try readStep(ended.raw(), d)).done) return authFailed(d, "the server did not end the conversation of SCRAM after its signature", .{});
}

fn startConversation(io: Io, gpa: Allocator, mechanism: scram.Mechanism, username: []const u8, d: ?*Diagnostics) Error!scram.Conversation {
    return scram.Conversation.start(gpa, io, mechanism, username) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.EntropyUnavailable => {
            if (d) |x| x.set(.authenticate, err, "the system gave no random bytes for the nonce of SCRAM", .{});
            return error.Unavailable;
        },
    };
}

/// The mechanism that the server's list of the user's mechanisms picks:
/// SCRAM-SHA-256 when the list names it, else SCRAM-SHA-1, even without a
/// list, as for a user the server does not know.
fn chooseMechanism(hello: bson.RawDocument) scram.Mechanism {
    const list = (hello.get("saslSupportedMechs") catch null) orelse return .scram_sha_1;
    if (list != .array) return .scram_sha_1;
    var it = list.array.iterator();
    while (it.next() catch null) |element| {
        if (element.value == .string and std.mem.eql(u8, element.value.string, "SCRAM-SHA-256")) return .scram_sha_256;
    }
    return .scram_sha_1;
}

/// The server's answer to the speculative saslStart: hello's
/// `speculativeAuthenticate`, a reply to saslStart without its ok.
fn speculativeAnswer(hello: bson.RawDocument) ?bson.RawDocument {
    const value = (hello.get("speculativeAuthenticate") catch null) orelse return null;
    return if (value == .document) value.document else null;
}

/// One step of a SASL conversation: the server's reply to saslStart or
/// saslContinue, or its speculative answer in hello.
const Step = struct {
    conversation_id: i32,
    done: bool,
    /// The server's message of SCRAM: a slice of the reply.
    payload: []const u8,
};

fn readStep(reply: bson.RawDocument, d: ?*Diagnostics) error{AuthenticationFailed}!Step {
    var id: ?i32 = null;
    var done: ?bool = null;
    var payload: ?[]const u8 = null;
    var it = reply.iterator();
    while (it.next() catch null) |element| {
        const value = element.value;
        if (std.mem.eql(u8, element.key, "conversationId")) {
            id = if (value.asI64()) |n| std.math.cast(i32, n) else |_| null;
        } else if (std.mem.eql(u8, element.key, "done")) {
            if (value == .boolean) done = value.boolean;
        } else if (std.mem.eql(u8, element.key, "payload")) {
            if (value == .binary) payload = value.binary.bytes;
        }
    }
    return .{
        .conversation_id = id orelse return authFailed(d, "the server's reply in SCRAM has no conversationId", .{}),
        .done = done orelse return authFailed(d, "the server's reply in SCRAM has no done", .{}),
        .payload = payload orelse return authFailed(d, "the server's reply in SCRAM has no payload", .{}),
    };
}

/// saslStart: the mechanism, the client's first message and
/// skipEmptyExchange; the speculative one in hello also names the user's
/// database, `db`.
fn saslStart(gpa: Allocator, mechanism: scram.Mechanism, payload: []const u8, db: ?[]const u8) bson.Builder.Error!bson.OwnedDocument {
    var b: bson.Builder = .init(gpa);
    defer b.deinit();
    try b.putInt32("saslStart", 1);
    try b.putString("mechanism", mechanism.name());
    try b.putBinary("payload", .{ .subtype = .generic, .bytes = payload });
    try b.beginDocument("options");
    try b.putBoolean("skipEmptyExchange", true);
    try b.end();
    if (db) |name| try b.putString("db", name);
    return b.finish();
}

fn saslContinue(gpa: Allocator, conversation_id: i32, payload: []const u8) bson.Builder.Error!bson.OwnedDocument {
    var b: bson.Builder = .init(gpa);
    defer b.deinit();
    try b.putInt32("saslContinue", 1);
    try b.putInt32("conversationId", conversation_id);
    try b.putBinary("payload", .{ .subtype = .generic, .bytes = payload });
    return b.finish();
}

/// saslContinue with `payload` on the user's database, and the server's
/// reply.
fn continueWith(conn: *Connection, db: []const u8, conversation_id: i32, payload: []const u8, gpa: Allocator, d: ?*Diagnostics) Error!bson.OwnedDocument {
    const body = saslContinue(gpa, conversation_id, payload) catch |err| return unwritable(err, d);
    defer body.deinit();
    return sasl(conn, db, body.raw(), gpa, d);
}

/// One SASL command on `conn`, to the user's database. ok 0 is the
/// server's refusal: code 18 (AuthenticationFailed), 334
/// (MechanismUnavailable) and the rest.
fn sasl(conn: *Connection, db: []const u8, body: bson.RawDocument, gpa: Allocator, d: ?*Diagnostics) Error!bson.OwnedDocument {
    const reply = conn.exchange(.{ .database = db, .body = body }, gpa, null, d) catch |err| {
        if (d) |x| x.phase = .authenticate;
        return switch (err) {
            error.Interrupted => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
            else => error.Unavailable,
        };
    };
    wire.checkReply(reply.raw(), gpa, d, null) catch |err| {
        reply.deinit();
        if (d) |x| x.phase = .authenticate;
        return if (err == error.OutOfMemory) error.OutOfMemory else error.AuthenticationFailed;
    };
    return reply;
}

/// The error of a command of the handshake that cannot be built: memory
/// ran out. Its strings are the driver's own, so it is never invalid BSON.
fn unwritable(err: bson.Builder.Error, d: ?*Diagnostics) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidBson => {
            if (d) |x| x.set(.handshake, null, "a command of the handshake cannot be written as BSON", .{});
            return error.Unavailable;
        },
    };
}

fn authFailed(d: ?*Diagnostics, comptime fmt: []const u8, args: anytype) error{AuthenticationFailed} {
    if (d) |x| x.set(.authenticate, null, fmt, args);
    return error.AuthenticationFailed;
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
