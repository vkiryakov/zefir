//! mongod's side of authentication for the protocol tests: one user, the
//! server's half of SCRAM with the checks mongod makes of the client's
//! proof, and hello, saslStart and saslContinue answered as the fields
//! below say, on `mongo.testing.FakeServer.Peer`. It records what came in
//! `seen`.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const crypto = std.crypto;
const base64 = std.base64.standard;
const mongo = @import("../root.zig");
const bson = mongo.bson;
const opmsg = @import("../wire.zig").opmsg;
const FakeServer = mongo.testing.FakeServer;
const Script = mongo.testing.Script;
const scram = @import("../engine/scram.zig");
const Mechanism = scram.Mechanism;
const ScramServer = @This();

user: []const u8 = "app",
/// The password as the user's client knows it.
password: []const u8 = "secret",
/// The database the user is defined in.
source: []const u8 = "admin",
/// The user's credentials: hello lists them, and saslStart with another
/// mechanism is refused with code 334, as mongod refuses it.
mechanisms: []const Mechanism = &.{ .scram_sha_1, .scram_sha_256 },
salt: []const u8 = "zefir-test-salt.",
iterations: u32 = 4096,
/// Answer the speculative saslStart of hello; false: leave the answer
/// out, as a server that does not take it.
speculative: bool = true,
/// Answer hello's saslSupportedMechs; false: leave it out, as mongod
/// does for a user that is not there.
list_mechanisms: bool = true,
/// End the conversation with the server's signature, as servers do when
/// the client asks for skipEmptyExchange; false: one more round with an
/// empty payload after it, as servers did before.
skip_empty_exchange: bool = true,
/// Refuse saslStart with this code.
refuse: ?i32 = null,
tamper: Tamper = .none,
seen: Seen = .{},

/// How the server breaks its side of SCRAM.
pub const Tamper = enum {
    none,
    /// The nonce of its first message does not extend the client's.
    foreign_nonce,
    /// Its signature is not the one its keys give.
    wrong_signature,
    /// It ends the conversation without its signature.
    no_signature,
    /// It hangs up when the proof comes.
    hang_up,
    /// It hangs up when saslStart comes.
    hang_up_at_start,
    /// It reads saslStart and answers nothing, until the client hangs up.
    stall_at_start,
};

/// What came after hello, in order.
pub const Step = enum { sasl_start, sasl_continue, sasl_continue_empty, ping, other };

pub const Seen = struct {
    steps: [8]Step = undefined,
    len: usize = 0,
    /// The mechanism of the last saslStart.
    mechanism: ?Mechanism = null,
    /// The mechanism of the speculative saslStart in hello.
    speculative: ?Mechanism = null,
    /// The speculative saslStart was one: saslStart first, with
    /// skipEmptyExchange and the user's database.
    speculative_shape: bool = false,
    /// The value of hello's saslSupportedMechs.
    asked_for: Text = .{},
    /// The user in the client's first message, as it came.
    sasl_name: Text = .{},
    /// `$db` of the last SASL command.
    database: Text = .{},
    /// Every saslStart asked for skipEmptyExchange.
    skip_empty_asked: bool = true,

    pub fn sequence(s: *const Seen) []const Step {
        return s.steps[0..s.len];
    }

    fn add(s: *Seen, step: Step) void {
        if (s.len < s.steps.len) {
            s.steps[s.len] = step;
            s.len += 1;
        }
    }
};

pub const Text = struct {
    buffer: [512]u8 = undefined,
    len: usize = 0,
    present: bool = false,

    fn set(t: *Text, text: []const u8) void {
        t.len = @min(text.len, t.buffer.len);
        @memcpy(t.buffer[0..t.len], text[0..t.len]);
        t.present = true;
    }

    pub fn slice(t: *const Text) ?[]const u8 {
        return if (t.present) t.buffer[0..t.len] else null;
    }
};

/// The server's state of one conversation.
const Exchange = struct {
    mechanism: Mechanism,
    keys: scram.Keys,
    /// client-first-message-bare, ",", server-first-message: the start of
    /// AuthMessage.
    head: Text = .{},
    /// The client's nonce and the server's.
    nonce: Text = .{},
    server_first: Text = .{},
    state: enum { proving, finishing, done } = .proving,
};

/// Accepts `connections` clients, one after another, and plays the
/// server's side of each until the client hangs up or a command named
/// `breakme` comes.
pub fn serve(s: *ScramServer, io: Io, listener: *net.Server, connections: usize) !void {
    for (0..connections) |_| {
        var peer: FakeServer.Peer = undefined;
        try peer.accept(io, listener);
        defer peer.close();
        try s.serveConnection(&peer);
    }
}

fn serveConnection(s: *ScramServer, peer: *FakeServer.Peer) !void {
    var exchange: ?Exchange = null;
    var handshaken = false;
    while (true) {
        const incoming = (try peer.readRequest(testing.allocator)) orelse return;
        defer incoming.deinit();
        const request: Script.Request = .of(0, &incoming);
        var b: bson.Builder = .init(testing.allocator);
        defer b.deinit();
        if (!handshaken) {
            handshaken = true;
            try s.hello(&b, &request, &exchange);
        } else if (std.mem.eql(u8, request.name, "saslStart")) {
            s.seen.add(.sasl_start);
            s.seen.database.set(request.database);
            switch (s.tamper) {
                .hang_up_at_start => return,
                .stall_at_start => {
                    _ = try peer.readToEnd();
                    return;
                },
                else => {},
            }
            try s.saslStart(&b, request.body, &exchange);
        } else if (std.mem.eql(u8, request.name, "saslContinue")) {
            s.seen.database.set(request.database);
            const payload = binary(request.body, "payload") orelse "";
            s.seen.add(if (payload.len == 0) .sasl_continue_empty else .sasl_continue);
            if (s.tamper == .hang_up) return;
            try s.saslContinue(&b, payload, &exchange);
        } else if (std.mem.eql(u8, request.name, "breakme")) {
            s.seen.add(.other);
            return;
        } else {
            s.seen.add(if (std.mem.eql(u8, request.name, "ping")) .ping else .other);
            try b.putDouble("ok", 1);
        }
        const reply = try b.finish();
        defer reply.deinit();
        try peer.reply(&incoming, reply.raw());
    }
}

/// The reply to hello: a standalone mongod of MongoDB 7.0, with what
/// authentication asked for.
fn hello(s: *ScramServer, b: *bson.Builder, request: *const Script.Request, exchange: *?Exchange) !void {
    try b.putBoolean("helloOk", true);
    try b.putBoolean("ismaster", true);
    try b.putInt32("maxBsonObjectSize", 16 * 1024 * 1024);
    try b.putInt32("maxMessageSizeBytes", 48_000_000);
    try b.putInt32("maxWriteBatchSize", 100_000);
    try b.putInt32("connectionId", 1);
    try b.putInt32("minWireVersion", 0);
    try b.putInt32("maxWireVersion", 21);
    if (string(request.body, "saslSupportedMechs")) |asked| {
        s.seen.asked_for.set(asked);
        if (s.list_mechanisms) {
            try b.beginArray("saslSupportedMechs");
            for (s.mechanisms) |m| try b.putString("", m.name());
            try b.end();
        }
    }
    if (document(request.body, "speculativeAuthenticate")) |first| {
        const mechanism = mechanismOf(first);
        s.seen.speculative = mechanism;
        const db = string(first, "db") orelse "";
        s.seen.speculative_shape = std.mem.eql(u8, db, s.source) and std.mem.eql(u8, firstKey(first), "saslStart") and skipsEmpty(first);
        if (s.speculative and s.refuse == null and mechanism != null and s.has(mechanism.?)) {
            if (try s.start(mechanism.?, binary(first, "payload") orelse "")) |started| {
                exchange.* = started;
                try b.beginDocument("speculativeAuthenticate");
                try putStep(b, false, started.server_first.slice().?);
                try b.end();
            }
        }
    }
    try b.putDouble("ok", 1);
}

fn saslStart(s: *ScramServer, b: *bson.Builder, body: bson.RawDocument, exchange: *?Exchange) !void {
    const mechanism = mechanismOf(body);
    s.seen.mechanism = mechanism;
    if (!skipsEmpty(body)) s.seen.skip_empty_asked = false;
    if (s.refuse) |code| return failure(b, code);
    if (mechanism == null or !s.has(mechanism.?)) return failure(b, 334);
    exchange.* = try s.start(mechanism.?, binary(body, "payload") orelse "") orelse return failure(b, 18);
    try putStep(b, false, exchange.*.?.server_first.slice().?);
    try b.putDouble("ok", 1);
}

fn saslContinue(s: *ScramServer, b: *bson.Builder, payload: []const u8, exchange: *?Exchange) !void {
    const ex = if (exchange.*) |*e| e else return failure(b, 17);
    switch (ex.state) {
        .proving => {
            var signature: [scram.max_mac_length]u8 = undefined;
            const len = s.check(ex, payload, &signature) orelse return failure(b, 18);
            switch (s.tamper) {
                .wrong_signature => signature[0] ^= 1,
                else => {},
            }
            var encoded: [base64.Encoder.calcSize(scram.max_mac_length)]u8 = undefined;
            var text: [2 + encoded.len]u8 = undefined;
            const final = if (s.tamper == .no_signature) "" else try std.fmt.bufPrint(&text, "v={s}", .{base64.Encoder.encode(&encoded, signature[0..len])});
            ex.state = if (s.skip_empty_exchange) .done else .finishing;
            try putStep(b, s.skip_empty_exchange or s.tamper == .no_signature, final);
        },
        .finishing => {
            if (payload.len != 0) return failure(b, 17);
            ex.state = .done;
            try putStep(b, true, "");
        },
        .done => return failure(b, 17),
    }
    try b.putDouble("ok", 1);
}

/// Starts a conversation from the client's first message; null when it
/// is not for this user.
fn start(s: *ScramServer, mechanism: Mechanism, client_first: []const u8) !?Exchange {
    if (!std.mem.startsWith(u8, client_first, "n,,n=")) return null;
    const bare = client_first["n,,".len..];
    const at = std.mem.find(u8, bare, ",r=") orelse return null;
    const name = bare["n=".len..at];
    const client_nonce = bare[at + ",r=".len ..];
    s.seen.sasl_name.set(name);
    var escaped: [64]u8 = undefined;
    if (!std.mem.eql(u8, name, escape(s.user, &escaped))) return null;
    var ex: Exchange = .{ .mechanism = mechanism, .keys = undefined };
    var nonce: [160]u8 = undefined;
    ex.nonce.set(try std.fmt.bufPrint(&nonce, "{s}3rfcNHYJY1ZVvWVs7j", .{if (s.tamper == .foreign_nonce) "someone-else" else client_nonce}));
    var salt: [64]u8 = undefined;
    var first: [256]u8 = undefined;
    ex.server_first.set(try std.fmt.bufPrint(&first, "r={s},s={s},i={d}", .{ ex.nonce.slice().?, base64.Encoder.encode(&salt, s.salt), s.iterations }));
    var head: [512]u8 = undefined;
    ex.head.set(try std.fmt.bufPrint(&head, "{s},{s}", .{ bare, ex.server_first.slice().? }));
    var digest: [32]u8 = undefined;
    ex.keys = scram.deriveKeys(mechanism, scram.saltingPassword(mechanism, s.user, s.password, &digest), s.salt, s.iterations);
    return ex;
}

/// Checks the client's proof in client-final-message, as mongod does:
/// the proof XOR ClientSignature must hash to StoredKey. Returns the
/// length of ServerSignature, written to `signature`, or null.
fn check(s: *const ScramServer, ex: *const Exchange, client_final: []const u8, signature: *[scram.max_mac_length]u8) ?usize {
    _ = s;
    const at = std.mem.find(u8, client_final, ",p=") orelse return null;
    const without_proof = client_final[0..at];
    var expected: [192]u8 = undefined;
    if (!std.mem.eql(u8, without_proof, std.fmt.bufPrint(&expected, "c=biws,r={s}", .{ex.nonce.slice().?}) catch return null)) return null;
    switch (ex.mechanism) {
        inline else => |m| {
            const H = Hmac(m);
            const len = H.mac_length;
            var proof: [len]u8 = undefined;
            const text = client_final[at + ",p=".len ..];
            if ((base64.Decoder.calcSizeForSlice(text) catch return null) != len) return null;
            base64.Decoder.decode(&proof, text) catch return null;
            var stored: [len]u8 = undefined;
            Hash(m).hash(ex.keys.client[0..len], &stored, .{});
            var client_signature: [len]u8 = undefined;
            var mac = H.init(&stored);
            mac.update(ex.head.slice().?);
            mac.update(",");
            mac.update(without_proof);
            mac.final(&client_signature);
            var client_key: [len]u8 = undefined;
            for (&client_key, proof, client_signature) |*k, p, c| k.* = p ^ c;
            var hashed: [len]u8 = undefined;
            Hash(m).hash(&client_key, &hashed, .{});
            if (!std.mem.eql(u8, &hashed, &stored)) return null;
            mac = H.init(ex.keys.server[0..len]);
            mac.update(ex.head.slice().?);
            mac.update(",");
            mac.update(without_proof);
            mac.final(signature[0..len]);
            return len;
        },
    }
}

fn has(s: *const ScramServer, mechanism: Mechanism) bool {
    for (s.mechanisms) |m| {
        if (m == mechanism) return true;
    }
    return false;
}

fn Hash(comptime m: Mechanism) type {
    return switch (m) {
        .scram_sha_1 => crypto.hash.Sha1,
        .scram_sha_256 => crypto.hash.sha2.Sha256,
    };
}

fn Hmac(comptime m: Mechanism) type {
    return crypto.auth.hmac.Hmac(Hash(m));
}

/// `name` as SCRAM writes a user: ',' as "=2C" and '=' as "=3D".
fn escape(name: []const u8, buffer: []u8) []const u8 {
    var w: Io.Writer = .fixed(buffer);
    for (name) |c| switch (c) {
        ',' => w.writeAll("=2C") catch return "",
        '=' => w.writeAll("=3D") catch return "",
        else => w.writeByte(c) catch return "",
    };
    return w.buffered();
}

/// conversationId, done and payload, as mongod answers a SASL command.
fn putStep(b: *bson.Builder, done: bool, payload: []const u8) !void {
    try b.putInt32("conversationId", 1);
    try b.putBoolean("done", done);
    try b.putBinary("payload", .{ .subtype = .generic, .bytes = payload });
}

/// A refusal as mongod writes one.
fn failure(b: *bson.Builder, code: i32) !void {
    const name, const errmsg = switch (code) {
        18 => .{ "AuthenticationFailed", "Authentication failed." },
        334 => .{ "MechanismUnavailable", "Unable to use SCRAM-SHA-256 based authentication for user without any SCRAM-SHA-256 credentials registered" },
        else => .{ "ProtocolError", "No SASL session state found" },
    };
    try b.putDouble("ok", 0);
    try b.putString("errmsg", errmsg);
    try b.putInt32("code", code);
    try b.putString("codeName", name);
}

fn mechanismOf(doc: bson.RawDocument) ?Mechanism {
    const name = string(doc, "mechanism") orelse return null;
    for (std.enums.values(Mechanism)) |m| {
        if (std.mem.eql(u8, name, m.name())) return m;
    }
    return null;
}

fn skipsEmpty(doc: bson.RawDocument) bool {
    const options = document(doc, "options") orelse return false;
    const value = (options.get("skipEmptyExchange") catch null) orelse return false;
    return value == .boolean and value.boolean;
}

fn firstKey(doc: bson.RawDocument) []const u8 {
    return if (doc.first() catch null) |element| element.key else "";
}

fn string(doc: bson.RawDocument, key: []const u8) ?[]const u8 {
    const value = (doc.get(key) catch null) orelse return null;
    return if (value == .string) value.string else null;
}

fn document(doc: bson.RawDocument, key: []const u8) ?bson.RawDocument {
    const value = (doc.get(key) catch null) orelse return null;
    return if (value == .document) value.document else null;
}

fn binary(doc: bson.RawDocument, key: []const u8) ?[]const u8 {
    const value = (doc.get(key) catch null) orelse return null;
    return if (value == .binary) value.binary.bytes else null;
}
