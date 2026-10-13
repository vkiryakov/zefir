//! What a `-ERR` from the server means. The texts are those of
//! nats-server 2.15.1; they are compared without regard to case, since the
//! server's capitalization is not consistent.

const std = @import("std");

pub const Kind = enum {
    /// Wrong, missing, expired or revoked credentials:
    /// `Authorization Violation`, `User Authentication Expired`,
    /// `Account Authentication Expired`, `User Authentication Revoked`.
    authentication_failed,
    /// `Authentication Timeout`: no CONNECT in time.
    authentication_timeout,
    /// `Stale Connection`: the client did not answer the server's PINGs.
    stale_connection,
    /// `maximum connections exceeded`, for the server or the account.
    max_connections,
    /// `Secure Connection - TLS Required`: the server wants TLS, which this
    /// client does not do.
    tls_required,
    /// `Connection throttling is active`.
    refused,
    /// This client sent something the server rejects; a bug here:
    /// `Unknown Protocol Operation`, `Maximum Payload Violation`,
    /// `maximum control line exceeded`, `invalid client protocol`,
    /// `no responders requires headers support`.
    protocol,
    /// `Permissions Violation for ...`: the user may not use a subject.
    permissions_violation,
    /// `maximum subscriptions exceeded`.
    max_subscriptions,
    /// `Invalid Subject`, `Invalid Publish Subject`.
    invalid_subject,
    /// A text this client does not know.
    unknown,

    /// The server closes the connection after this error. After the others
    /// the connection stays, and an unknown text leaves it alone.
    pub fn closesConnection(kind: Kind) bool {
        return switch (kind) {
            .authentication_failed, .authentication_timeout, .stale_connection, .max_connections, .tls_required, .refused, .protocol => true,
            .permissions_violation, .max_subscriptions, .invalid_subject, .unknown => false,
        };
    }
};

/// What a permissions violation refers to.
pub const Permission = struct {
    operation: Operation,
    /// The subject, or the reply-to subject for `.reply`.
    subject: []const u8,
    /// The queue group of a denied subscription, when the text names one.
    queue: ?[]const u8 = null,

    pub const Operation = enum { publish, subscribe, reply };
};

pub const Classified = struct {
    kind: Kind,
    /// For `.permissions_violation` when the text could be read; slices of
    /// the text.
    permission: ?Permission = null,
};

const Rule = struct { prefix: []const u8, kind: Kind };

const rules = [_]Rule{
    .{ .prefix = "Authorization Violation", .kind = .authentication_failed },
    .{ .prefix = "User Authentication Expired", .kind = .authentication_failed },
    .{ .prefix = "Account Authentication Expired", .kind = .authentication_failed },
    .{ .prefix = "User Authentication Revoked", .kind = .authentication_failed },
    .{ .prefix = "Authentication Timeout", .kind = .authentication_timeout },
    .{ .prefix = "Stale Connection", .kind = .stale_connection },
    .{ .prefix = "maximum connections exceeded", .kind = .max_connections },
    .{ .prefix = "maximum account active connections exceeded", .kind = .max_connections },
    .{ .prefix = "Secure Connection - TLS Required", .kind = .tls_required },
    .{ .prefix = "Connection throttling is active", .kind = .refused },
    .{ .prefix = "Unknown Protocol Operation", .kind = .protocol },
    .{ .prefix = "Maximum Payload Violation", .kind = .protocol },
    .{ .prefix = "maximum control line exceeded", .kind = .protocol },
    .{ .prefix = "invalid client protocol", .kind = .protocol },
    .{ .prefix = "no responders requires headers support", .kind = .protocol },
    .{ .prefix = "Permissions Violation for ", .kind = .permissions_violation },
    .{ .prefix = "maximum subscriptions exceeded", .kind = .max_subscriptions },
    .{ .prefix = "Invalid Subject", .kind = .invalid_subject },
    .{ .prefix = "Invalid Publish Subject", .kind = .invalid_subject },
};

/// Classifies the text of `-ERR`, without its quotes.
pub fn classify(text: []const u8) Classified {
    for (rules) |rule| {
        if (!std.ascii.startsWithIgnoreCase(text, rule.prefix)) continue;
        if (rule.kind != .permissions_violation) return .{ .kind = rule.kind };
        return .{ .kind = .permissions_violation, .permission = permission(text[rule.prefix.len..]) };
    }
    return .{ .kind = .unknown };
}

/// Reads `Publish to "s"`, `Publish with Reply of "r"`,
/// `Subscription to "s"`, `Subscription to "s" using queue "q"` and
/// `Subscription to "s", too many tokens`.
fn permission(rest: []const u8) ?Permission {
    const forms = [_]struct { prefix: []const u8, operation: Permission.Operation }{
        .{ .prefix = "Publish with Reply of \"", .operation = .reply },
        .{ .prefix = "Publish to \"", .operation = .publish },
        .{ .prefix = "Subscription to \"", .operation = .subscribe },
    };
    for (forms) |form| {
        if (!std.ascii.startsWithIgnoreCase(rest, form.prefix)) continue;
        const quoted = rest[form.prefix.len..];
        const queue_marker = "\" using queue \"";
        if (form.operation == .subscribe) {
            if (std.mem.find(u8, quoted, queue_marker)) |end| {
                const queue = quoted[end + queue_marker.len ..];
                const queue_end = std.mem.findScalarLast(u8, queue, '"') orelse return null;
                return .{ .operation = .subscribe, .subject = quoted[0..end], .queue = queue[0..queue_end] };
            }
        }
        const end = std.mem.findScalarLast(u8, quoted, '"') orelse return null;
        return .{ .operation = form.operation, .subject = quoted[0..end] };
    }
    return null;
}

const testing = std.testing;

test "fatal errors close the connection" {
    for ([_]struct { []const u8, Kind }{
        .{ "Authorization Violation", .authentication_failed },
        .{ "AUTHORIZATION VIOLATION", .authentication_failed },
        .{ "User Authentication Expired", .authentication_failed },
        .{ "Account Authentication Expired", .authentication_failed },
        .{ "User Authentication Revoked", .authentication_failed },
        .{ "Authentication Timeout", .authentication_timeout },
        .{ "Stale Connection", .stale_connection },
        .{ "maximum connections exceeded", .max_connections },
        .{ "maximum account active connections exceeded", .max_connections },
        .{ "Secure Connection - TLS Required", .tls_required },
        .{ "Connection throttling is active. Please try again later.", .refused },
        .{ "Unknown Protocol Operation", .protocol },
        .{ "Maximum Payload Violation", .protocol },
        .{ "maximum control line exceeded", .protocol },
        .{ "invalid client protocol", .protocol },
        .{ "no responders requires headers support", .protocol },
    }) |case| {
        const classified = classify(case[0]);
        try testing.expectEqual(case[1], classified.kind);
        try testing.expect(classified.kind.closesConnection());
    }
}

test "the connection stays after these, and after unknown texts" {
    for ([_]struct { []const u8, Kind }{
        .{ "maximum subscriptions exceeded", .max_subscriptions },
        .{ "Invalid Subject", .invalid_subject },
        .{ "Invalid Publish Subject", .invalid_subject },
        .{ "Something new in a later server", .unknown },
        .{ "", .unknown },
    }) |case| {
        const classified = classify(case[0]);
        try testing.expectEqual(case[1], classified.kind);
        try testing.expect(!classified.kind.closesConnection());
    }
}

test "permissions violations name the subject" {
    const publish = classify("Permissions Violation for Publish to \"secret.x\"");
    try testing.expectEqual(.permissions_violation, publish.kind);
    try testing.expectEqual(.publish, publish.permission.?.operation);
    try testing.expectEqualStrings("secret.x", publish.permission.?.subject);

    const subscribe = classify("permissions violation for subscription to \"forbidden\"");
    try testing.expectEqual(.subscribe, subscribe.permission.?.operation);
    try testing.expectEqualStrings("forbidden", subscribe.permission.?.subject);
    try testing.expect(subscribe.permission.?.queue == null);

    const queue = classify("Permissions Violation for Subscription to \"jobs.>\" using queue \"workers\"");
    try testing.expectEqualStrings("jobs.>", queue.permission.?.subject);
    try testing.expectEqualStrings("workers", queue.permission.?.queue.?);

    const tokens = classify("Permissions Violation for Subscription to \"a.b.c\", too many tokens");
    try testing.expectEqualStrings("a.b.c", tokens.permission.?.subject);

    const reply = classify("Permissions Violation for Publish with Reply of \"_R_.x\"");
    try testing.expectEqual(.reply, reply.permission.?.operation);
    try testing.expectEqualStrings("_R_.x", reply.permission.?.subject);

    const unreadable = classify("Permissions Violation for something else");
    try testing.expectEqual(.permissions_violation, unreadable.kind);
    try testing.expect(unreadable.permission == null);
}
