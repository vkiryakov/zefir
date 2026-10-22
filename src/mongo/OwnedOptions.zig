//! The client's own copy of its options: the connection string read, its
//! strings and the password copied, all of them wiped when freed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Duration = std.Io.Duration;
const mongo = @import("root.zig");
const Diagnostics = mongo.Diagnostics;
const Options = @import("Options.zig");
const Uri = @import("uri.zig").Uri;
const OwnedOptions = @This();

uri: Uri,
/// The copy of `Options.password`.
password: ?[]u8,
start_timeout: Duration,
close_timeout: Duration,
cursor_close_timeout: Duration,

pub const Error = Uri.Error;

/// Who the client authenticates as.
pub const Credentials = struct {
    username: []const u8,
    password: []const u8,
    /// The database the user is defined in: `authSource`, else the
    /// database of the path, else "admin".
    source: []const u8,
    /// Null: the server's `saslSupportedMechs` decides.
    mechanism: ?Uri.Mechanism,
};

pub fn init(gpa: Allocator, options: Options) Error!OwnedOptions {
    const d = options.diagnostics;
    if (options.start_timeout.nanoseconds <= 0) return fail(d, "start_timeout is not above zero: start would fail at once", .{});
    if (options.close_timeout.nanoseconds < 0) return fail(d, "close_timeout is negative; 0 cuts the operations in flight at once", .{});
    if (options.cursor_close_timeout.nanoseconds < 0) return fail(d, "cursor_close_timeout is negative", .{});
    var uri = try Uri.parse(gpa, options.uri, d);
    errdefer uri.deinit(gpa);
    if (options.password != null) {
        if (uri.username == null) return fail(d, "options.password is set, but the connection string names no user: mongodb://user@host", .{});
        if (uri.password != null) return fail(d, "the password is given twice, in the connection string and in options.password; keep one", .{});
    } else if (uri.username != null and uri.password == null) {
        return fail(d, "the connection string names a user but no password: add it percent-encoded, mongodb://user:password@host, or pass options.password", .{});
    }
    const password = if (options.password) |p| try gpa.dupe(u8, p) else null;
    return .{
        .uri = uri,
        .password = password,
        .start_timeout = options.start_timeout,
        .close_timeout = options.close_timeout,
        .cursor_close_timeout = options.cursor_close_timeout,
    };
}

pub fn deinit(owned: *OwnedOptions, gpa: Allocator) void {
    owned.wipe();
    if (owned.password) |password| gpa.free(password);
    owned.uri.deinit(gpa);
    owned.* = undefined;
}

/// The user, the password and where the user is defined; null when the
/// connection string names no user.
pub fn credentials(owned: *const OwnedOptions) ?Credentials {
    const username = owned.uri.username orelse return null;
    return .{
        .username = username,
        .password = owned.password orelse owned.uri.password.?,
        .source = owned.uri.auth_source orelse owned.uri.database orelse "admin",
        .mechanism = owned.uri.auth_mechanism,
    };
}

/// Overwrites the copies of the strings and the password, so that they do
/// not stay in freed memory.
fn wipe(owned: *OwnedOptions) void {
    std.crypto.secureZero(u8, owned.uri.bytes);
    if (owned.password) |password| std.crypto.secureZero(u8, password);
}

fn fail(d: ?*Diagnostics, comptime fmt: []const u8, args: anytype) Error {
    if (d) |x| x.set(null, null, fmt, args);
    return error.InvalidArgument;
}

const testing = std.testing;

test "the copy holds everything the caller may free" {
    var uri = "mongodb://orders@db.internal:27018/orders?appName=orders".*;
    var password = "s3cret".*;
    var owned: OwnedOptions = try .init(testing.allocator, .{ .uri = &uri, .password = &password, .close_timeout = .fromSeconds(2) });
    defer owned.deinit(testing.allocator);
    @memset(&uri, 'X');
    @memset(&password, 'X');
    try testing.expectEqualStrings("db.internal", owned.uri.host);
    try testing.expectEqual(@as(u16, 27018), owned.uri.port);
    try testing.expectEqualStrings("orders", owned.uri.app_name.?);
    try testing.expectEqual(Duration.fromSeconds(10), owned.start_timeout);
    try testing.expectEqual(Duration.fromSeconds(2), owned.close_timeout);
    try testing.expectEqual(Duration.fromSeconds(1), owned.cursor_close_timeout);
    const c = owned.credentials().?;
    try testing.expectEqualStrings("orders", c.username);
    try testing.expectEqualStrings("s3cret", c.password);
    try testing.expectEqualStrings("orders", c.source);
    try testing.expect(c.mechanism == null);
}

test "credentials: the password of the string or of the options, the user defined in authSource, the path's database or admin" {
    {
        var owned: OwnedOptions = try .init(testing.allocator, .{ .uri = "mongodb://app:p%40ss@host/?authMechanism=SCRAM-SHA-1" });
        defer owned.deinit(testing.allocator);
        const c = owned.credentials().?;
        try testing.expectEqualStrings("p@ss", c.password);
        try testing.expectEqualStrings("admin", c.source);
        try testing.expectEqual(Uri.Mechanism.scram_sha_1, c.mechanism.?);
    }
    {
        var owned: OwnedOptions = try .init(testing.allocator, .{ .uri = "mongodb://app@host/app?authSource=users", .password = "secret" });
        defer owned.deinit(testing.allocator);
        try testing.expectEqualStrings("users", owned.credentials().?.source);
        try testing.expectEqualStrings("secret", owned.credentials().?.password);
    }
    {
        var owned: OwnedOptions = try .init(testing.allocator, .{ .uri = "mongodb://host/app" });
        defer owned.deinit(testing.allocator);
        try testing.expect(owned.credentials() == null);
    }
}

test "a password given twice, a password without a user and a user without a password are InvalidArgument" {
    const cases = [_]struct { Options, []const u8 }{
        .{ .{ .uri = "mongodb://app:one@host", .password = "two" }, "the password is given twice, in the connection string and in options.password; keep one" },
        .{ .{ .uri = "mongodb://host", .password = "secret" }, "options.password is set, but the connection string names no user: mongodb://user@host" },
        .{ .{ .uri = "mongodb://app@host/app" }, "the connection string names a user but no password: add it percent-encoded, mongodb://user:password@host, or pass options.password" },
        .{ .{ .uri = "mongodb://host", .start_timeout = .zero }, "start_timeout is not above zero: start would fail at once" },
        .{ .{ .uri = "mongodb://host", .close_timeout = .fromSeconds(-1) }, "close_timeout is negative; 0 cuts the operations in flight at once" },
        .{ .{ .uri = "mongodb://host", .cursor_close_timeout = .fromMilliseconds(-1) }, "cursor_close_timeout is negative" },
    };
    for (cases) |case| {
        var options, const message = case;
        var d: Diagnostics = .{};
        options.diagnostics = &d;
        try testing.expectError(error.InvalidArgument, OwnedOptions.init(testing.allocator, options));
        try testing.expectEqualStrings(message, d.message());
    }
    // The connection string's own errors come through as they are.
    var d: Diagnostics = .{};
    try testing.expectError(error.Unsupported, OwnedOptions.init(testing.allocator, .{ .uri = "mongodb://host/?tls=true", .diagnostics = &d }));
    try testing.expectEqualStrings("tls=true: TLS is not supported in v0.1; use a trusted network", d.message());
}

test "deinit wipes the copies of the strings and the password" {
    var owned: OwnedOptions = try .init(testing.allocator, .{ .uri = "mongodb://app@host/app", .password = "secret" });
    defer owned.deinit(testing.allocator);
    // deinit wipes first; Allocator.free overwrites freed memory in Debug,
    // so the wipe is checked before it.
    owned.wipe();
    try testing.expect(std.mem.allEqual(u8, owned.uri.bytes, 0));
    try testing.expect(std.mem.allEqual(u8, owned.password.?, 0));
}

fn initAndDeinit(gpa: Allocator, options: Options) !void {
    var owned: OwnedOptions = try .init(gpa, options);
    owned.deinit(gpa);
}

test "nothing leaks when memory runs out" {
    try testing.checkAllAllocationFailures(testing.allocator, initAndDeinit, .{Options{ .uri = "mongodb://app@host/app", .password = "secret" }});
}
