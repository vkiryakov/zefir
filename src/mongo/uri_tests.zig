//! The connection string, row by row of the table in `uri.zig`: what is
//! taken, what is `Unsupported` with what to do instead, what is
//! `InvalidArgument`, and what is skipped with a warning.

const std = @import("std");
const testing = std.testing;
const mongo = @import("root.zig");
const Diagnostics = mongo.Diagnostics;
const Uri = @import("uri.zig").Uri;

fn parse(text: []const u8) !Uri {
    var d: Diagnostics = .{};
    return Uri.parse(testing.allocator, text, &d) catch |err| {
        std.debug.print("{s}: {t}: {s}\n", .{ text, err, d.message() });
        return err;
    };
}

/// `text` is refused with `expected` and exactly `message`.
fn expectRefused(text: []const u8, expected: Uri.Error, message: []const u8) !void {
    var d: Diagnostics = .{};
    if (Uri.parse(testing.allocator, text, &d)) |parsed| {
        var uri = parsed;
        uri.deinit(testing.allocator);
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
const percent_hint = "the user and the password in a connection string are percent-encoded: write '@' as %40, ':' as %3A, '/' as %2F and '%' as %25";
const standalone_only = "v0.1 works with a standalone mongod only; remove it from the connection string";

test "one host, by name, IPv4 address or IPv6 address in brackets, on port 27017 unless the string gives one" {
    const cases = [_]struct { []const u8, []const u8, u16 }{
        .{ "mongodb://localhost", "localhost", 27017 },
        .{ "mongodb://DB.Example.com:27018", "db.example.com", 27018 },
        .{ "mongodb://127.0.0.1:27117", "127.0.0.1", 27117 },
        .{ "mongodb://127.0.0.1:27117/", "127.0.0.1", 27117 },
        .{ "mongodb://[::1]", "::1", 27017 },
        .{ "mongodb://[::1]:27018/", "::1", 27018 },
        .{ "mongodb://[fe80::1%25en0]:27019", "fe80::1%en0", 27019 },
        .{ "mongodb://db:65535", "db", 65535 },
    };
    for (cases) |case| {
        const text, const host, const port = case;
        var uri = try parse(text);
        defer uri.deinit(testing.allocator);
        try testing.expectEqualStrings(host, uri.host);
        try testing.expectEqual(port, uri.port);
        try testing.expect(uri.username == null and uri.password == null and uri.database == null);
    }
}

test "mongodb+srv, several hosts and UNIX domain sockets are Unsupported" {
    try expectRefused("mongodb+srv://cluster.example.com", error.Unsupported, "mongodb+srv:// needs SRV records, which v0.1 does not look up: give the host, mongodb://host:port");
    try expectRefused("mongodb://a.example.com,b.example.com/app", error.Unsupported, "the connection string names several hosts, and v0.1 connects to one standalone mongod: give one host");
    try expectRefused("mongodb://%2Ftmp%2Fmongodb-27017.sock", error.Unsupported, "the connection string names a UNIX domain socket, and v0.1 connects over TCP: give host:port");
}

test "a scheme, a host or a port that cannot be read is InvalidArgument, with what to write" {
    const port_message = "the port of the connection string is a number from 1 to 65535";
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "postgres://127.0.0.1", "a connection string starts with mongodb://" },
        .{ "mongodb://", "the connection string names no host: mongodb://host:27017" },
        .{ "mongodb:///app", "the connection string names no host: mongodb://host:27017" },
        .{ "mongodb://:27017", "the connection string names no host: mongodb://host:27017" },
        .{ "mongodb://host:0", port_message },
        .{ "mongodb://host:65536", port_message },
        .{ "mongodb://host:port", port_message },
        .{ "mongodb://host:", port_message },
        .{ "mongodb://host:+27017", port_message },
        .{ "mongodb://[::1]:", port_message },
        .{ "mongodb://::1:27017", "an IPv6 address in a connection string goes in brackets: mongodb://[::1]:27017" },
        .{ "mongodb://[::1", "the IPv6 address of the connection string has no ']': mongodb://[::1]:27017" },
        .{ "mongodb://[::1]x", "after the IPv6 address of the connection string comes ':' and the port: mongodb://[::1]:27017" },
        .{ "mongodb://[db.example.com]", "'[db.example.com]' is not an IPv6 address" },
        .{ "mongodb://db_1.example.com", "'db_1.example.com' is not a host name or an IP address" },
        .{ "mongodb://host?appName=app", "the options of a connection string come after a '/': mongodb://host/?appName=app" },
    };
    for (cases) |case| try expectRefused(case[0], error.InvalidArgument, case[1]);
}

test "the user and the password are percent-decoded: p%40ss%3Aw%2Frd is the password p@ss:w/rd" {
    var uri = try parse("mongodb://app:p%40ss%3Aw%2Frd@host/app");
    defer uri.deinit(testing.allocator);
    try testing.expectEqualStrings("app", uri.username.?);
    try testing.expectEqualStrings("p@ss:w/rd", uri.password.?);
    try testing.expectEqualStrings("app", uri.database.?);
    try testing.expectEqualStrings("host", uri.host);

    const cases = [_]struct { []const u8, []const u8, ?[]const u8 }{
        // The user of a SCRAM-SHA-256 vector of the auth spec, as UTF-8.
        .{ "mongodb://%E2%85%A8:x@host", "Ⅸ", "x" },
        .{ "mongodb://user:@host", "user", "" },
        .{ "mongodb://user@host", "user", null },
        // Sub-delimiters of RFC 3986 stand for themselves.
        .{ "mongodb://us%3Aer:pa+ss!$&'()*,;=~@host", "us:er", "pa+ss!$&'()*,;=~" },
    };
    for (cases) |case| {
        var parsed = try parse(case[0]);
        defer parsed.deinit(testing.allocator);
        try testing.expectEqualStrings(case[1], parsed.username.?);
        if (case[2]) |password| try testing.expectEqualStrings(password, parsed.password.?) else try testing.expect(parsed.password == null);
    }
}

test "an unescaped @, a second : or a % without two hex digits in the user or the password is InvalidArgument, and the message holds no password" {
    const cases = [_][]const u8{
        "mongodb://app:p@ss@host/app",
        "mongodb://app@x@host",
        "mongodb://app:p:ss@host/app",
        "mongodb://app:p%4@host/app",
        "mongodb://app:p%zzss@host/app",
        "mongodb://app:pa%@host/app",
        "mongodb://app:pa/ss@host/app",
        "mongodb://app:p ss@host/app",
        "mongodb://app:p#ss@host/app",
        "mongodb://app:p[ss]@host/app",
    };
    for (cases) |text| try expectRefused(text, error.InvalidArgument, percent_hint);
    try expectRefused("mongodb://:pass@host", error.InvalidArgument, "the user of the connection string is empty: mongodb://user:password@host");
    try expectRefused("mongodb://@host", error.InvalidArgument, "the user of the connection string is empty: mongodb://user:password@host");
    try expectRefused("mongodb://%FF:x@host", error.InvalidArgument, "the user of the connection string is not UTF-8 once percent-decoded");
}

test "the database of the path, authSource and authMechanism, SCRAM-SHA-256 or SCRAM-SHA-1" {
    var uri = try parse("mongodb://app:secret@host/app?authSource=users&authMechanism=SCRAM-SHA-256");
    defer uri.deinit(testing.allocator);
    try testing.expectEqualStrings("app", uri.database.?);
    try testing.expectEqualStrings("users", uri.auth_source.?);
    try testing.expectEqual(Uri.Mechanism.scram_sha_256, uri.auth_mechanism.?);

    var sha1 = try parse("mongodb://app:secret@host/?authMechanism=SCRAM-SHA-1");
    defer sha1.deinit(testing.allocator);
    try testing.expectEqual(Uri.Mechanism.scram_sha_1, sha1.auth_mechanism.?);
    try testing.expectEqualStrings("SCRAM-SHA-1", sha1.auth_mechanism.?.name());
    try testing.expect(sha1.database == null and sha1.auth_source == null);

    for ([_][]const u8{ "MONGODB-X509", "PLAIN", "GSSAPI", "MONGODB-AWS", "MONGODB-OIDC", "MONGODB-CR", "SCRAM-SHA-512" }) |name| {
        var buffer: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "mongodb://app:secret@host/?authMechanism={s}", .{name});
        try expectRefused(text, error.Unsupported, try std.fmt.bufPrint(buffer[text.len..], "authMechanism={s}: v0.1 authenticates with SCRAM-SHA-256 or SCRAM-SHA-1 only", .{name}));
    }
    try expectRefused("mongodb://app:secret@host/?authMechanism=scram-sha-256", error.InvalidArgument, "authMechanism is SCRAM-SHA-256 or SCRAM-SHA-1, as written here; got 'scram-sha-256'");
    try expectRefused("mongodb://app:secret@host/?authSource=", error.InvalidArgument, "authSource is a database name of 1 to 63 bytes; this one is 0");
    try expectRefused("mongodb://app:secret@host/?authSource=a.b", error.InvalidArgument, "authSource is a database name, without / \\ . \" $, a space or NUL");
    try expectRefused("mongodb://app:secret@host/?authSource=a%FF", error.InvalidArgument, "authSource is a database name, of UTF-8 once percent-decoded");
    try expectRefused("mongodb://host/a%C3", error.InvalidArgument, "the database of the connection string is a database name, of UTF-8 once percent-decoded");
    try expectRefused("mongodb://host/?authSource=admin", error.InvalidArgument, "authSource and authMechanism go with a user: mongodb://user:password@host/?authSource=admin");
    try expectRefused("mongodb://host/?authMechanism=SCRAM-SHA-256", error.InvalidArgument, "authSource and authMechanism go with a user: mongodb://user:password@host/?authSource=admin");
    try expectRefused("mongodb://host/a.b", error.InvalidArgument, "the database of the connection string is a database name, without / \\ . \" $, a space or NUL");
    try expectRefused("mongodb://host/a%2Fb", error.InvalidArgument, "the database of the connection string is a database name, without / \\ . \" $, a space or NUL");
    try expectRefused("mongodb://host/a%2", error.InvalidArgument, "the database of the connection string holds a '%' without two hex digits after it; write '%' as %25");
}

test "appName is 1 to 128 bytes of UTF-8" {
    var uri = try parse("mongodb://host/?appName=orders%20service");
    defer uri.deinit(testing.allocator);
    try testing.expectEqualStrings("orders service", uri.app_name.?);

    const longest = "mongodb://host/?appName=" ++ &@as([128]u8, @splat('a'));
    var at_limit = try parse(longest);
    defer at_limit.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 128), at_limit.app_name.?.len);

    try expectRefused(longest ++ "a", error.InvalidArgument, "appName is 1 to 128 bytes long; this one is 129");
    try expectRefused("mongodb://host/?appName=", error.InvalidArgument, "appName is 1 to 128 bytes long; this one is 0");
    try expectRefused("mongodb://host/?appName=%FF", error.InvalidArgument, "appName is not UTF-8 once percent-decoded");
}

test "tls=false and ssl=false are taken" {
    var uri = try parse("mongodb://host/?tls=false&ssl=false");
    uri.deinit(testing.allocator);
}

test "TLS is Unsupported: tls=true, ssl=true and any tls option, whatever its value" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "tls=true", "tls=true" },
        .{ "ssl=true", "ssl=true" },
        .{ "TLS=true", "tls=true" },
        .{ "tlsCAFile=%2Fetc%2Fca.pem", "tlsCAFile" },
        .{ "tlsInsecure=true", "tlsInsecure" },
        .{ "tlsInsecure=false", "tlsInsecure" },
        .{ "tlsAllowInvalidCertificates=true", "tlsAllowInvalidCertificates" },
        .{ "tlsAllowInvalidHostnames=true", "tlsAllowInvalidHostnames" },
        .{ "tlsCertificateKeyFile=client.pem", "tlsCertificateKeyFile" },
        .{ "tlsCertificateKeyFilePassword=secret", "tlsCertificateKeyFilePassword" },
        .{ "sslInvalidHostNameAllowed=true", "sslInvalidHostNameAllowed" },
    };
    for (cases) |case| {
        var buffer: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "mongodb://host/?{s}", .{case[0]});
        try expectRefused(text, error.Unsupported, try std.fmt.bufPrint(buffer[text.len..], "{s}: " ++ no_tls, .{case[1]}));
    }
    try expectRefused("mongodb://host/?tls=yes", error.InvalidArgument, "tls is true or false; got 'yes'");
}

test "connectTimeoutMS, serverSelectionTimeoutMS and timeoutMS, with their defaults" {
    var defaults = try parse("mongodb://host");
    defer defaults.deinit(testing.allocator);
    try testing.expectEqual(std.Io.Duration.fromSeconds(10), defaults.connect_timeout.?);
    try testing.expectEqual(std.Io.Duration.fromSeconds(30), defaults.server_selection_timeout);
    try testing.expect(defaults.timeout == null);

    var set = try parse("mongodb://host/?connectTimeoutMS=2500&serverSelectionTimeoutMS=5000&timeoutMS=1500");
    defer set.deinit(testing.allocator);
    try testing.expectEqual(std.Io.Duration.fromMilliseconds(2500), set.connect_timeout.?);
    try testing.expectEqual(std.Io.Duration.fromMilliseconds(5000), set.server_selection_timeout);
    try testing.expectEqual(std.Io.Duration.fromMilliseconds(1500), set.timeout.?);

    // 0 is no limit for the connect timeout and for the deadline.
    var unlimited = try parse("mongodb://host/?connectTimeoutMS=0&timeoutMS=0");
    defer unlimited.deinit(testing.allocator);
    try testing.expect(unlimited.connect_timeout == null and unlimited.timeout == null);

    try expectRefused("mongodb://host/?serverSelectionTimeoutMS=0", error.InvalidArgument, "serverSelectionTimeoutMS is at least 1");
    try expectRefused("mongodb://host/?connectTimeoutMS=-1", error.InvalidArgument, "connectTimeoutMS is a whole number from 0 to 4294967295; got '-1'");
    try expectRefused("mongodb://host/?timeoutMS=1.5", error.InvalidArgument, "timeoutMS is a whole number from 0 to 4294967295; got '1.5'");
    try expectRefused("mongodb://host/?timeoutMS=4294967296", error.InvalidArgument, "timeoutMS is a whole number from 0 to 4294967295; got '4294967296'");
}

test "maxPoolSize, maxConnecting and maxIdleTimeMS, with their defaults; maxPoolSize=0 is InvalidArgument" {
    var defaults = try parse("mongodb://host");
    defer defaults.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 100), defaults.max_pool_size);
    try testing.expectEqual(@as(u32, 2), defaults.max_connecting);
    try testing.expect(defaults.max_idle_time == null);

    var set = try parse("mongodb://host/?maxPoolSize=4&maxConnecting=1&maxIdleTimeMS=60000");
    defer set.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 4), set.max_pool_size);
    try testing.expectEqual(@as(u32, 1), set.max_connecting);
    try testing.expectEqual(std.Io.Duration.fromSeconds(60), set.max_idle_time.?);

    var idle_forever = try parse("mongodb://host/?maxIdleTimeMS=0");
    defer idle_forever.deinit(testing.allocator);
    try testing.expect(idle_forever.max_idle_time == null);

    try expectRefused("mongodb://host/?maxPoolSize=0", error.InvalidArgument, "maxPoolSize is at least 1: v0.1 has no pool without a limit");
    try expectRefused("mongodb://host/?maxConnecting=0", error.InvalidArgument, "maxConnecting is at least 1");
}

test "minPoolSize is 0 only" {
    var uri = try parse("mongodb://host/?minPoolSize=0");
    uri.deinit(testing.allocator);
    try expectRefused("mongodb://host/?minPoolSize=1", error.Unsupported, "minPoolSize: v0.1 opens connections only when operations need them, so minPoolSize is 0");
}

test "directConnection takes either value: there is one host and nothing else to find" {
    for ([_][]const u8{ "mongodb://host/?directConnection=true", "mongodb://host/?directConnection=false" }) |text| {
        var uri = try parse(text);
        uri.deinit(testing.allocator);
    }
    try expectRefused("mongodb://host/?directConnection=1", error.InvalidArgument, "directConnection is true or false; got '1'");
}

test "replicaSet and readPreference are Unsupported: v0.1 works with a standalone mongod only" {
    try expectRefused("mongodb://host/?replicaSet=rs0", error.Unsupported, "replicaSet: " ++ standalone_only);
    try expectRefused("mongodb://host/?readPreference=primary", error.Unsupported, "readPreference: " ++ standalone_only);
    try expectRefused("mongodb://host/?readPreference=secondaryPreferred", error.Unsupported, "readPreference: " ++ standalone_only);
}

test "retryWrites and retryReads: false is taken, true is Unsupported, since v0.1 retries nothing" {
    var uri = try parse("mongodb://host/?retryWrites=false&retryReads=false");
    uri.deinit(testing.allocator);
    try expectRefused("mongodb://host/?retryWrites=true", error.Unsupported, "retryWrites=true: v0.1 retries nothing; set retryWrites=false or leave it out");
    try expectRefused("mongodb://host/?retryReads=true", error.Unsupported, "retryReads=true: v0.1 retries nothing; set retryReads=false or leave it out");
}

test "options that v0.1 cannot honour are Unsupported, with what to do instead" {
    const write_concern = "v0.1 takes no write concern from the connection string: put writeConcern in the command, or leave the server's default";
    const proxy = "v0.1 connects without a proxy";
    const srv = "v0.1 does not look up SRV records";
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "w=majority", "w: " ++ write_concern },
        .{ "journal=true", "journal: " ++ write_concern },
        .{ "wTimeoutMS=1000", "wTimeoutMS: " ++ write_concern },
        .{ "readConcernLevel=majority", "readConcernLevel: v0.1 takes no read concern from the connection string: put readConcern in the command, or leave the server's default" },
        .{ "readPreferenceTags=dc:ny", "readPreferenceTags: " ++ standalone_only },
        .{ "maxStalenessSeconds=90", "maxStalenessSeconds: " ++ standalone_only },
        .{ "loadBalanced=true", "loadBalanced=true: v0.1 connects to a standalone mongod, not through a load balancer" },
        .{ "socketTimeoutMS=1000", "socketTimeoutMS: v0.1 bounds operations by their deadline; use timeoutMS for a default one" },
        .{ "waitQueueTimeoutMS=1000", "waitQueueTimeoutMS: v0.1 bounds the wait for a connection by the deadline of the operation and serverSelectionTimeoutMS; use timeoutMS for a default deadline" },
        .{ "authMechanismProperties=SERVICE_NAME:mongodb", "authMechanismProperties: it belongs to mechanisms other than SCRAM, which v0.1 does not have" },
        .{ "srvServiceName=mongodb", "srvServiceName: " ++ srv },
        .{ "srvMaxHosts=1", "srvMaxHosts: " ++ srv },
        .{ "proxyHost=proxy.example.com", "proxyHost: " ++ proxy },
        .{ "proxyPort=1080", "proxyPort: " ++ proxy },
        .{ "proxyUsername=user", "proxyUsername: " ++ proxy },
        .{ "proxyPassword=hunter2", "proxyPassword: " ++ proxy },
    };
    for (cases) |case| {
        var buffer: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "mongodb://host/?{s}", .{case[0]});
        try expectRefused(text, error.Unsupported, case[1]);
    }
    var balanced = try parse("mongodb://host/?loadBalanced=false");
    balanced.deinit(testing.allocator);
}

test "options that change nothing here, and options the driver does not know, are skipped with a warning" {
    // The warnings go to the log; keep them out of the test's output.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var uri = try parse("mongodb://host/?compressors=zstd,zlib&zlibCompressionLevel=6&heartbeatFrequencyMS=1000" ++
        "&localThresholdMS=15&serverSelectionTryOnce=false&serverMonitoringMode=poll&uuidRepresentation=standard&zefirNoSuchOption=1");
    defer uri.deinit(testing.allocator);
    var defaults = try parse("mongodb://host");
    defer defaults.deinit(testing.allocator);
    try testing.expectEqualStrings(defaults.host, uri.host);
    try testing.expectEqual(defaults.port, uri.port);
    try testing.expectEqual(defaults.connect_timeout, uri.connect_timeout);
    try testing.expectEqual(defaults.server_selection_timeout, uri.server_selection_timeout);
    try testing.expectEqual(defaults.max_pool_size, uri.max_pool_size);
    try testing.expect(uri.app_name == null and uri.timeout == null);
}

test "option names are case-insensitive, an option given twice is InvalidArgument, and empty pairs are skipped" {
    var uri = try parse("mongodb://host/?&APPNAME=orders&MaxPoolSize=7&");
    defer uri.deinit(testing.allocator);
    try testing.expectEqualStrings("orders", uri.app_name.?);
    try testing.expectEqual(@as(u32, 7), uri.max_pool_size);
    try expectRefused("mongodb://host/?appName=a&appname=b", error.InvalidArgument, "the option appName is given twice in the connection string; keep one");
    try expectRefused("mongodb://host/?appName", error.InvalidArgument, "the option 'appName' of the connection string has no value: write appName=value");
    try expectRefused("mongodb://host/?=x", error.InvalidArgument, "an option of the connection string has no name: write name=value");
    try expectRefused("mongodb://host/?appName=a%2", error.InvalidArgument, "the value of appName holds a '%' without two hex digits after it; write '%' as %25");
}

fn parseAndFree(gpa: std.mem.Allocator, text: []const u8) !void {
    var uri = try Uri.parse(gpa, text, null);
    uri.deinit(gpa);
}

test "nothing leaks when memory runs out" {
    try testing.checkAllAllocationFailures(testing.allocator, parseAndFree, .{"mongodb://app:p%40ss@[::1]:27018/app?appName=orders&authSource=admin"});
}
