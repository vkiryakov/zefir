//! `rpc.Credentials`: what a call carries in the reserved metadata key
//! `authorization`, as a type instead of a string. The client engine
//! encodes it right before the transport sends the call; the server engine
//! parses it back for the authenticator. Applications never read or write
//! `authorization` as metadata.

const std = @import("std");
const core = @import("core");

/// The credentials of a call.
///
/// ```zig
/// var client: rpc.RawClient = try .init(gpa, .{
///     .transport = bus.clientTransport(),
///     .credentials = .{ .bearer = token }, // init copies it
/// });
/// defer client.deinit(); // wipes the copy
/// // One call as an end user, one anonymous:
/// var a = try client.call(io, ctx, route, body, .{ .credentials = .{ .bearer = user_token } });
/// var b = try client.call(io, ctx, route, body, .{ .credentials = .none });
/// ```
pub const Credentials = union(enum) {
    /// No credentials: the call is anonymous.
    none,
    /// `authorization: Bearer <token>`.
    bearer: []const u8,
    /// `authorization: Basic base64(user:password)`. The user must not
    /// contain ':' (RFC 7617): the server reads it up to the first ':'.
    basic: Basic,
    /// Credentials that change over time, such as an OAuth token that is
    /// refreshed: the client engine asks the provider before every call. On
    /// the client only; a server never sees it.
    provider: CredentialsProvider,
    /// A scheme of your own: the `authorization` value as it is, such as
    /// "ApiKey k-123". On the server, whatever the engine did not parse as
    /// bearer or basic.
    custom: []const u8,

    pub const Basic = struct { user: []const u8, password: []const u8 };

    /// zefir loggers never print values of this type.
    pub const zefir_sensitive = true;
};

/// Credentials that the client engine asks for before every call.
pub const CredentialsProvider = struct {
    ptr: *anyopaque,
    /// The credentials of one call. Strings the provider allocates for them
    /// come from `arena`, which the engine wipes and frees once the call has
    /// been sent. `ctx` carries the deadline and the trace of the call.
    /// `error.Unavailable` ends the call with `Unavailable`: it was not sent,
    /// a retry is safe. Returning `.provider` is a bug: the engine panics.
    get: *const fn (ptr: *anyopaque, io: std.Io, ctx: core.Context, arena: std.mem.Allocator) (error{ Unavailable, OutOfMemory } || std.Io.Cancelable)!Credentials,
};

/// The `authorization` value of `credentials`, allocated in `arena`; null
/// for `.none`. The value of `.custom` is returned as it is. The engine has
/// asked a provider already: `.provider` is not valid here. Internal to the
/// module.
pub fn encode(arena: std.mem.Allocator, credentials: Credentials) error{OutOfMemory}!?[]const u8 {
    return switch (credentials) {
        .none => null,
        .bearer => |token| try std.mem.concat(arena, u8, &.{ "Bearer ", token }),
        .basic => |basic| {
            const plain = try std.mem.concat(arena, u8, &.{ basic.user, ":", basic.password });
            const encoder = std.base64.standard.Encoder;
            const value = try arena.alloc(u8, basic_prefix.len + encoder.calcSize(plain.len));
            @memcpy(value[0..basic_prefix.len], basic_prefix);
            _ = encoder.encode(value[basic_prefix.len..], plain);
            return value;
        },
        .custom => |value| value,
        .provider => unreachable,
    };
}

const basic_prefix = "Basic ";

/// Whether the server's `parse` gives `credentials` back as they were
/// encoded: a bearer token that is not empty and has no space; a basic user
/// without ':', the user and the password in UTF-8. A custom value goes as
/// it is. The client engine does not send credentials the server would read
/// as something else. Internal to the module.
pub fn readsBack(credentials: Credentials) bool {
    return switch (credentials) {
        .none, .custom => true,
        .bearer => |token| token.len > 0 and std.mem.findScalar(u8, token, ' ') == null,
        .basic => |basic| std.mem.findScalar(u8, basic.user, ':') == null and
            std.unicode.utf8ValidateSlice(basic.user) and std.unicode.utf8ValidateSlice(basic.password),
        .provider => false,
    };
}

/// The credentials of an `authorization` value, as RFC 7235 writes them:
/// the scheme in any case, exactly one space, then the credentials without
/// spaces. No value is `.none`; "Bearer <token>" is `.bearer`; "Basic
/// <base64>" that decodes to UTF-8 with a ':' is `.basic`; anything else is
/// `.custom` with the whole value. Strings point into `value`, except the
/// decoded user and password, which are in `arena`: wipe them with
/// `wipeParsed` before `arena` is freed. Internal to the module.
pub fn parse(arena: std.mem.Allocator, value: ?[]const u8) error{OutOfMemory}!Credentials {
    const header = value orelse return .none;
    const custom: Credentials = .{ .custom = header };
    const space = std.mem.findScalar(u8, header, ' ') orelse return custom;
    const scheme = header[0..space];
    const rest = header[space + 1 ..];
    if (rest.len == 0 or std.mem.findScalar(u8, rest, ' ') != null) return custom;
    if (std.ascii.eqlIgnoreCase(scheme, "Bearer")) return .{ .bearer = rest };
    if (!std.ascii.eqlIgnoreCase(scheme, "Basic")) return custom;

    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(rest) catch return custom;
    const plain = try arena.alloc(u8, len);
    decoder.decode(plain, rest) catch {
        std.crypto.secureZero(u8, plain);
        return custom;
    };
    const colon = std.mem.findScalar(u8, plain, ':') orelse {
        std.crypto.secureZero(u8, plain);
        return custom;
    };
    if (!std.unicode.utf8ValidateSlice(plain)) {
        std.crypto.secureZero(u8, plain);
        return custom;
    }
    return .{ .basic = .{ .user = plain[0..colon], .password = plain[colon + 1 ..] } };
}

/// Wipes what `parse` decoded into its arena: the user and password of
/// `.basic`. Internal to the module.
pub fn wipeParsed(credentials: Credentials) void {
    switch (credentials) {
        .basic => |basic| {
            std.crypto.secureZero(u8, @constCast(basic.user));
            std.crypto.secureZero(u8, @constCast(basic.password));
        },
        .none, .bearer, .custom, .provider => {},
    }
}

/// A copy of `credentials` whose strings are its own, in `gpa`: a client's
/// default credentials. A provider is copied as it is. Internal to the
/// module.
pub fn dupe(gpa: std.mem.Allocator, credentials: Credentials) error{OutOfMemory}!Credentials {
    return switch (credentials) {
        .none, .provider => credentials,
        .bearer => |token| .{ .bearer = try gpa.dupe(u8, token) },
        .custom => |value| .{ .custom = try gpa.dupe(u8, value) },
        .basic => |basic| {
            const user = try gpa.dupe(u8, basic.user);
            errdefer wipeAndFree(gpa, user);
            return .{ .basic = .{ .user = user, .password = try gpa.dupe(u8, basic.password) } };
        },
    };
}

/// Wipes and frees a copy made with `dupe`. Internal to the module.
pub fn wipe(gpa: std.mem.Allocator, credentials: Credentials) void {
    switch (credentials) {
        .none, .provider => {},
        .bearer, .custom => |value| wipeAndFree(gpa, value),
        .basic => |basic| {
            wipeAndFree(gpa, basic.user);
            wipeAndFree(gpa, basic.password);
        },
    }
}

fn wipeAndFree(gpa: std.mem.Allocator, value: []const u8) void {
    if (value.len == 0) return;
    const bytes = @constCast(value);
    std.crypto.secureZero(u8, bytes);
    // Not `free`: in Debug it fills the block with 0xAA before the
    // allocator sees it, and a test could not tell a wiped block.
    gpa.rawFree(bytes, .of(u8), @returnAddress());
}

/// An allocator over `gpa` that zeroes every block before it gives the
/// block back: the client engine keeps the credentials of one call in an
/// arena on it. Internal to the module.
pub const Wiping = struct {
    gpa: std.mem.Allocator,

    pub fn allocator(w: *Wiping) std.mem.Allocator {
        return .{ .ptr = w, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const w: *Wiping = @ptrCast(@alignCast(ptr));
        return w.gpa.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const w: *Wiping = @ptrCast(@alignCast(ptr));
        // The bytes past a shrink are no longer the caller's.
        if (new_len < memory.len) std.crypto.secureZero(u8, memory[new_len..]);
        return w.gpa.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        // A move would give the old block back unwiped; callers copy instead.
        return null;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const w: *Wiping = @ptrCast(@alignCast(ptr));
        std.crypto.secureZero(u8, memory);
        w.gpa.rawFree(memory, alignment, ret_addr);
    }
};

const testing = std.testing;

test "zefir loggers never print credentials" {
    try testing.expect(core.isSensitive(Credentials));
}

fn expectParsed(expected: Credentials, value: ?[]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(), value);
    try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(parsed));
    switch (expected) {
        .none, .provider => {},
        .bearer => |token| try testing.expectEqualStrings(token, parsed.bearer),
        .custom => |custom| try testing.expectEqualStrings(custom, parsed.custom),
        .basic => |basic| {
            try testing.expectEqualStrings(basic.user, parsed.basic.user);
            try testing.expectEqualStrings(basic.password, parsed.basic.password);
        },
    }
}

test "parse: the scheme in any case, one space, bearer and basic; anything else is custom" {
    try expectParsed(.none, null);
    try expectParsed(.{ .bearer = "t0k.en-_~+/=" }, "Bearer t0k.en-_~+/=");
    try expectParsed(.{ .bearer = "abc" }, "bearer abc");
    try expectParsed(.{ .bearer = "abc" }, "BEARER abc");
    // "user:pass", "u:p:q" (a password may hold ':'), ":" (both empty).
    try expectParsed(.{ .basic = .{ .user = "user", .password = "pass" } }, "Basic dXNlcjpwYXNz");
    try expectParsed(.{ .basic = .{ .user = "u", .password = "p:q" } }, "basic dTpwOnE=");
    try expectParsed(.{ .basic = .{ .user = "", .password = "" } }, "Basic Og==");
    // "ü:ß" in UTF-8.
    try expectParsed(.{ .basic = .{ .user = "ü", .password = "ß" } }, "Basic w7w6w58=");

    for ([_][]const u8{
        "",
        "Bearer",
        "Bearer ",
        "Bearer  two-spaces",
        "Bearer a b",
        " Bearer t",
        "Basic",
        "Basic !!!!",
        "Basic dXNlcg==", // "user": no ':'
        "Basic dXNlcjpwYXNz=", // bad padding
        "Basic /zr+", // "\xff:\xfe": not UTF-8
        "ApiKey k-123",
        "Token",
    }) |value| try expectParsed(.{ .custom = value }, value);
}

fn roundTrip(credentials: Credentials) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const value = try encode(arena.allocator(), credentials);
    try expectParsed(credentials, value);
}

test "encode: what parse reads back" {
    try roundTrip(.none);
    try roundTrip(.{ .bearer = "eyJhbGciOiJIUzI1NiJ9.e30.sig" });
    try roundTrip(.{ .basic = .{ .user = "svc", .password = "p:ss w0rd" } });
    try roundTrip(.{ .basic = .{ .user = "", .password = "" } });
    try roundTrip(.{ .custom = "ApiKey k-123" });

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("Bearer abc", (try encode(arena.allocator(), .{ .bearer = "abc" })).?);
    try testing.expectEqualStrings("Basic dXNlcjpwYXNz", (try encode(arena.allocator(), .{ .basic = .{ .user = "user", .password = "pass" } })).?);
    try testing.expectEqual(@as(?[]const u8, null), try encode(arena.allocator(), .none));
}

/// An allocator over `testing.allocator` that looks for `needle` in every
/// block given back through it, and notes a block that is not all zero.
/// `Allocator.free` fills a block with 0xAA in Debug before the allocator
/// sees it, so only `rawFree` shows what the caller left in it.
const Spotter = struct {
    needle: []const u8,
    spotted: bool = false,
    unwiped: bool = false,

    fn allocator(s: *Spotter) std.mem.Allocator {
        return .{ .ptr = s, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        return testing.allocator.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const s: *Spotter = @ptrCast(@alignCast(ptr));
        if (new_len < memory.len and std.mem.find(u8, memory[new_len..], s.needle) != null) s.spotted = true;
        return testing.allocator.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const s: *Spotter = @ptrCast(@alignCast(ptr));
        if (std.mem.find(u8, memory, s.needle) != null) s.spotted = true;
        if (!std.mem.allEqual(u8, memory, 0)) s.unwiped = true;
        testing.allocator.rawFree(memory, alignment, ret_addr);
    }
};

test "dupe makes a copy of its own; wipe zeroes it before freeing" {
    var spotter: Spotter = .{ .needle = "s3cr3t" };
    const gpa = spotter.allocator();
    var token = "s3cr3t-token".*;
    const cases = [_]Credentials{
        .none,
        .{ .bearer = &token },
        .{ .custom = &token },
        .{ .basic = .{ .user = "svc", .password = &token } },
    };
    for (cases) |original| {
        const copy = try dupe(gpa, original);
        token[0] = 'X';
        defer token[0] = 's';
        switch (copy) {
            .bearer => |value| try testing.expectEqualStrings("s3cr3t-token", value),
            .custom => |value| try testing.expectEqualStrings("s3cr3t-token", value),
            .basic => |basic| try testing.expectEqualStrings("s3cr3t-token", basic.password),
            .none, .provider => {},
        }
        wipe(gpa, copy);
    }
    try testing.expect(!spotter.spotted and !spotter.unwiped);

    // A provider is copied as it is: nothing to allocate.
    var state: u8 = 0;
    const provider: Credentials = .{ .provider = .{ .ptr = &state, .get = undefined } };
    const copy = try dupe(testing.allocator, provider);
    try testing.expectEqual(provider.provider.ptr, copy.provider.ptr);
    wipe(testing.allocator, copy);
}

fn dupeAndWipe(gpa: std.mem.Allocator) !void {
    wipe(gpa, try dupe(gpa, .{ .basic = .{ .user = "s3cr3t-user", .password = "pw" } }));
}

test "dupe frees what it took when an allocation fails, and wipes it first" {
    var spotter: Spotter = .{ .needle = "s3cr3t" };
    try testing.checkAllAllocationFailures(spotter.allocator(), dupeAndWipe, .{});
    try testing.expect(!spotter.spotted and !spotter.unwiped);
}

test "readsBack: what the server's parse gives back as it was encoded" {
    for ([_]Credentials{
        .none,
        .{ .bearer = "t0k.en-_~+/=" },
        .{ .basic = .{ .user = "u", .password = "p:q ü" } },
        .{ .basic = .{ .user = "", .password = "" } },
        .{ .custom = "ApiKey k-1" },
    }) |credentials| {
        try testing.expect(readsBack(credentials));
        try roundTrip(credentials);
    }
    for ([_]Credentials{
        .{ .bearer = "" },
        .{ .bearer = "a b" },
        .{ .basic = .{ .user = "a:b", .password = "c" } },
        .{ .basic = .{ .user = "u", .password = "\xff" } },
        .{ .basic = .{ .user = "\xfe", .password = "p" } },
    }) |credentials| try testing.expect(!readsBack(credentials));
}

test "the decoded user and password are wiped by wipeParsed; a failed decode leaves nothing behind" {
    var spotter: Spotter = .{ .needle = "s3cr3t" };
    var arena: std.heap.ArenaAllocator = .init(spotter.allocator());
    // base64("svc:s3cr3t") and base64("s3cr3t") without ':'.
    const parsed = try parse(arena.allocator(), "Basic c3ZjOnMzY3IzdA==");
    try testing.expectEqualStrings("s3cr3t", parsed.basic.password);
    wipeParsed(parsed);
    try expectParsed(.{ .custom = "Basic czNjcjN0" }, "Basic czNjcjN0");
    _ = try parse(arena.allocator(), "Basic czNjcjN0");
    arena.deinit();
    try testing.expect(!spotter.spotted);
}

test "an arena on a wiping allocator gives back only zeroes" {
    var spotter: Spotter = .{ .needle = "s3cr3t" };
    var wiping: Wiping = .{ .gpa = spotter.allocator() };
    var arena: std.heap.ArenaAllocator = .init(wiping.allocator());
    const a = arena.allocator();
    for (0..100) |_| _ = try std.mem.concat(a, u8, &.{ "Bearer ", "s3cr3t" });
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(wiping.allocator(), "s3cr3t s3cr3t s3cr3t");
    list.shrinkAndFree(wiping.allocator(), 2);
    list.deinit(wiping.allocator());
    var buffer = try wiping.allocator().alloc(u8, 64);
    @memcpy(buffer[0..20], "ab s3cr3t s3cr3t xyz");
    if (wiping.allocator().resize(buffer, 2)) buffer = buffer[0..2];
    wiping.allocator().free(buffer);
    arena.deinit();
    try testing.expect(!spotter.spotted);
}
