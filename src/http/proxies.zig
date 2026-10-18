//! The client behind proxies. `.trusted_proxies`
//! says which peers the server believes when they name the client in
//! `X-Forwarded-For` or `Forwarded` (RFC 7239), and whose `X-Request-Id`
//! it takes: everybody (`.all`, the default), loopback and private networks
//! (`.private`), nobody (`.none`), or a list of CIDR blocks.
//!
//! Each proxy appends the address it got the request from, so the entries
//! on the right of `X-Forwarded-For` come from the trusted proxies, and the
//! first entry from the right that is not trusted is the client; with
//! `.all` every entry is trusted, so the client is the leftmost one. An
//! entry that is no address ends the walk at the trusted entry right of it.
//! `Forwarded` is read the same way, only when there is no
//! `X-Forwarded-For`. A peer that is not trusted names nobody: the client is
//! the peer itself. A service open to the internet without a proxy sets
//! `.none`, or a client forges its address with a header.
const std = @import("std");
const h1 = @import("h1/head.zig");

const Allocator = std.mem.Allocator;
const IpAddress = std.Io.net.IpAddress;

/// From whom to believe `X-Forwarded-For` and `Forwarded`: everybody,
/// loopback and private networks (127.0.0.0/8, ::1, 10.0.0.0/8,
/// 172.16.0.0/12, 192.168.0.0/16, fc00::/7), nobody, or a list of CIDR
/// blocks such as `.{ .list = &.{"10.1.0.0/16"} }`, which `Server.init`
/// copies and checks.
pub const TrustedProxies = union(enum) {
    all,
    private,
    none,
    list: []const []const u8,
};

/// An address as the checks compare it. An IPv4-mapped IPv6 address
/// (`::ffff:10.0.0.1`, how a dual-stack socket sees an IPv4 client) is the
/// IPv4 address.
pub const Address = struct {
    /// 4 bytes for IPv4, then zeros; 16 for IPv6.
    bytes: [16]u8 = @splat(0),
    ip6: bool,

    pub fn of(raw: IpAddress) Address {
        return switch (raw) {
            .ip4 => |a| ip4(a.bytes),
            .ip6 => |a| if (std.mem.eql(u8, a.bytes[0..12], &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff }))
                ip4(a.bytes[12..16].*)
            else
                .{ .bytes = a.bytes, .ip6 = true },
        };
    }

    fn ip4(bytes: [4]u8) Address {
        var a: Address = .{ .ip6 = false };
        a.bytes[0..4].* = bytes;
        return a;
    }
};

/// A block of addresses, "10.1.0.0/16" or "fc00::/7"; an address alone is
/// a block of one.
pub const Cidr = struct {
    /// The network, its bits past `bits` zero.
    network: Address,
    bits: u8,

    /// `text` as a block: an IPv4 or IPv6 address, then '/' and the length
    /// of the prefix (at most 32 or 128); the bits of the address past the
    /// prefix are dropped.
    pub fn parse(text: []const u8) error{InvalidCidr}!Cidr {
        const slash = std.mem.findScalar(u8, text, '/');
        const address_text = text[0 .. slash orelse text.len];
        const network: Address = if (IpAddress.parseIp4(address_text, 0)) |a|
            .ip4(a.ip4.bytes)
        else |_| if (IpAddress.parseIp6(address_text, 0)) |a|
            .{ .bytes = a.ip6.bytes, .ip6 = true }
        else |_|
            return error.InvalidCidr;
        const most: u8 = if (network.ip6) 128 else 32;
        const bits: u8 = if (slash) |at| bits: {
            const digits = text[at + 1 ..];
            if (digits.len == 0 or digits.len > 3) return error.InvalidCidr;
            for (digits) |c| if (!std.ascii.isDigit(c)) return error.InvalidCidr;
            const n = std.fmt.parseInt(u8, digits, 10) catch return error.InvalidCidr;
            if (n > most) return error.InvalidCidr;
            break :bits n;
        } else most;
        var block: Cidr = .{ .network = network, .bits = bits };
        for (&block.network.bytes, 0..) |*byte, i| byte.* &= maskByte(bits, i);
        return block;
    }

    pub fn contains(c: Cidr, a: Address) bool {
        if (c.network.ip6 != a.ip6) return false;
        for (c.network.bytes, a.bytes, 0..) |net, byte, i| {
            if (byte & maskByte(c.bits, i) != net) return false;
        }
        return true;
    }

    /// The bits of byte `i` that a prefix of `bits` covers.
    fn maskByte(bits: u8, i: usize) u8 {
        const start = i * 8;
        if (bits >= start + 8) return 0xff;
        if (bits <= start) return 0;
        return @as(u8, 0xff) << @intCast(start + 8 - bits);
    }
};

/// `.private`: loopback and the private networks.
const private_blocks = [_]Cidr{
    ip4Block(.{ 127, 0, 0, 0 }, 8),
    ip4Block(.{ 10, 0, 0, 0 }, 8),
    ip4Block(.{ 172, 16, 0, 0 }, 12),
    ip4Block(.{ 192, 168, 0, 0 }, 16),
    .{ .network = .{ .bytes = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, .ip6 = true }, .bits = 128 },
    .{ .network = .{ .bytes = .{ 0xfc, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .ip6 = true }, .bits = 7 },
};

fn ip4Block(bytes: [4]u8, bits: u8) Cidr {
    return .{ .network = .ip4(bytes), .bits = bits };
}

/// `.trusted_proxies` as the server checks it, the list parsed.
pub const Trust = union(enum) {
    all,
    private,
    none,
    list: []const Cidr,

    /// `proxies`, a list parsed into `gpa`: an entry that is no CIDR block
    /// and no address is `InvalidConfiguration`.
    pub fn init(gpa: Allocator, proxies: TrustedProxies) error{ InvalidConfiguration, OutOfMemory }!Trust {
        switch (proxies) {
            .all => return .all,
            .private => return .private,
            .none => return .none,
            .list => |list| {
                const blocks = try gpa.alloc(Cidr, list.len);
                errdefer gpa.free(blocks);
                for (blocks, list) |*block, text| block.* = Cidr.parse(text) catch return error.InvalidConfiguration;
                return .{ .list = blocks };
            },
        }
    }

    pub fn deinit(t: Trust, gpa: Allocator) void {
        switch (t) {
            .list => |blocks| gpa.free(blocks),
            else => {},
        }
    }

    /// Whether the server believes the peer `peer`; with `.all`, one
    /// without an address too.
    pub fn trusts(t: *const Trust, peer: ?IpAddress) bool {
        if (t.* == .all) return true;
        return t.trustsAddress(.of(peer orelse return false));
    }

    fn trustsAddress(t: *const Trust, a: Address) bool {
        const blocks: []const Cidr = switch (t.*) {
            .all => return true,
            .none => return false,
            .private => &private_blocks,
            .list => |list| list,
        };
        for (blocks) |block| {
            if (block.contains(a)) return true;
        }
        return false;
    }
};

/// The client of a request whose connection comes from `peer`: the peer
/// itself, unless it is trusted and names the client in `X-Forwarded-For`
/// or, without one, in `Forwarded`. The port of a named client is the one
/// its entry gives, else 0.
pub fn clientAddress(trust: *const Trust, peer: ?IpAddress, fields: []const h1.Field) ?IpAddress {
    if (!trust.trusts(peer)) return peer;
    var walk: Walk = .{ .trust = trust };
    var forwarded_for = false;
    for (fields) |f| {
        if (!std.ascii.eqlIgnoreCase(f.name, "x-forwarded-for")) continue;
        forwarded_for = true;
        var entries = std.mem.splitScalar(u8, f.value, ',');
        while (entries.next()) |entry| {
            const text = std.mem.trim(u8, entry, " \t");
            // Empty elements of a list are no elements (RFC 9110 §5.6.1).
            if (text.len > 0) walk.see(text);
        }
    }
    if (!forwarded_for) {
        for (fields) |f| {
            if (!std.ascii.eqlIgnoreCase(f.name, "forwarded")) continue;
            var at: usize = 0;
            while (nextPart(f.value, &at, ',')) |element| {
                if (element.len > 0) walk.see(forOf(element) orelse "");
            }
        }
    }
    return walk.result(peer);
}

/// The `X-Request-Id` of a request: one field of 1 to 128 visible ASCII
/// characters, else null.
pub fn requestIdOf(fields: []const h1.Field) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (fields) |f| {
        if (!std.ascii.eqlIgnoreCase(f.name, "x-request-id")) continue;
        // Two ids name no request.
        if (found != null) return null;
        found = f.value;
    }
    const id = found orelse return null;
    if (id.len == 0 or id.len > 128) return null;
    for (id) |c| if (c < 0x21 or c > 0x7e) return null;
    return id;
}

/// The entries of the hops from the left, giving what a walk from the
/// right gives: the first entry from the right that is not trusted; after
/// an entry that is no address, the trusted entry right of it (or the
/// peer); the leftmost entry when every entry is trusted.
const Walk = struct {
    trust: *const Trust,
    seen: usize = 0,
    leftmost: ?IpAddress = null,
    /// The rightmost entry so far that is not trusted.
    stop: union(enum) {
        none,
        untrusted: IpAddress,
        /// No address: the trusted entry right of it, once there is one.
        invalid: ?IpAddress,
    } = .none,

    fn see(w: *Walk, text: []const u8) void {
        defer w.seen += 1;
        const hop = parseAddress(text) orelse {
            w.stop = .{ .invalid = null };
            return;
        };
        if (w.seen == 0) w.leftmost = hop;
        if (!w.trust.trustsAddress(.of(hop))) {
            w.stop = .{ .untrusted = hop };
        } else if (w.stop == .invalid and w.stop.invalid == null) {
            w.stop = .{ .invalid = hop };
        }
    }

    fn result(w: *const Walk, peer: ?IpAddress) ?IpAddress {
        return switch (w.stop) {
            .none => if (w.seen == 0) peer else w.leftmost,
            .untrusted => |hop| hop,
            .invalid => |right| right orelse peer,
        };
    }
};

/// An address as a header names it: "192.0.2.60", "192.0.2.60:4711",
/// "[2001:db8::17]:4711", "[2001:db8::17]" or "2001:db8::17".
fn parseAddress(text: []const u8) ?IpAddress {
    if (text.len == 0) return null;
    if (IpAddress.parseLiteral(text)) |a| return a else |_| {}
    return IpAddress.parseIp6(text, 0) catch null;
}

/// The `for` of an element of `Forwarded` (`for=192.0.2.60;proto=http`),
/// without its quotes; null without one.
fn forOf(element: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (nextPart(element, &at, ';')) |pair| {
        const eq = std.mem.findScalar(u8, pair, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, pair[0..eq], " \t"), "for")) continue;
        const value = std.mem.trim(u8, pair[eq + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            const inner = value[1 .. value.len - 1];
            // An escape has no place in an address.
            return if (std.mem.findScalar(u8, inner, '\\') == null) inner else "";
        }
        return value;
    }
    return null;
}

/// The next part of `text` from `at.*` up to `separator` outside quoted
/// strings, trimmed; null at the end.
fn nextPart(text: []const u8, at: *usize, separator: u8) ?[]const u8 {
    if (at.* > text.len) return null;
    const start = at.*;
    var quoted = false;
    var i = start;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quoted) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') quoted = false;
        } else if (c == '"') {
            quoted = true;
        } else if (c == separator) break;
    }
    const end = @min(i, text.len);
    at.* = end + 1;
    return std.mem.trim(u8, text[start..end], " \t");
}

const testing = std.testing;

/// An address written in a test, which always parses.
fn ip(text: []const u8) IpAddress {
    return parseAddress(text) orelse std.debug.panic("not an address: {s}", .{text});
}

fn expectAddress(expected: ?[]const u8, got: ?IpAddress) !void {
    if (expected == null or got == null) {
        if (expected != null or got != null) std.debug.print("expected {?s}, got {?f}\n", .{ expected, got });
        return testing.expectEqual(expected == null, got == null);
    }
    const want = ip(expected.?);
    testing.expect(want.eql(&got.?)) catch |err| {
        std.debug.print("expected {f}, got {f}\n", .{ want, got.? });
        return err;
    };
}

test "CIDR parsing for IPv4 and IPv6" {
    const ten = try Cidr.parse("10.1.0.0/16");
    try testing.expect(ten.contains(.of(ip("10.1.255.7"))));
    try testing.expect(!ten.contains(.of(ip("10.2.0.1"))));
    // An IPv4-mapped IPv6 address is the IPv4 address.
    try testing.expect(ten.contains(.of(ip("::ffff:10.1.2.3"))));
    try testing.expect(!ten.contains(.of(ip("2001:db8::1"))));
    // The bits past the prefix are dropped; a prefix that ends in a byte.
    const odd = try Cidr.parse("172.31.200.9/12");
    try testing.expect(odd.contains(.of(ip("172.16.0.1"))) and odd.contains(.of(ip("172.31.255.255"))));
    try testing.expect(!odd.contains(.of(ip("172.32.0.0"))) and !odd.contains(.of(ip("172.15.255.255"))));
    // An address alone, /0 and the longest prefixes.
    try testing.expect((try Cidr.parse("192.0.2.1")).contains(.of(ip("192.0.2.1"))));
    try testing.expect(!(try Cidr.parse("192.0.2.1")).contains(.of(ip("192.0.2.2"))));
    try testing.expect((try Cidr.parse("0.0.0.0/0")).contains(.of(ip("203.0.113.5"))));
    try testing.expect((try Cidr.parse("192.0.2.1/32")).contains(.of(ip("192.0.2.1"))));

    const ula = try Cidr.parse("fc00::/7");
    try testing.expect(ula.contains(.of(ip("fd12:3456::1"))) and ula.contains(.of(ip("fc00::"))));
    try testing.expect(!ula.contains(.of(ip("fe80::1"))) and !ula.contains(.of(ip("10.0.0.1"))));
    const doc = try Cidr.parse("2001:db8::/32");
    try testing.expect(doc.contains(.of(ip("2001:db8:ffff::1"))) and !doc.contains(.of(ip("2001:db9::1"))));
    try testing.expect((try Cidr.parse("::1")).contains(.of(ip("::1"))));
    try testing.expect((try Cidr.parse("::/0")).contains(.of(ip("2001:db8::1"))));

    for ([_][]const u8{ "", "/8", "10.0.0.0/", "10.0.0.0/33", "10.0.0.0/-1", "10.0.0.0/+8", "10.0.0/8", "010.0.0.0/8", "10.0.0.0/8/8", "::1/129", "fc00::/x", "[::1]/128", "10.0.0.0/0008", "example.com", "10.0.0.0 /8" }) |text| {
        testing.expectError(error.InvalidCidr, Cidr.parse(text)) catch |err| {
            std.debug.print("{s}\n", .{text});
            return err;
        };
    }
    // The blocks of .private, as parsed.
    for (private_blocks, [_][]const u8{ "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "::1/128", "fc00::/7" }) |block, text| {
        const parsed = try Cidr.parse(text);
        try testing.expectEqual(parsed.bits, block.bits);
        try testing.expectEqualSlices(u8, &parsed.network.bytes, &block.network.bytes);
        try testing.expectEqual(parsed.network.ip6, block.network.ip6);
    }
    // A list from Server.init: an entry that is no block is refused.
    const trust = try Trust.init(testing.allocator, .{ .list = &.{ "10.0.0.0/8", "::1" } });
    defer trust.deinit(testing.allocator);
    try testing.expect(trust.trusts(ip("10.9.9.9")) and trust.trusts(ip("::1")) and !trust.trusts(ip("11.0.0.1")));
    try testing.expectError(error.InvalidConfiguration, Trust.init(testing.allocator, .{ .list = &.{ "10.0.0.0/8", "10.0.0.0/40" } }));
}

test "client address through every trusted_proxies value" {
    const fields = [_]h1.Field{.{ .name = "X-Forwarded-For", .value = "198.51.100.7, 203.0.113.5, 10.0.0.2" }};
    var list_blocks = [_]Cidr{ try Cidr.parse("10.0.0.0/8"), try Cidr.parse("203.0.113.0/24") };
    const all: Trust = .all;
    const private: Trust = .private;
    const none: Trust = .none;
    const list: Trust = .{ .list = &list_blocks };
    const peer = ip("10.0.0.1:41000");
    const outside = ip("192.0.2.9:41000");

    // .all: every hop is trusted, the client is the leftmost entry.
    try expectAddress("198.51.100.7", clientAddress(&all, peer, &fields));
    try expectAddress("198.51.100.7", clientAddress(&all, outside, &fields));
    // .private: the first entry from the right that is not private.
    try expectAddress("203.0.113.5", clientAddress(&private, peer, &fields));
    try expectAddress("192.0.2.9:41000", clientAddress(&private, outside, &fields));
    try expectAddress("[::1]:9", clientAddress(&private, ip("[::1]:9"), &.{}));
    try expectAddress("192.0.2.1", clientAddress(&private, ip("[::ffff:10.0.0.1]:9"), &.{.{ .name = "x-forwarded-for", .value = "192.0.2.1" }}));
    // .none: the peer, whatever it says.
    try expectAddress("10.0.0.1:41000", clientAddress(&none, peer, &fields));
    // A list: its blocks are proxies too.
    try expectAddress("198.51.100.7", clientAddress(&list, peer, &fields));
    try expectAddress("192.0.2.9:41000", clientAddress(&list, outside, &fields));
    // No address of the peer: trusted only by .all.
    try expectAddress("198.51.100.7", clientAddress(&all, null, &fields));
    try expectAddress(null, clientAddress(&private, null, &fields));

    // Several fields are one list; empty elements are none; ports stay.
    try expectAddress("192.0.2.1:8080", clientAddress(&private, peer, &.{
        .{ .name = "x-forwarded-for", .value = "198.51.100.1, 192.0.2.1:8080" },
        .{ .name = "x-forwarded-for", .value = " , 10.0.0.3," },
    }));
    try expectAddress("2001:db8::17", clientAddress(&private, peer, &.{.{ .name = "x-forwarded-for", .value = "2001:db8::17, [fd00::1]:80" }}));
    // An entry that is no address ends the walk at the trusted entry
    // right of it, or the peer.
    try expectAddress("10.0.0.5", clientAddress(&private, peer, &.{.{ .name = "x-forwarded-for", .value = "198.51.100.1, unknown, 10.0.0.5, 10.0.0.6" }}));
    try expectAddress("10.0.0.1:41000", clientAddress(&private, peer, &.{.{ .name = "x-forwarded-for", .value = "198.51.100.1, garbage" }}));
    try expectAddress("10.0.0.5", clientAddress(&all, peer, &.{.{ .name = "x-forwarded-for", .value = "010.0.0.1, 10.0.0.5" }}));
    // Without the headers, or with an empty one: the peer.
    try expectAddress("10.0.0.1:41000", clientAddress(&all, peer, &.{}));
    try expectAddress("10.0.0.1:41000", clientAddress(&all, peer, &.{.{ .name = "x-forwarded-for", .value = "" }}));
}

test "X-Forwarded-For wins over Forwarded" {
    const peer = ip("10.0.0.1:41000");
    const private: Trust = .private;
    // Forwarded alone: for= in each element, IPv6 quoted in brackets.
    try expectAddress("[2001:db8:cafe::17]:4711", clientAddress(&private, peer, &.{
        .{ .name = "Forwarded", .value = "for=\"[2001:db8:cafe::17]:4711\";proto=https, For=10.0.0.9;by=10.0.0.1" },
    }));
    try expectAddress("192.0.2.43", clientAddress(&private, peer, &.{
        .{ .name = "forwarded", .value = "for=198.51.100.1" },
        .{ .name = "forwarded", .value = "proto=http;for=192.0.2.43, for=\"10.0.0.7:80\"" },
    }));
    // A quoted comma or semicolon does not split; unknown and hidden
    // names end the walk.
    try expectAddress("10.0.0.7", clientAddress(&private, peer, &.{
        .{ .name = "forwarded", .value = "for=198.51.100.1;host=\"a,b;c\", for=unknown, for=10.0.0.7" },
    }));
    try expectAddress("10.0.0.1:41000", clientAddress(&private, peer, &.{.{ .name = "forwarded", .value = "for=\"_hidden\"" }}));
    try expectAddress("10.0.0.1:41000", clientAddress(&private, peer, &.{.{ .name = "forwarded", .value = "proto=https" }}));
    // Both: X-Forwarded-For is believed, Forwarded is not read.
    try expectAddress("198.51.100.20", clientAddress(&private, peer, &.{
        .{ .name = "Forwarded", .value = "for=203.0.113.9" },
        .{ .name = "X-Forwarded-For", .value = "198.51.100.20" },
    }));
}

test "X-Request-Id: one field of 1 to 128 visible ASCII characters" {
    try testing.expectEqualStrings("req-42/a:b", requestIdOf(&.{.{ .name = "X-Request-Id", .value = "req-42/a:b" }}) orelse "");
    const longest: []const u8 = &@as([128]u8, @splat('a'));
    try testing.expectEqualStrings(longest, requestIdOf(&.{.{ .name = "x-request-id", .value = longest }}) orelse "");
    for ([_][]const u8{ "", "a b", "a\tb", "caf\xc3\xa9", "a\x7f", &@as([129]u8, @splat('a')) }) |bad| {
        try testing.expectEqual(null, requestIdOf(&.{.{ .name = "x-request-id", .value = bad }}));
    }
    try testing.expectEqual(null, requestIdOf(&.{ .{ .name = "x-request-id", .value = "a" }, .{ .name = "X-Request-ID", .value = "b" } }));
    try testing.expectEqual(null, requestIdOf(&.{}));
}

const Server = @import("Server.zig");
const Context = @import("Context.zig");
const TestingBackend = @import("testing/Backend.zig");
const routes = @import("routes.zig");

const WhoController = struct {
    pub const http_routes = routes.routes(.{ .methods = .{ .who = routes.get("/who", .{}) } });

    /// The client and the request's id.
    pub fn who(_: *WhoController, ctx: *Context) !void {
        try ctx.response.text(try std.fmt.allocPrint(ctx.allocator(), "{?f} {s}", .{ ctx.request.clientAddress(), ctx.requestId() }));
    }
};

/// What `/who` answers to a request from `peer` with `fields`.
fn who(b: *TestingBackend, peer: ?IpAddress, fields: []const [2][]const u8) !TestingBackend.Response {
    return b.request(testing.io, .{ .method = .GET, .target = "/who", .headers = fields, .client_address = peer });
}

/// The id is the server's own: 32 lowercase hex digits.
fn expectOwnId(body: []const u8) !void {
    const id = body[(std.mem.findScalar(u8, body, ' ') orelse return error.TestUnexpectedResult) + 1 ..];
    try testing.expectEqual(32, id.len);
    for (id) |c| try testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
}

test "the server gives the client through its trusted_proxies" {
    const test_io = testing.io;
    var controller: WhoController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    const forwarded: []const [2][]const u8 = &.{.{ "x-forwarded-for", "198.51.100.7, 203.0.113.5" }};
    for ([_]struct { TrustedProxies, ?IpAddress, []const u8 }{
        .{ .all, ip("192.0.2.9:5000"), "198.51.100.7:0" },
        .{ .all, null, "198.51.100.7:0" },
        .{ .private, ip("10.0.0.1:5000"), "203.0.113.5:0" },
        .{ .private, ip("192.0.2.9:5000"), "192.0.2.9:5000" },
        .{ .none, ip("10.0.0.1:5000"), "10.0.0.1:5000" },
        .{ .{ .list = &.{"192.0.2.0/24"} }, ip("192.0.2.9:5000"), "203.0.113.5:0" },
        .{ .{ .list = &.{"192.0.2.0/24"} }, ip("10.0.0.1:5000"), "10.0.0.1:5000" },
    }) |case| {
        var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&controller}, .trusted_proxies = case[0] });
        defer server.deinit(test_io);
        try server.start(test_io);
        var res = try who(&b, case[1], forwarded);
        defer res.deinit();
        testing.expect(std.mem.startsWith(u8, res.body, case[2])) catch |err| {
            std.debug.print("{t}: {s}\n", .{ case[0], res.body });
            return err;
        };
    }
}

test "X-Request-Id only from a trusted peer" {
    const test_io = testing.io;
    var controller: WhoController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    {
        var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&controller}, .trusted_proxies = .private });
        defer server.deinit(test_io);
        try server.start(test_io);
        var trusted = try who(&b, ip("10.0.0.1:5000"), &.{.{ "X-Request-Id", "req-42" }});
        defer trusted.deinit();
        try testing.expectEqualStrings("10.0.0.1:5000 req-42", trusted.body);
        var outside = try who(&b, ip("192.0.2.9:5000"), &.{.{ "X-Request-Id", "req-42" }});
        defer outside.deinit();
        try expectOwnId(outside.body);
        // Not an id: a new one.
        var spaced = try who(&b, ip("10.0.0.1:5000"), &.{.{ "x-request-id", "req 42" }});
        defer spaced.deinit();
        try expectOwnId(spaced.body);
        var none = try who(&b, ip("10.0.0.1:5000"), &.{});
        defer none.deinit();
        try expectOwnId(none.body);
    }
    {
        // By default every peer is trusted, one without an address too.
        var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&controller} });
        defer server.deinit(test_io);
        try server.start(test_io);
        var res = try who(&b, null, &.{.{ "x-request-id", "edge-7f3a" }});
        defer res.deinit();
        try testing.expectEqualStrings("null edge-7f3a", res.body);
    }
    {
        var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&controller}, .trusted_proxies = .none });
        defer server.deinit(test_io);
        try server.start(test_io);
        var res = try who(&b, ip("10.0.0.1:5000"), &.{.{ "x-request-id", "req-42" }});
        defer res.deinit();
        try expectOwnId(res.body);
    }
}
