//! The URL and the options of `redis.Client.init`, row by row of the
//! tables of `url.zig` and `Options.zig`: what is taken, what is
//! `Unsupported` with what to do instead, and what is `InvalidArgument`.
//! No text of an error shows the user or the password.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const Diagnostics = @import("errors.zig").Diagnostics;
const Url = @import("url.zig").Url;
const Options = @import("Options.zig");
const OwnedOptions = @import("OwnedOptions.zig");

fn parse(text: []const u8) !Url {
    var d: Diagnostics = .{};
    return Url.parse(testing.allocator, text, &d) catch |err| {
        std.debug.print("{s}: {t}: {s}\n", .{ text, err, d.message() });
        return err;
    };
}

/// `text` is refused with `expected` and exactly `message`.
fn expectRefused(text: []const u8, expected: Url.Error, message: []const u8) !void {
    var d: Diagnostics = .{};
    if (Url.parse(testing.allocator, text, &d)) |parsed| {
        var url = parsed;
        url.deinit(testing.allocator);
        std.debug.print("{s}: taken, expected {t}\n", .{ text, expected });
        return error.TestUnexpectedResult;
    } else |err| {
        if (err != expected) {
            std.debug.print("{s}: {t}, expected {t}: {s}\n", .{ text, err, expected, d.message() });
            return error.TestUnexpectedError;
        }
        if (!std.mem.eql(u8, message, d.message())) {
            std.debug.print("{s}:\n  expected: {s}\n  got:      {s}\n", .{ text, message, d.message() });
            return error.TestUnexpectedResult;
        }
    }
}

const no_tls = "TLS is not supported in v0.1; use a trusted network";
const no_options = "v0.1 takes no options in the URL; set them in redis.Client.Options";
const percent_hint = "the user and the password in a URL are percent-encoded: write '@' as %40, ':' as %3A, '/' as %2F, '?' as %3F and '%' as %25";
const bad_port = "the port of the URL is a number from 1 to 65535";
const bad_database = "the database of the URL is a number from 0 to 2147483647, as in redis://host:6379/3";

test "one host, by name, IPv4 address or IPv6 address in brackets, on port 6379 and database 0 unless the URL gives others" {
    const cases = [_]struct { []const u8, []const u8, u16, u32 }{
        .{ "redis://localhost", "localhost", 6379, 0 },
        .{ "redis://127.0.0.1:16379/3", "127.0.0.1", 16379, 3 },
        .{ "redis://[::1]:6380/0", "::1", 6380, 0 },
        .{ "redis://Cache.Example.com", "cache.example.com", 6379, 0 },
        .{ "redis://cache:65535/", "cache", 65535, 0 },
        .{ "redis://[fe80::1%25en0]", "fe80::1%en0", 6379, 0 },
        .{ "redis://cache/2147483647", "cache", 6379, 2147483647 },
        .{ "REDIS://cache:1", "cache", 1, 0 },
    };
    for (cases) |case| {
        const text, const host, const port, const database = case;
        var url = try parse(text);
        defer url.deinit(testing.allocator);
        try testing.expectEqualStrings(host, url.host);
        try testing.expectEqual(port, url.port);
        try testing.expectEqual(database, url.database);
        try testing.expect(url.username == null and url.password == null);
    }
}

test "the user and the password are percent-decoded; an empty user is the user default" {
    {
        var url = try parse("redis://app:s3cr%40t@cache/1");
        defer url.deinit(testing.allocator);
        try testing.expectEqualDeep(@as(?[]const u8, "app"), url.username);
        try testing.expectEqualDeep(@as(?[]const u8, "s3cr@t"), url.password);
        try testing.expectEqualStrings("cache", url.host);
        try testing.expectEqual(@as(u32, 1), url.database);
    }
    {
        var url = try parse("redis://:secret@cache");
        defer url.deinit(testing.allocator);
        try testing.expect(url.username == null);
        try testing.expectEqualDeep(@as(?[]const u8, "secret"), url.password);
    }
    {
        var url = try parse("redis://app@cache");
        defer url.deinit(testing.allocator);
        try testing.expectEqualDeep(@as(?[]const u8, "app"), url.username);
        try testing.expect(url.password == null);
    }
    {
        // The first ':' ends the user; the password may hold more.
        var url = try parse("redis://app:a:b%3A@cache");
        defer url.deinit(testing.allocator);
        try testing.expectEqualDeep(@as(?[]const u8, "app"), url.username);
        try testing.expectEqualDeep(@as(?[]const u8, "a:b:"), url.password);
    }
}

test "rediss://, UNIX sockets, other schemes and options after ? are Unsupported, with what to do instead" {
    const unix = "a UNIX socket: v0.1 connects over TCP; give redis://host:port";
    const cases = [_][2][]const u8{
        .{ "rediss://cache:6380", no_tls },
        .{ "unix:///tmp/redis.sock", unix },
        .{ "redis+unix:///tmp/redis.sock", unix },
        .{ "valkey://cache", "valkey:// is not a scheme of v0.1: write redis://, which Valkey takes too" },
        .{ "valkeys://cache", no_tls },
        .{ "http://cache", "v0.1 takes a URL of the scheme redis://, as in redis://host:6379" },
        .{ "redis://cache?protocol=3", no_options },
        .{ "redis://cache/0?timeout=5", no_options },
        .{ "redis://cache/?", no_options },
    };
    for (cases) |case| try expectRefused(case[0], error.Unsupported, case[1]);
}

test "a URL that does not read is InvalidArgument, and says what to fix" {
    const cases = [_][2][]const u8{
        .{ "localhost:6379", "a URL starts with redis://, as in redis://host:6379" },
        .{ "redis://", "the URL names no host: redis://host:6379" },
        .{ "redis://:6379", "the URL names no host: redis://host:6379" },
        .{ "redis://cache:0", bad_port },
        .{ "redis://cache:65536", bad_port },
        .{ "redis://cache:abc", bad_port },
        .{ "redis://cache:", bad_port },
        .{ "redis://cache:+1", bad_port },
        .{ "redis://cache/x", bad_database },
        .{ "redis://cache/-1", bad_database },
        .{ "redis://cache/2147483648", bad_database },
        .{ "redis://cache/1/2", bad_database },
        .{ "redis://a%4@cache", percent_hint },
        .{ "redis://a:%zz@cache", percent_hint },
        .{ "redis://app:p@ss@cache", percent_hint },
        .{ "redis://app:p/ss@cache", percent_hint },
        .{ "redis://app:p?ss@cache", percent_hint },
        .{ "redis://@cache", "the URL has an empty user before '@': write redis://user:password@host, or leave the user out" },
        .{ "redis://[::1", "the IPv6 address of the URL has no ']': redis://[::1]:6379" },
        .{ "redis://[::1]x", "after the IPv6 address of the URL comes ':' and the port: redis://[::1]:6379" },
        .{ "redis://[cache]", "'[cache]' is not an IPv6 address" },
        .{ "redis://::1", "an IPv6 address in a URL goes in brackets: redis://[::1]:6379" },
        .{ "redis://ca che", "'ca che' is not a host name or an IP address" },
    };
    for (cases) |case| try expectRefused(case[0], error.InvalidArgument, case[1]);
}

test "no text of an error shows the user or the password" {
    const cases = [_][]const u8{
        "redis://app:hunter2@cache?x",
        "redis://app:hunter2@cache:0",
        "redis://app:hunter2@cache/x",
        "redis://app:hunter2@ca che",
        "redis://app:hunter2%4@cache",
        "rediss://app:hunter2@cache",
    };
    for (cases) |text| {
        var d: Diagnostics = .{};
        try testing.expect(std.meta.isError(Url.parse(testing.allocator, text, &d)));
        try testing.expect(d.message().len > 0);
        try testing.expect(std.mem.find(u8, d.message(), "hunter2") == null);
        try testing.expect(std.mem.find(u8, d.message(), "app") == null);
    }
}

/// `options` are refused with `expected` and exactly `message`.
fn expectOptionsRefused(options: Options, expected: OwnedOptions.Error, message: []const u8) !void {
    var d: Diagnostics = .{};
    var with_diagnostics = options;
    with_diagnostics.diagnostics = &d;
    if (OwnedOptions.init(testing.allocator, with_diagnostics)) |taken| {
        var owned = taken;
        owned.deinit(testing.allocator);
        std.debug.print("{s}: taken, expected {t}\n", .{ options.url, expected });
        return error.TestUnexpectedResult;
    } else |err| {
        if (err != expected) {
            std.debug.print("{s}: {t}, expected {t}: {s}\n", .{ options.url, err, expected, d.message() });
            return error.TestUnexpectedError;
        }
        if (!std.mem.eql(u8, message, d.message())) {
            std.debug.print("{s}:\n  expected: {s}\n  got:      {s}\n", .{ options.url, message, d.message() });
            return error.TestUnexpectedResult;
        }
    }
}

fn expectOptionsTaken(options: Options) !void {
    var d: Diagnostics = .{};
    var with_diagnostics = options;
    with_diagnostics.diagnostics = &d;
    var owned = OwnedOptions.init(testing.allocator, with_diagnostics) catch |err| {
        std.debug.print("{s}: {t}: {s}\n", .{ options.url, err, d.message() });
        return err;
    };
    owned.deinit(testing.allocator);
}

test "the password comes from the URL or from Options.password, never both, and a user needs one" {
    {
        var owned: OwnedOptions = try .init(testing.allocator, .{ .url = "redis://app@cache", .password = "x" });
        defer owned.deinit(testing.allocator);
        const c = owned.credentials() orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("app", c.username);
        try testing.expectEqualStrings("x", c.password);
    }
    {
        var owned: OwnedOptions = try .init(testing.allocator, .{ .url = "redis://:secret@cache" });
        defer owned.deinit(testing.allocator);
        const c = owned.credentials() orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("default", c.username);
        try testing.expectEqualStrings("secret", c.password);
    }
    {
        var owned: OwnedOptions = try .init(testing.allocator, .{ .url = "redis://cache", .password = "secret" });
        defer owned.deinit(testing.allocator);
        const c = owned.credentials() orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("default", c.username);
    }
    {
        var owned: OwnedOptions = try .init(testing.allocator, .{ .url = "redis://cache" });
        defer owned.deinit(testing.allocator);
        try testing.expect(owned.credentials() == null);
    }
    try expectOptionsRefused(.{ .url = "redis://app@cache" }, error.InvalidArgument, "the URL names a user but no password: add it percent-encoded, redis://user:password@host, or pass Options.password");
    try expectOptionsRefused(.{ .url = "redis://:a@cache", .password = "b" }, error.InvalidArgument, "the password is given twice, in the URL and in Options.password; keep one");
    // The URL's own errors come through as they are.
    try expectOptionsRefused(.{ .url = "rediss://cache" }, error.Unsupported, no_tls);
}

test "max_connections of 0, a duration under 1 ms or beyond maxInt(i64) ms, and max_reply_bytes under 64 KiB are InvalidArgument" {
    const url = "redis://cache";
    try expectOptionsRefused(.{ .url = url, .max_connections = 0 }, error.InvalidArgument, "max_connections is 0: the pool needs at least one connection");
    try expectOptionsRefused(.{ .url = url, .timeout = .fromNanoseconds(0) }, error.InvalidArgument, "timeout is under 1 ms: give it 1 ms or more, or null for calls without a deadline of their own");
    try expectOptionsRefused(.{ .url = url, .timeout = .max }, error.InvalidArgument, "timeout is longer than 9223372036854775807 ms, the most the client counts");
    try expectOptionsRefused(.{ .url = url, .connect_timeout = .fromMilliseconds(-1) }, error.InvalidArgument, "connect_timeout is under 1 ms: give it 1 ms or more");
    try expectOptionsRefused(.{ .url = url, .connect_timeout = .max }, error.InvalidArgument, "connect_timeout is longer than 9223372036854775807 ms, the most the client counts");
    try expectOptionsRefused(.{ .url = url, .close_timeout = .fromMicroseconds(500) }, error.InvalidArgument, "close_timeout is under 1 ms: give it 1 ms or more");
    try expectOptionsRefused(.{ .url = url, .close_timeout = .fromNanoseconds(std.math.maxInt(i64) * std.time.ns_per_ms + std.time.ns_per_ms) }, error.InvalidArgument, "close_timeout is longer than 9223372036854775807 ms, the most the client counts");
    try expectOptionsRefused(.{ .url = url, .max_reply_bytes = 65535 }, error.InvalidArgument, "max_reply_bytes is 65535: it is 65536 (64 KiB) or more");

    try expectOptionsTaken(.{ .url = url, .timeout = null });
    try expectOptionsTaken(.{ .url = url, .timeout = .fromMilliseconds(1), .connect_timeout = .fromMilliseconds(1), .close_timeout = .fromMilliseconds(1) });
    try expectOptionsTaken(.{ .url = url, .connect_timeout = .fromMilliseconds(std.math.maxInt(i64)) });
    try expectOptionsTaken(.{ .url = url, .max_reply_bytes = 65536, .max_connections = 1 });
}

test "the user, the password and the name of the client are at most 16 384 bytes; the name is printable ASCII without spaces" {
    const url = "redis://cache";
    const longest: [16384]u8 = @splat('p');
    const too_long: [16385]u8 = @splat('p');
    try expectOptionsTaken(.{ .url = url, .password = &longest });
    try expectOptionsRefused(.{ .url = url, .password = &too_long }, error.InvalidArgument, "the password is 16385 bytes; a server takes 16384 at most before authentication");
    try expectOptionsTaken(.{ .url = url, .client_name = &longest });
    try expectOptionsRefused(.{ .url = url, .client_name = &too_long }, error.InvalidArgument, "client_name is 16385 bytes; a server takes 16384 at most before authentication");

    var long_user: [8 + 16385 + 7]u8 = undefined;
    @memcpy(long_user[0..8], "redis://");
    @memset(long_user[8..][0..16385], 'u');
    @memcpy(long_user[8 + 16385 ..], "@cache/");
    try expectOptionsRefused(.{ .url = &long_user, .password = "x" }, error.InvalidArgument, "the user is 16385 bytes; a server takes 16384 at most before authentication");

    const not_printable = "client_name holds a space or a byte outside printable ASCII, at byte {d}: a server takes the bytes 0x21 to 0x7E";
    var buffer: [256]u8 = undefined;
    try expectOptionsRefused(.{ .url = url, .client_name = "my app" }, error.InvalidArgument, try std.fmt.bufPrint(&buffer, not_printable, .{2}));
    try expectOptionsRefused(.{ .url = url, .client_name = "api\x7f" }, error.InvalidArgument, try std.fmt.bufPrint(&buffer, not_printable, .{3}));
    try expectOptionsRefused(.{ .url = url, .client_name = "" }, error.InvalidArgument, "client_name is empty: leave it null for connections without a name");
    try expectOptionsTaken(.{ .url = url, .client_name = "api-1" });
}

test "the copy holds everything the caller may free" {
    var url = "redis://app@Cache.Internal:16380/2".*;
    var password = "s3cret".*;
    var name = "api-1".*;
    var owned: OwnedOptions = try .init(testing.allocator, .{
        .url = &url,
        .password = &password,
        .client_name = &name,
        .max_connections = 4,
        .timeout = .fromSeconds(2),
        .connect_timeout = .fromSeconds(3),
        .close_timeout = .fromSeconds(4),
        .max_reply_bytes = 1 << 20,
    });
    defer owned.deinit(testing.allocator);
    @memset(&url, 'X');
    @memset(&password, 'X');
    @memset(&name, 'X');
    try testing.expectEqualStrings("cache.internal", owned.url.host);
    try testing.expectEqual(@as(u16, 16380), owned.url.port);
    try testing.expectEqual(@as(u32, 2), owned.url.database);
    try testing.expectEqualDeep(@as(?[]const u8, "api-1"), owned.client_name);
    try testing.expectEqual(@as(u32, 4), owned.max_connections);
    try testing.expectEqual(@as(?Io.Duration, .fromSeconds(2)), owned.timeout);
    try testing.expectEqual(Io.Duration.fromSeconds(3), owned.connect_timeout);
    try testing.expectEqual(Io.Duration.fromSeconds(4), owned.close_timeout);
    try testing.expectEqual(@as(usize, 1 << 20), owned.max_reply_bytes);
    const c = owned.credentials() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("app", c.username);
    try testing.expectEqualStrings("s3cret", c.password);
}

test "the defaults are those of the design" {
    var owned: OwnedOptions = try .init(testing.allocator, .{ .url = "redis://cache" });
    defer owned.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 32), owned.max_connections);
    try testing.expectEqual(@as(?Io.Duration, .fromSeconds(5)), owned.timeout);
    try testing.expectEqual(Io.Duration.fromSeconds(5), owned.connect_timeout);
    try testing.expectEqual(Io.Duration.fromSeconds(5), owned.close_timeout);
    try testing.expectEqual(@as(usize, 64 * 1024 * 1024), owned.max_reply_bytes);
    try testing.expect(owned.client_name == null);
}

test "deinit wipes the copies of the URL and the password before it frees them" {
    // Allocator.free overwrites what it frees in safe builds before the
    // allocator sees it, so the wipe that deinit runs first is checked
    // on its own.
    var owned: OwnedOptions = try .init(testing.allocator, .{ .url = "redis://app:hunter2@cache", .client_name = "api-1" });
    defer owned.deinit(testing.allocator);
    owned.wipe();
    try testing.expect(std.mem.allEqual(u8, owned.url.bytes, 0));

    var from_options: OwnedOptions = try .init(testing.allocator, .{ .url = "redis://app@cache", .password = "hunter2" });
    defer from_options.deinit(testing.allocator);
    from_options.wipe();
    const password = from_options.password orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.allEqual(u8, password, 0));
    try testing.expect(std.mem.allEqual(u8, from_options.url.bytes, 0));
}

fn initAndDeinit(gpa: std.mem.Allocator, options: Options) !void {
    var owned: OwnedOptions = try .init(gpa, options);
    owned.deinit(gpa);
}

test "nothing leaks when memory runs out" {
    try testing.checkAllAllocationFailures(testing.allocator, initAndDeinit, .{Options{ .url = "redis://app@cache/1", .password = "secret", .client_name = "api-1" }});
}
