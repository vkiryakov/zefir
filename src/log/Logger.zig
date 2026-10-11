//! A logger handle: two pointers, copied by value and shared freely
//! between threads. `init` creates the engine every handle points to;
//! `scoped` derives handles that write a scope.

const std = @import("std");
const Engine = @import("Engine.zig");
const options = @import("options.zig");
const scopes = @import("scopes.zig");
const field_checks = @import("fields.zig");
const Level = @import("level.zig").Level;
const testing = std.testing;

const Logger = @This();

engine: *Engine,
scope: *const scopes.Entry,

pub const InitError = Engine.InitError;

/// Creates the engine: the only allocations the logger makes. The options
/// may be freed once `init` returns; the logger copies what it keeps. Call
/// `deinit` once, after the last record, on any handle of this logger: all
/// of them become invalid. Use one logger per process for stdout: two
/// loggers on one stdout do not coordinate their writes.
pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: options.Options) InitError!Logger {
    const engine = try Engine.create(gpa, io, opts);
    return .{ .engine = engine, .scope = &engine.scope_table.root };
}

pub fn deinit(self: Logger) void {
    self.engine.destroy();
}

/// Logs at `.trace`. `message` is a constant: variable data goes in
/// `fields`, a struct literal such as `.{ .user_id = id }`. Logging never
/// fails and never allocates; problems are counted in `stats`.
pub fn trace(self: Logger, comptime message: []const u8, fields: anytype) void {
    comptime field_checks.check(@TypeOf(fields));
    self.log(.trace, message, fields);
}

/// Logs at `.debug`; see `trace`.
pub fn debug(self: Logger, comptime message: []const u8, fields: anytype) void {
    comptime field_checks.check(@TypeOf(fields));
    self.log(.debug, message, fields);
}

/// Logs at `.info`; see `trace`.
pub fn info(self: Logger, comptime message: []const u8, fields: anytype) void {
    comptime field_checks.check(@TypeOf(fields));
    self.log(.info, message, fields);
}

/// Logs at `.warn`; see `trace`.
pub fn warn(self: Logger, comptime message: []const u8, fields: anytype) void {
    comptime field_checks.check(@TypeOf(fields));
    self.log(.warn, message, fields);
}

/// Logs at `.err`, written as "error"; see `trace`.
pub fn err(self: Logger, comptime message: []const u8, fields: anytype) void {
    comptime field_checks.check(@TypeOf(fields));
    self.log(.err, message, fields);
}

fn log(self: Logger, comptime level: Level, comptime message: []const u8, fields: anytype) void {
    if (!self.enabled(level)) return;
    self.engine.emit(level, self.scope, message, fields);
}

/// Whether a record at `level` would be written. Field values are computed
/// even when the level is off, so check this before costly ones.
pub fn enabled(self: Logger, level: Level) bool {
    return @backingInt(level) >= @backingInt(self.scope.level.load(.monotonic));
}

/// A handle that writes `name` as its records' scope, in place of this
/// handle's scope. The name is copied (up to 128 bytes, cut between
/// characters), so it need not outlive the handle. The first call with a
/// new name takes a short lock; later calls only search. Past 256 names a
/// handle logs without a scope, at the global level, and
/// `stats().scopes_overflow` counts it.
pub fn scoped(self: Logger, name: []const u8) Logger {
    return .{ .engine = self.engine, .scope = self.engine.scope_table.find(name) };
}

/// Sets the global threshold. Scopes without a rule follow it; every
/// handle sees the change at once.
pub fn setLevel(self: Logger, level: Level) void {
    self.engine.scope_table.setGlobal(level);
}

/// Sets the level of scope `prefix` and its subscopes (`zefir.rpc` covers
/// `zefir.rpc.server`, not `zefir.rpcx`), or removes the rule when `level`
/// is null. The longest matching prefix wins, and every handle sees the
/// change at once. A logger keeps at most 64 rules.
pub fn setScopeLevel(self: Logger, prefix: []const u8, level: ?Level) error{ TooManyRules, EmptyPrefix }!void {
    return self.engine.scope_table.setRule(prefix, level);
}

/// Counters since `init`, readable from any thread.
pub fn stats(self: Logger) Engine.Stats {
    return self.engine.stats();
}

test "init and deinit leave nothing behind; the first handle has no scope" {
    const logger: Logger = try .init(testing.allocator, testing.io, .{});
    defer logger.deinit();
    try testing.expectEqualStrings("", logger.scope.name());
    try testing.expectEqual(@as(u64, 0), logger.stats().accepted);
}

/// A logger over an in-memory writer.
const Capture = struct {
    out: std.Io.Writer.Allocating,
    logger: Logger,

    /// `capture` must stay put: the logger keeps a pointer to `capture.out`.
    fn open(capture: *Capture, opts: options.Options) !void {
        capture.out = .init(testing.allocator);
        errdefer capture.out.deinit();
        var with_output = opts;
        with_output.output = .{ .writer = &capture.out.writer };
        capture.logger = try .init(testing.allocator, testing.io, with_output);
    }

    fn close(capture: *Capture) void {
        capture.logger.deinit();
        capture.out.deinit();
    }

    /// Checks every record written so far; each is given without its
    /// timestamp, which is only checked for its shape.
    fn expect(capture: *Capture, format: options.Format, records: []const []const u8) !void {
        var lines = std.mem.splitScalar(u8, capture.out.written(), '\n');
        for (records) |want| {
            const line = lines.next() orelse return error.TestExpectedMoreRecords;
            const time_at: usize = if (format == .json) "{\"timestamp\":\"".len else 0;
            if (line.len < time_at + 24) return error.TestRecordTooShort;
            try expectTimestamp(line[time_at..][0..24]);
            try testing.expectEqualStrings(want, line[time_at + 24 ..]);
            if (format == .json) try testing.expect(try std.json.validate(testing.allocator, line));
        }
        try testing.expectEqualStrings("", lines.rest());
    }
};

fn expectTimestamp(s: []const u8) !void {
    const shape = "dddd-dd-ddTdd:dd:dd.dddZ";
    for (shape, s) |want, got| {
        if (want == 'd') try testing.expect(std.ascii.isDigit(got)) else try testing.expectEqual(want, got);
    }
}

/// 600 bytes: longer than a 300-byte record.
const long_message = &@as([600]u8, @splat('x'));

test "records carry the level, message, service, scope and fields" {
    var c: Capture = undefined;
    try c.open(.{ .service = .{ .name = "user-service", .version = "1.0.0" } });
    defer c.close();
    var user_id: u64 = 42;
    _ = &user_id;
    c.logger.scoped("users").info("User created", .{ .user_id = user_id, .email = "ada@example.com", .admin = false });
    c.logger.err("Payment failed", .{ .order_id = 1001 });
    try c.expect(.json, &.{
        "\",\"level\":\"info\",\"message\":\"User created\",\"service.name\":\"user-service\",\"service.version\":\"1.0.0\",\"scope\":\"users\",\"user_id\":42,\"email\":\"ada@example.com\",\"admin\":false}",
        "\",\"level\":\"error\",\"message\":\"Payment failed\",\"service.name\":\"user-service\",\"service.version\":\"1.0.0\",\"order_id\":1001}",
    });
}

test "the text format writes one readable line per record, without the service" {
    var c: Capture = undefined;
    try c.open(.{ .format = .text, .service = .{ .name = "user-service" } });
    defer c.close();
    c.logger.scoped("users").warn("Slow query", .{ .ms = 250, .table = "users" });
    c.logger.info("Started", .{ .port = 9000 });
    try c.expect(.text, &.{
        " WARN  [users] Slow query ms=250 table=users",
        " INFO  Started port=9000",
    });
}

test "records below the threshold are skipped, and enabled says so first" {
    var c: Capture = undefined;
    try c.open(.{ .level = .warn });
    defer c.close();
    try testing.expect(!c.logger.enabled(.info));
    try testing.expect(c.logger.enabled(.warn));
    c.logger.trace("no", .{});
    c.logger.debug("no", .{});
    c.logger.info("no", .{});
    c.logger.warn("yes", .{});
    c.logger.setLevel(.trace);
    c.logger.trace("now yes", .{});
    try c.expect(.json, &.{
        "\",\"level\":\"warn\",\"message\":\"yes\"}",
        "\",\"level\":\"trace\",\"message\":\"now yes\"}",
    });
    try testing.expectEqual(@as(u64, 2), c.logger.stats().accepted);
}

test "level changes reach handles created before them" {
    var c: Capture = undefined;
    try c.open(.{ .scopes = &.{.{ .prefix = "db", .level = .err }} });
    defer c.close();
    const server = c.logger.scoped("zefir.rpc.server");
    const pool = c.logger.scoped("db.pool");
    server.debug("hidden", .{});
    pool.warn("hidden", .{});
    try c.logger.setScopeLevel("zefir.rpc", .debug);
    try c.logger.setScopeLevel("db", null);
    server.debug("shown", .{});
    pool.warn("shown", .{});
    c.logger.setLevel(.err);
    server.info("shown: the rule outranks the global level", .{});
    pool.warn("hidden: db has no rule now", .{});
    try testing.expectError(error.EmptyPrefix, c.logger.setScopeLevel("", .debug));
    try c.expect(.json, &.{
        "\",\"level\":\"debug\",\"message\":\"shown\",\"scope\":\"zefir.rpc.server\"}",
        "\",\"level\":\"warn\",\"message\":\"shown\",\"scope\":\"db.pool\"}",
        "\",\"level\":\"info\",\"message\":\"shown: the rule outranks the global level\",\"scope\":\"zefir.rpc.server\"}",
    });
}

test "scoped replaces the scope; an empty name means no scope" {
    var c: Capture = undefined;
    try c.open(.{});
    defer c.close();
    c.logger.scoped("a").scoped("b").info("m", .{});
    c.logger.scoped("a").scoped("").info("m", .{});
    try c.expect(.json, &.{
        "\",\"level\":\"info\",\"message\":\"m\",\"scope\":\"b\"}",
        "\",\"level\":\"info\",\"message\":\"m\"}",
    });
}

test "secret names are redacted; .src is not a field" {
    var c: Capture = undefined;
    try c.open(.{});
    defer c.close();
    var password: []const u8 = "hunter2";
    _ = &password;
    c.logger.info("Login", .{ .src = @src(), .user = "ada", .password = password, .@"db.api_key" = "k", .Cookie = "c" });
    try c.expect(.json, &.{
        "\",\"level\":\"info\",\"message\":\"Login\",\"user\":\"ada\",\"password\":\"[REDACTED]\",\"db.api_key\":\"[REDACTED]\",\"Cookie\":\"[REDACTED]\"}",
    });
}

test "scope names with control characters, broken UTF-8 or too many bytes stay on one line" {
    var c: Capture = undefined;
    try c.open(.{});
    defer c.close();
    c.logger.scoped("a\nb\"c\xff").info("m", .{});
    c.logger.scoped(&@as([300]u8, @splat('s'))).info("m", .{});
    try c.expect(.json, &.{
        "\",\"level\":\"info\",\"message\":\"m\",\"scope\":\"a\\nb\\\"c\u{FFFD}\"}",
        "\",\"level\":\"info\",\"message\":\"m\",\"scope\":\"" ++ &@as([128]u8, @splat('s')) ++ "\"}",
    });
    try testing.expectEqual(@as(u64, 1), c.logger.stats().scope_names_truncated);
}

test "stats count accepted, written, cut and dropped records" {
    var cut: Capture = undefined;
    try cut.open(.{ .max_record_bytes = 300 });
    defer cut.close();
    cut.logger.info(long_message, .{});
    cut.logger.info("short", .{});
    cut.logger.debug("filtered", .{});
    var s = cut.logger.stats();
    try testing.expectEqual(@as(u64, 2), s.accepted);
    try testing.expectEqual(@as(u64, 2), s.written);
    try testing.expectEqual(@as(u64, 1), s.truncated);

    var dropped: Capture = undefined;
    try dropped.open(.{ .max_record_bytes = 300, .oversize = .drop });
    defer dropped.close();
    dropped.logger.info(long_message, .{});
    s = dropped.logger.stats();
    try testing.expectEqual(@as(u64, 1), s.accepted);
    try testing.expectEqual(@as(u64, 0), s.written);
    try testing.expectEqual(@as(u64, 1), s.dropped.oversize);
    try testing.expectEqualStrings("", dropped.out.written());
}

test "a record of exactly 16384 bytes is written whole" {
    var c: Capture = undefined;
    try c.open(.{ .max_record_bytes = 16384 });
    defer c.close();
    const data: [16384]u8 = @splat('d');
    c.logger.info("m", .{ .data = data[0..0] });
    const base = c.out.written().len; // the same record with an empty `data`
    const k = 16384 - base;
    c.logger.info("m", .{ .data = data[0..k] });
    const second = c.out.written()[base..];
    try testing.expectEqual(@as(usize, 16384), second.len);
    try testing.expect(std.mem.find(u8, second, "truncated") == null);
    c.logger.info("m", .{ .data = data[0 .. k + 1] });
    try testing.expectEqual(@as(u64, 1), c.logger.stats().truncated);
}

test "a failing writer: records are counted as dropped" {
    var failing: std.Io.Writer = .failing;
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &failing } });
    defer logger.deinit();
    logger.info("lost", .{});
    logger.info("lost too", .{});
    const s = logger.stats();
    try testing.expectEqual(@as(u64, 2), s.accepted);
    try testing.expectEqual(@as(u64, 0), s.written);
    try testing.expectEqual(@as(u64, 2), s.write_errors);
    try testing.expectEqual(@as(u64, 2), s.dropped.write_failed);
}

test "logging never allocates after init" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const json: Logger = try .init(failing.allocator(), testing.io, .{
        .level = .trace,
        .service = .{ .name = "svc" },
        .output = .{ .writer = &sink.writer },
    });
    defer json.deinit();
    const text: Logger = try .init(failing.allocator(), testing.io, .{
        .format = .text,
        .oversize = .drop,
        .max_record_bytes = 512,
        .output = .{ .writer = &sink.writer },
    });
    defer text.deinit();
    failing.fail_index = failing.alloc_index; // every allocation from here on fails
    const before = failing.allocations;

    var id: u64 = 42;
    _ = &id;
    const huge = &@as([5000]u8, @splat('y')); // longer than both limits: cut in JSON, dropped in text
    inline for (.{ json, text }) |logger| {
        logger.trace("t", .{ .id = id });
        logger.debug("d", .{ .id = id, .name = "x" });
        logger.info("i", .{ .ratio = 0.5 });
        logger.warn("w", .{ .password = "secret" });
        logger.err("e", .{ .failure = error.Boom });
        logger.scoped("new.scope").info("s", .{});
        logger.scoped("new.scope").info("s again", .{});
        try logger.setScopeLevel("new", .debug);
        try logger.setScopeLevel("new", null);
        logger.setLevel(.debug);
        _ = logger.enabled(.info);
        _ = logger.stats();
        logger.info(huge, .{ .id = id });
    }
    try testing.expectEqual(before, failing.allocations);
}

test "threads log, add scopes and change levels at once without losing or mixing records" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &out.writer } });
    defer logger.deinit();

    const producers = 8;
    const per_producer = 500;
    var threads: [producers + 1]std.Thread = undefined;
    for (threads[0..producers], 0..) |*thread, producer| thread.* = try std.Thread.spawn(.{}, produce, .{ logger, producer, per_producer });
    threads[producers] = try std.Thread.spawn(.{}, toggleLevels, .{logger});
    for (threads) |thread| thread.join();

    var next: [producers]usize = @splat(0);
    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue; // the piece after the final '\n'
        try testing.expect(try std.json.validate(testing.allocator, line));
        const producer = try intAfter(line, "\"producer\":");
        try testing.expectEqual(next[producer], try intAfter(line, "\"seq\":"));
        next[producer] += 1;
    }
    for (next) |count| try testing.expectEqual(@as(usize, per_producer), count);
}

/// Logs at warn: every level the toggler sets lets it through.
fn produce(logger: Logger, producer: usize, count: usize) void {
    const work = logger.scoped(if (producer % 2 == 0) "work.even" else "work.odd");
    for (0..count) |seq| work.warn("tick", .{ .producer = producer, .seq = seq });
}

fn toggleLevels(logger: Logger) void {
    var buf: [16]u8 = undefined;
    for (0..200) |i| {
        logger.setScopeLevel("work", if (i % 2 == 0) .debug else .info) catch unreachable;
        logger.setLevel(if (i % 2 == 0) .trace else .info);
        _ = logger.scoped(std.fmt.bufPrint(&buf, "extra.{d}", .{i}) catch unreachable);
    }
}

fn intAfter(line: []const u8, key: []const u8) !usize {
    const start = (std.mem.find(u8, line, key) orelse return error.TestUnexpectedResult) + key.len;
    var end = start;
    while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
    return std.fmt.parseInt(usize, line[start..end], 10);
}

test "a call with many fields writes them all, in order" {
    var c: Capture = undefined;
    try c.open(.{});
    defer c.close();
    var n: u32 = 7;
    _ = &n;
    c.logger.info("wide", .{
        .f00 = 0,
        .f01 = n,
        .f02 = 2,
        .f03 = n,
        .f04 = 4,
        .f05 = n,
        .f06 = 6,
        .f07 = n,
        .f08 = 8,
        .f09 = n,
        .f10 = 10,
        .f11 = n,
        .f12 = 12,
        .f13 = n,
        .f14 = 14,
        .f15 = n,
        .f16 = 16,
        .f17 = n,
        .f18 = 18,
        .f19 = n,
        .f20 = 20,
        .f21 = n,
        .f22 = 22,
        .f23 = n,
        .f24 = 24,
        .f25 = n,
        .f26 = 26,
        .f27 = n,
        .f28 = 28,
        .f29 = n,
        .f30 = 30,
        .f31 = n,
    });
    var want: std.Io.Writer.Allocating = .init(testing.allocator);
    defer want.deinit();
    try want.writer.writeAll("\",\"level\":\"info\",\"message\":\"wide\"");
    for (0..32) |i| try want.writer.print(",\"f{d:0>2}\":{d}", .{ i, if (i % 2 == 0) i else 7 });
    try want.writer.writeByte('}');
    try c.expect(.json, &.{want.written()});
}
