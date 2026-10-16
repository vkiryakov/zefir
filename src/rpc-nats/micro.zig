//! NATS micro discovery (ADR-32, the NATS Service API) for the server
//! side: every contract of the server, a service and a major version, is a
//! NATS micro service, so `nats micro ls`, `nats micro info users` and
//! `nats micro stats users` see its live replicas, its methods and their
//! counters.
//!
//! A contract `users` of version 1 is the service `users`, version
//! "1.0.0", with an id of its own on every start of every server, and its
//! methods are its endpoints, with their subjects and queue group. It
//! answers, without a queue group, on `$SRV.PING`, `$SRV.INFO` and
//! `$SRV.STATS`, the same followed by `.users`, and by `.users.<id>`. Two
//! versions of a contract on one server are two services of one name.
//! Internal to the module: `Transport.Options.discovery` turns it off.

const std = @import("std");
const rpc = @import("rpc");
const Conn = @import("Conn.zig");
const Transport = @import("Transport.zig");
const shared = @import("shared.zig");
const subject = @import("subject.zig");
const wire = @import("wire.zig");

const log = std.log.scoped(.rpc_nats);

/// What a request asks.
pub const Verb = enum {
    ping,
    info,
    stats,

    /// Its token in a subject: PING, INFO or STATS.
    fn token(verb: Verb) []const u8 {
        return switch (verb) {
            .ping => "PING",
            .info => "INFO",
            .stats => "STATS",
        };
    }

    /// The `type` of its response.
    fn responseType(verb: Verb) []const u8 {
        return switch (verb) {
            .ping => "io.nats.micro.v1.ping_response",
            .info => "io.nats.micro.v1.info_response",
            .stats => "io.nats.micro.v1.stats_response",
        };
    }
};

/// Which services a subject asks: all, those of a name, or one.
const Form = enum { all, name, id };

/// The characters of an id.
pub const id_len = 22;

/// One contract of the server: a NATS micro service.
pub const Contract = struct {
    /// The service of its routes, such as "users".
    name: []const u8,
    version: u16,
    id: [id_len]u8,
    /// Its routes: indices into the routes of the server.
    routes: []u32,
};

/// One subscription of a service: a verb in one form.
pub const Listener = struct {
    transport: *Transport,
    contract: u32,
    verb: Verb,
    sub: Conn.Sub,
    subject_buffer: [max_subject_bytes]u8,
    subject_len: u8,

    pub fn subjectOf(l: *const Listener) []const u8 {
        return l.subject_buffer[0..l.subject_len];
    }
};

/// "$SRV.STATS.<name>.<id>" with the longest name.
const max_subject_bytes = "$SRV.STATS.".len + 64 + 1 + id_len;

/// The services of one start of the server side, with their listeners.
pub const Services = struct {
    contracts: []Contract,
    listeners: []Listener,
    /// The routes of all contracts, each a run of it.
    indices: []u32,
    /// When the server side started, on the real clock: `started` of
    /// STATS.
    started: std.Io.Timestamp,

    pub const empty: Services = .{ .contracts = &.{}, .listeners = &.{}, .indices = &.{}, .started = .zero };
};

/// The services of `routes`, the routes of the server in their order,
/// with a fresh id each and the listeners to subscribe. Allocates from the
/// transport's allocator; free with `free`.
pub fn make(t: *Transport, io: std.Io, routes: []const rpc.Route) error{OutOfMemory}!Services {
    // A Debug allocator may take a cancelable lock.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    const gpa = t.gpa;
    const indices = try gpa.alloc(u32, routes.len);
    errdefer gpa.free(indices);
    var contracts: std.ArrayList(Contract) = .empty;
    defer contracts.deinit(gpa);
    // Each contract takes the routes of its service and version, in order,
    // as one run of `indices`.
    var placed: usize = 0;
    for (routes, 0..) |route, first| {
        const seen = for (contracts.items) |c| {
            if (c.version == route.version and std.mem.eql(u8, c.name, route.service)) break true;
        } else false;
        if (seen) continue;
        const start = placed;
        for (routes[first..], first..) |other, index| {
            if (other.version != route.version or !std.mem.eql(u8, other.service, route.service)) continue;
            indices[placed] = @intCast(index);
            placed += 1;
        }
        var id: [id_len]u8 = undefined;
        randomId(io, &id);
        try contracts.append(gpa, .{ .name = route.service, .version = route.version, .id = id, .routes = indices[start..placed] });
    }
    const owned = try contracts.toOwnedSlice(gpa);
    errdefer gpa.free(owned);
    const listeners = try gpa.alloc(Listener, owned.len * 9);
    var i: usize = 0;
    for (owned, 0..) |*c, contract| {
        for (std.enums.values(Verb)) |verb| {
            for (std.enums.values(Form)) |form| {
                const l = &listeners[i];
                l.* = .{ .transport = t, .contract = @intCast(contract), .verb = verb, .sub = undefined, .subject_buffer = undefined, .subject_len = 0 };
                const name = subjectFor(&l.subject_buffer, verb, form, c);
                l.subject_len = @intCast(name.len);
                i += 1;
            }
        }
    }
    return .{ .contracts = owned, .listeners = listeners, .indices = indices, .started = std.Io.Clock.real.now(io) };
}

/// Frees what `make` made; the listeners are unsubscribed by then.
pub fn free(t: *Transport, io: std.Io, services: Services) void {
    if (services.contracts.len == 0) return;
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    t.gpa.free(services.indices);
    t.gpa.free(services.listeners);
    t.gpa.free(services.contracts);
}

/// `$SRV.<VERB>`, followed by `.<name>` and by `.<name>.<id>`.
fn subjectFor(buffer: *[max_subject_bytes]u8, verb: Verb, form: Form, c: *const Contract) []const u8 {
    return switch (form) {
        .all => std.fmt.bufPrint(buffer, "$SRV.{s}", .{verb.token()}),
        .name => std.fmt.bufPrint(buffer, "$SRV.{s}.{s}", .{ verb.token(), c.name }),
        .id => std.fmt.bufPrint(buffer, "$SRV.{s}.{s}.{s}", .{ verb.token(), c.name, &c.id }),
    } catch unreachable;
}

const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

/// 22 random base62 characters, as nats.go makes the id of a service. An
/// id is no secret: `io.random` is enough.
fn randomId(io: std.Io, id: *[id_len]u8) void {
    var filled: usize = 0;
    var bytes: [64]u8 = undefined;
    while (filled < id.len) {
        io.random(&bytes);
        for (bytes) |byte| {
            // Below 248, four times 62, every character is equally likely.
            if (byte >= 248) continue;
            id[filled] = alphabet[byte % alphabet.len];
            filled += 1;
            if (filled == id.len) break;
        }
    }
}

/// Answers one request to a listener, to its reply subject. Every reply
/// subject the server answers to must be under `reply_prefixes`, as for
/// calls.
pub fn answer(t: *Transport, io: std.Io, l: *const Listener, message: Conn.InMsg) void {
    defer message.release();
    const reply_to = message.reply_to orelse {
        shared.count(t, .requests_without_reply_to);
        return;
    };
    if (!subject.isAllowedReplyTo(reply_to, t.reply_prefixes)) {
        shared.count(t, .requests_with_foreign_reply_to);
        return;
    }
    const services = &t.server.services;
    var out: std.Io.Writer.Allocating = .init(t.gpa);
    defer out.deinit();
    write(&out.writer, t, &services.contracts[l.contract], l.verb, services.started) catch {
        log.debug("no memory for the NATS micro answer to {s}", .{l.subjectOf()});
        return;
    };
    t.conn.publish(io, .{ .subject = reply_to, .payload = out.written() }, shared.timeoutAfter(io, t.options.publish_timeout)) catch |err| switch (err) {
        error.PayloadTooLarge => log.warn("the NATS micro answer to {s} is over the server's max_payload: {d} bytes", .{ l.subjectOf(), out.written().len }),
        else => log.debug("the NATS micro answer to {s} was not published: {t}", .{ l.subjectOf(), err }),
    };
}

/// The JSON of the response to `verb` about contract `c`, as ADR-32 and
/// nats.go write it.
pub fn write(w: *std.Io.Writer, t: *Transport, c: *const Contract, verb: Verb, started: std.Io.Timestamp) std.Io.Writer.Error!void {
    var json: std.json.Stringify = .{ .writer = w };
    try json.beginObject();
    try json.objectField("name");
    try json.write(c.name);
    try json.objectField("id");
    try json.write(@as([]const u8, &c.id));
    try json.objectField("version");
    try json.print("\"{d}.0.0\"", .{c.version});
    try json.objectField("metadata");
    try json.beginObject();
    try json.endObject();
    try json.objectField("type");
    try json.write(verb.responseType());
    switch (verb) {
        .ping => {},
        .info => {
            try json.objectField("description");
            try json.write("");
            try json.objectField("endpoints");
            try json.beginArray();
            for (c.routes) |index| {
                try endpointHead(&json, t, index);
                try json.objectField("metadata");
                try json.write(null);
                try json.endObject();
            }
            try json.endArray();
        },
        .stats => {
            var time: [rfc3339_len]u8 = undefined;
            try json.objectField("started");
            try json.write(rfc3339(&time, started));
            try json.objectField("endpoints");
            try json.beginArray();
            for (c.routes) |index| {
                try endpointHead(&json, t, index);
                const stats = t.server.dispatcher.routeStats(index);
                const total = nanoseconds(stats.processing_time);
                try json.objectField("num_requests");
                try json.write(stats.requests);
                try json.objectField("num_errors");
                try json.write(stats.errors);
                var last_error: [last_error_bytes]u8 = undefined;
                try json.objectField("last_error");
                try json.write(if (stats.last_error) |*last| lastError(&last_error, last) else "");
                try json.objectField("processing_time");
                try json.write(total);
                try json.objectField("average_processing_time");
                try json.write(if (stats.requests == 0) 0 else @divFloor(total, @as(i64, @intCast(@min(stats.requests, std.math.maxInt(i64))))));
                try json.endObject();
            }
            try json.endArray();
        },
    }
    try json.endObject();
}

const LastError = rpc.transport.Dispatcher.RouteStats.LastError;

/// "503:" and the longest app code the engine keeps.
const last_error_bytes = "503:".len + @typeInfo(@FieldType(LastError, "app_code_buffer")).array.len;

/// The last failure as nats.go writes `last_error`, "<code>:<description>":
/// the number of `Nats-Service-Error-Code` and the app code, or the name of
/// the code without one, such as "404:users.not_found". An app code that is
/// not UTF-8 goes by the name of the code too: JSON would carry it as an
/// array of numbers, which the NATS tools cannot read.
fn lastError(buffer: *[last_error_bytes]u8, last: *const LastError) []const u8 {
    const app_code = last.appCode();
    const description = if (app_code.len > 0 and std.unicode.utf8ValidateSlice(app_code)) app_code else @tagName(last.code);
    return std.fmt.bufPrint(buffer, "{d}:{s}", .{ wire.statusOf(last.code), description }) catch unreachable;
}

/// Opens the object of an endpoint with its name, subject and queue group.
fn endpointHead(json: *std.json.Stringify, t: *Transport, index: u32) std.Io.Writer.Error!void {
    const r = &t.server.routes[index];
    try json.beginObject();
    try json.objectField("name");
    try json.write(r.route.method);
    try json.objectField("subject");
    try json.write(r.subjectOf());
    try json.objectField("queue_group");
    try json.write(t.options.queue_group);
}

/// Nanoseconds as Go's `time.Duration`, an i64; saturates.
fn nanoseconds(d: std.Io.Duration) i64 {
    return @intCast(std.math.clamp(d.nanoseconds, 0, std.math.maxInt(i64)));
}

/// "2026-10-15T02:15:00.123456789Z".
pub const rfc3339_len = 30;

/// `ts`, on the real clock, as RFC 3339 in UTC with nanoseconds, the way
/// Go writes a `time.Time`; a time before 1970 is written as 1970.
pub fn rfc3339(buffer: *[rfc3339_len]u8, ts: std.Io.Timestamp) []const u8 {
    const ns: u96 = @intCast(@max(ts.nanoseconds, 0));
    const seconds: u64 = @intCast(@min(ns / std.time.ns_per_s, std.math.maxInt(u64)));
    const fraction: u64 = @intCast(ns % std.time.ns_per_s);
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const day = epoch.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}Z", .{
        day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
        fraction,
    }) catch unreachable;
}

const testing = std.testing;

test "a time is written as Go writes a time.Time in UTC" {
    var buffer: [rfc3339_len]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01T00:00:00.000000000Z", rfc3339(&buffer, .zero));
    try testing.expectEqualStrings("1970-01-01T00:00:00.000000000Z", rfc3339(&buffer, .{ .nanoseconds = -5 }));
    // 2026-10-14T23:28:19.595812004Z, the start of a nats.go service.
    try testing.expectEqualStrings("2026-10-14T23:28:19.595812004Z", rfc3339(&buffer, .{ .nanoseconds = 1_792_020_499_595_812_004 }));
    // A leap day.
    try testing.expectEqualStrings("2024-02-29T12:00:00.000000001Z", rfc3339(&buffer, .{ .nanoseconds = 1_709_208_000_000_000_001 }));
}

test "an id is 22 base62 characters, and two are not the same" {
    var a: [id_len]u8 = undefined;
    var b: [id_len]u8 = undefined;
    randomId(testing.io, &a);
    randomId(testing.io, &b);
    for (a ++ b) |c| try testing.expect(std.mem.findScalar(u8, alphabet, c) != null);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}
