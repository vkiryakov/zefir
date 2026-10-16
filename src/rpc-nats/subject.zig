//! The subjects of the NATS transport: the subject of a route, the inbox
//! of a client and the reply-to that a server answers to.
//!
//! A route lives on `[subject_prefix.]service.v<version>.method`, such as
//! `users.v1.getUser`: the major version is in the subject, so replicas of
//! two versions never get each other's requests. A client's inbox is
//! `<inbox_prefix>.<22 random base62 characters>`, and the reply subject
//! of a call is `<inbox>.<call number>`.

const std = @import("std");
const rpc = @import("rpc");

/// The longest subject the transport makes: the limit of lalinsky/nats.zig,
/// so that a subject fits every NATS library.
pub const max_subject_bytes = 255;

/// The longest name of a service or a method.
const max_name_bytes = 64;

/// The longest route subject without a prefix: two names and ".v65535.".
const max_route_bytes = max_name_bytes + ".v65535.".len + max_name_bytes;

/// The longest `subject_prefix`: every route subject with it stays within
/// `max_subject_bytes`.
pub const max_prefix_bytes = max_subject_bytes - 1 - max_route_bytes;

/// The random base62 characters of an inbox: other clients cannot guess
/// it and read the responses.
pub const token_len = 22;

/// The digits of the largest call number.
const max_id_digits = 20;

/// The longest `inbox_prefix`: every reply subject with it stays within
/// `max_subject_bytes`.
pub const max_inbox_prefix_bytes = max_subject_bytes - 1 - token_len - 1 - max_id_digits;

/// What NATS and clients use for inboxes; a route subject never starts
/// with it.
pub const inbox_head = "_INBOX";

/// A token of a subject the transport makes: one or more of
/// `[A-Za-z0-9_-]`.
pub fn isToken(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// Tokens joined by dots, such as "shop" or "shop.eu".
pub fn isTokens(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |token| {
        if (!isToken(token)) return false;
    }
    return true;
}

/// Whether `prefix` may be the `subject_prefix`: tokens, at most
/// `max_prefix_bytes`, and not an inbox.
pub fn isSubjectPrefix(prefix: []const u8) bool {
    return prefix.len <= max_prefix_bytes and isTokens(prefix) and !std.mem.startsWith(u8, prefix, inbox_head);
}

/// Whether `prefix` may be the `inbox_prefix`: tokens, at most
/// `max_inbox_prefix_bytes`.
pub fn isInboxPrefix(prefix: []const u8) bool {
    return prefix.len <= max_inbox_prefix_bytes and isTokens(prefix);
}

/// The subject of `route` in `buffer`: `[prefix.]service.v<version>.method`.
/// Null when a name of the route is not 1 to 64 characters of
/// `[A-Za-z0-9_-]`, its version is 0, or the subject would start with
/// `_INBOX`. `prefix` is one that `isSubjectPrefix` accepts.
pub fn routeSubject(buffer: *[max_subject_bytes]u8, prefix: ?[]const u8, route: rpc.Route) ?[]const u8 {
    if (!isName(route.service) or !isName(route.method) or route.version == 0) return null;
    var w: std.Io.Writer = .fixed(buffer);
    if (prefix) |p| w.print("{s}.", .{p}) catch return null;
    w.print("{s}.v{d}.{s}", .{ route.service, route.version, route.method }) catch return null;
    const subject = w.buffered();
    if (std.mem.startsWith(u8, subject, inbox_head)) return null;
    return subject;
}

fn isName(name: []const u8) bool {
    return name.len <= max_name_bytes and isToken(name);
}

/// Whether a server may publish the response of a request to `reply_to`:
/// a subject without wildcards, spaces or empty tokens, whose first token
/// starts with one of `prefixes` (`_INBOX` takes `_INBOX` and
/// `_INBOX_orders`). Otherwise anyone could send the responses of a
/// service to a subject of their choice; NATS permissions
/// (`allow_responses`) are the main guard, this is the second line.
pub fn isAllowedReplyTo(reply_to: []const u8, prefixes: []const []const u8) bool {
    var it = std.mem.splitScalar(u8, reply_to, '.');
    const first = it.first();
    var token: []const u8 = first;
    while (true) {
        if (token.len == 0) return false;
        for (token) |c| switch (c) {
            0...' ', 0x7f, '*', '>' => return false,
            else => {},
        };
        token = it.next() orelse break;
    }
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, first, prefix)) return true;
    }
    return false;
}

const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

/// Fills `token` with random base62 characters from `io.randomSecure`, as
/// zefir-nats does for its own inbox.
pub fn randomToken(io: std.Io, token: *[token_len]u8) std.Io.RandomSecureError!void {
    var filled: usize = 0;
    var bytes: [64]u8 = undefined;
    while (filled < token.len) {
        try io.randomSecure(&bytes);
        for (bytes) |byte| {
            // Below 248, four times 62, every character is equally likely.
            if (byte >= 248) continue;
            token[filled] = alphabet[byte % alphabet.len];
            filled += 1;
            if (filled == token.len) break;
        }
    }
}

/// The call number at the end of a reply subject `<inbox>.<id>`; null when
/// the last token is not a decimal number.
pub fn replyId(subject: []const u8) ?u64 {
    const dot = std.mem.findScalarLast(u8, subject, '.') orelse return null;
    const digits = subject[dot + 1 ..];
    if (digits.len == 0 or digits.len > max_id_digits) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u64, digits, 10) catch null;
}

/// `<inbox>.<id>` in `buffer`.
pub fn replySubject(buffer: *[max_subject_bytes]u8, inbox: []const u8, id: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}.{d}", .{ inbox, id }) catch unreachable;
}

const testing = std.testing;

test "a route lives on service.v<version>.method, after the prefix" {
    var buffer: [max_subject_bytes]u8 = undefined;
    const route: rpc.Route = .{ .service = "users", .version = 1, .method = "getUser" };
    try testing.expectEqualStrings("users.v1.getUser", routeSubject(&buffer, null, route).?);
    try testing.expectEqualStrings("shop.users.v1.getUser", routeSubject(&buffer, "shop", route).?);
    try testing.expectEqualStrings("shop.eu.users.v65535.get-user_2", routeSubject(&buffer, "shop.eu", .{ .service = "users", .version = 65535, .method = "get-user_2" }).?);
}

test "a route whose names are not tokens, or of version 0, has no subject" {
    var buffer: [max_subject_bytes]u8 = undefined;
    const long: [65]u8 = @splat('a');
    for ([_]rpc.Route{
        .{ .service = "users", .version = 0, .method = "get" },
        .{ .service = "", .version = 1, .method = "get" },
        .{ .service = "users", .version = 1, .method = "" },
        .{ .service = "us.ers", .version = 1, .method = "get" },
        .{ .service = "users", .version = 1, .method = "*" },
        .{ .service = "users", .version = 1, .method = ">" },
        .{ .service = "users", .version = 1, .method = "get user" },
        .{ .service = "$SRV", .version = 1, .method = "get" },
        .{ .service = &long, .version = 1, .method = "get" },
        .{ .service = "users", .version = 1, .method = &long },
        // Inboxes are no routes.
        .{ .service = "_INBOX", .version = 1, .method = "get" },
        .{ .service = "_INBOX_orders", .version = 1, .method = "get" },
    }) |route| {
        try testing.expect(routeSubject(&buffer, null, route) == null);
    }
}

test "the longest route with the longest prefix fits 255 bytes" {
    var buffer: [max_subject_bytes]u8 = undefined;
    const name: [64]u8 = @splat('n');
    const prefix: [max_prefix_bytes]u8 = @splat('p');
    try testing.expect(isSubjectPrefix(&prefix));
    const subject = routeSubject(&buffer, &prefix, .{ .service = &name, .version = 65535, .method = &name }).?;
    try testing.expectEqual(@as(usize, max_subject_bytes), subject.len);
    const longer: [max_prefix_bytes + 1]u8 = @splat('p');
    try testing.expect(!isSubjectPrefix(&longer));
}

test "prefixes: tokens joined by dots, never an inbox" {
    for ([_][]const u8{ "shop", "shop.eu", "a-b_c.D9" }) |prefix| try testing.expect(isSubjectPrefix(prefix));
    for ([_][]const u8{ "", ".", "shop.", ".shop", "shop..eu", "shop eu", "shop.*", "shop.>", "$SYS", "_INBOX", "_INBOX_x.shop", "щ" }) |prefix| {
        try testing.expect(!isSubjectPrefix(prefix));
    }
    try testing.expect(isInboxPrefix("_INBOX"));
    try testing.expect(isInboxPrefix("_INBOX_orders"));
    try testing.expect(isInboxPrefix("svc.inbox"));
    try testing.expect(!isInboxPrefix("_INBOX."));
    try testing.expect(!isInboxPrefix("_INBOX.*"));
    const longest: [max_inbox_prefix_bytes]u8 = @splat('i');
    try testing.expect(isInboxPrefix(&longest));
    const longer: [max_inbox_prefix_bytes + 1]u8 = @splat('i');
    try testing.expect(!isInboxPrefix(&longer));
}

test "a server answers only to a reply-to under an allowed prefix" {
    const inbox: []const []const u8 = &.{"_INBOX"};
    for ([_][]const u8{ "_INBOX.abc.1", "_INBOX_orders.abc.1", "_INBOX", "_INBOXES.x" }) |reply_to| {
        try testing.expect(isAllowedReplyTo(reply_to, inbox));
    }
    for ([_][]const u8{ "", "users.v1.getUser", "x._INBOX.1", "_INBOX.*", "_INBOX.>", "_INBOX.a b", "_INBOX..1", "_INBOX.1.", "_INBOX\r\n.1", "_INBOX.1\x7f" }) |reply_to| {
        try testing.expect(!isAllowedReplyTo(reply_to, inbox));
    }
    try testing.expect(isAllowedReplyTo("svc.replies.7", &.{ "_INBOX", "svc" }));
    try testing.expect(!isAllowedReplyTo("_INBOX.a.1", &.{}));
}

test "a token is 22 base62 characters, and two are not the same" {
    var a: [token_len]u8 = undefined;
    var b: [token_len]u8 = undefined;
    try randomToken(testing.io, &a);
    try randomToken(testing.io, &b);
    for (a ++ b) |c| try testing.expect(std.mem.findScalar(u8, alphabet, c) != null);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "reply subjects carry the call number in their last token" {
    var buffer: [max_subject_bytes]u8 = undefined;
    const subject = replySubject(&buffer, "_INBOX.tokentokentokentoken42", 18446744073709551615);
    try testing.expectEqualStrings("_INBOX.tokentokentokentoken42.18446744073709551615", subject);
    try testing.expectEqual(@as(?u64, 18446744073709551615), replyId(subject));
    try testing.expectEqual(@as(?u64, 7), replyId("_INBOX.t.7"));
    for ([_][]const u8{ "_INBOX.t", "_INBOX.t.", "_INBOX.t.x7", "_INBOX.t.-1", "_INBOX.t.18446744073709551616", "_INBOX.t.+7", "7" }) |foreign| {
        try testing.expectEqual(@as(?u64, null), replyId(foreign));
    }
    // The longest inbox prefix still fits.
    const longest: [max_inbox_prefix_bytes + 1 + token_len]u8 = @splat('i');
    try testing.expectEqual(@as(usize, max_subject_bytes), replySubject(&buffer, &longest, std.math.maxInt(u64)).len);
}
