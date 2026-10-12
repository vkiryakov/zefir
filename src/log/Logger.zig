//! A logger handle: two pointers, copied by value and shared freely
//! between threads. `init` creates the engine every handle points to;
//! `scoped` derives handles that write a scope.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const Engine = @import("Engine.zig");
const encode = @import("encode.zig");
const std_log = @import("std_log.zig");
const uninstallStdLog = std_log.uninstall;
const options = @import("options.zig");
const scopes = @import("scopes.zig");
const field_checks = @import("fields.zig");
const Level = @import("level.zig").Level;
const testing = std.testing;

const Logger = @This();

engine: *Engine,
scope: *const scopes.Entry,
/// The trace this handle writes, from `withContext`.
ids: ?Ids = null,

/// Copied from a `core.Context`: the handle borrows nothing.
const Ids = struct { trace_id: core.TraceId, span_id: core.SpanId };

pub const InitError = Engine.InitError;

/// Creates the engine: the only allocations the logger makes. The options
/// may be freed once `init` returns; the logger copies what it keeps. Call
/// `deinit` once, after the last record, on any handle of this logger: all
/// of them become invalid. Use one logger per process for stdout: two
/// loggers on one stdout do not coordinate their writes.
///
/// Records are read from the clock and written through `io`, so log only
/// from threads or tasks of that `io` (under `std.Io.Threaded`, any thread).
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
    var hex: encode.TraceHex = undefined;
    const ids_hex: ?*const encode.TraceHex = if (self.ids) |ids| blk: {
        hex = .{ .trace_id = ids.trace_id.toHex(), .span_id = ids.span_id.toHex() };
        break :blk &hex;
    } else null;
    self.engine.emit(level, self.scope, ids_hex, message, fields);
}

/// Whether a record at `level` would be written. Field values are computed
/// even when the level is off, so check this before costly ones.
pub fn enabled(self: Logger, level: Level) bool {
    return @backingInt(level) >= @backingInt(self.scope.level.load(.monotonic));
}

/// A handle that writes `name` as its records' scope, in place of this
/// handle's scope. The name is copied, so it need not outlive the handle.
/// It is kept as records write it, escaped, and cut between characters to
/// 128 bytes (`stats().scope_names_truncated` counts it): names that agree
/// in those 128 bytes are one scope. The first call with a new name takes a
/// short lock; later calls only search. Past 256 names a handle logs
/// without a scope, at the global level, and `stats().scopes_overflow`
/// counts it.
pub fn scoped(self: Logger, name: []const u8) Logger {
    return .{ .engine = self.engine, .scope = self.engine.scope_table.find(name), .ids = self.ids };
}

/// A handle whose records carry the trace and span ids of `ctx`, in place
/// of this handle's; a context without a trace gives a handle without them.
/// The ids are copied, so the handle may outlive `ctx`. A deadline or a
/// cancellation in `ctx` does not affect logging.
pub fn withContext(self: Logger, ctx: core.Context) Logger {
    var handle = self;
    handle.ids = if (ctx.trace) |t| .{ .trace_id = t.trace_id, .span_id = t.span_id } else null;
    return handle;
}

/// Sets the global threshold. Scopes without a rule follow it; every
/// handle sees the change at once.
pub fn setLevel(self: Logger, level: Level) void {
    self.engine.scope_table.setGlobal(level);
}

/// Sets the level of scope `prefix` and its subscopes (`zefir.rpc` covers
/// `zefir.rpc.server`, not `zefir.rpcx`), or removes the rule when `level`
/// is null. The longest matching prefix wins, and every handle sees the
/// change at once. A trailing dot is ignored (`zefir.` is `zefir`), and the
/// prefix is cut to 128 bytes as scope names are. A logger keeps at most 64
/// rules.
pub fn setScopeLevel(self: Logger, prefix: []const u8, level: ?Level) error{ TooManyRules, EmptyPrefix }!void {
    return self.engine.scope_table.setRule(prefix, level);
}

/// Sends std.log to this logger, in place of a logger installed before. The
/// root file must set
/// `pub const std_options: std.Options = .{ .logFn = zefir.log.stdLogFn };`.
/// std.log's scope becomes the record's scope and its text the message;
/// std's compile-time level filter still runs first. `deinit` removes the
/// bridge, `zefir.log.uninstallStdLog` does it earlier; both wait for the
/// std.log calls that may still be inside this logger.
pub fn installStdLog(self: Logger) void {
    std_log.install(self.engine);
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

/// 600 bytes: longer than a 400-byte record.
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

test "secret names are redacted; .src is the call site, not a field" {
    var c: Capture = undefined;
    try c.open(.{});
    defer c.close();
    var password: []const u8 = "hunter2";
    _ = &password;
    const here = @src();
    c.logger.info("Login", .{ .src = here, .user = "ada", .password = password, .@"db.api_key" = "k", .Cookie = "c" });
    try c.expect(.json, &.{
        "\",\"level\":\"info\",\"message\":\"Login\",\"source\":{\"file\":\"Logger.zig\",\"line\":" ++ std.fmt.comptimePrint("{d}", .{here.line}) ++
            "},\"user\":\"ada\",\"password\":\"[REDACTED]\",\"db.api_key\":\"[REDACTED]\",\"Cookie\":\"[REDACTED]\"}",
    });
}

fn traceContext(trace_hex: []const u8, span_hex: []const u8) !core.TraceContext {
    return .{ .trace_id = try .parseHex(trace_hex), .span_id = try .parseHex(span_hex), .flags = .{}, .state = .empty };
}

test "withContext adds the trace and span ids; scoped and withContext compose in either order" {
    var c: Capture = undefined;
    try c.open(.{});
    defer c.close();
    const ctx = core.Context.root.withTrace(try traceContext("4bf92f3577b34da6a3ce929d0e0e4736", "00f067aa0ba902b7"));
    const here = @src();
    c.logger.withContext(ctx).scoped("users").info("a", .{ .id = 1 });
    c.logger.scoped("users").withContext(ctx).info("b", .{ .src = here });
    c.logger.withContext(ctx).withContext(.root).info("c", .{}); // a context without a trace clears the ids
    c.logger.info("d", .{});
    const ids = ",\"trace_id\":\"4bf92f3577b34da6a3ce929d0e0e4736\",\"span_id\":\"00f067aa0ba902b7\"";
    try c.expect(.json, &.{
        "\",\"level\":\"info\",\"message\":\"a\",\"scope\":\"users\"" ++ ids ++ ",\"id\":1}",
        "\",\"level\":\"info\",\"message\":\"b\",\"scope\":\"users\",\"source\":{\"file\":\"Logger.zig\",\"line\":" ++ std.fmt.comptimePrint("{d}", .{here.line}) ++ "}" ++ ids ++ "}",
        "\",\"level\":\"info\",\"message\":\"c\"}",
        "\",\"level\":\"info\",\"message\":\"d\"}",
    });
}

test "text puts the trace ids after the fields" {
    var c: Capture = undefined;
    try c.open(.{ .format = .text });
    defer c.close();
    const ctx = core.Context.root.withTrace(try traceContext("4bf92f3577b34da6a3ce929d0e0e4736", "00f067aa0ba902b7"));
    c.logger.withContext(ctx).info("Fetching user", .{ .user_id = 42 });
    try c.expect(.text, &.{" INFO  Fetching user user_id=42 trace_id=4bf92f3577b34da6a3ce929d0e0e4736 span_id=00f067aa0ba902b7"});
}

test "nested values, format, logValue, hex, the call site, the context and std.log never allocate" {
    const hex = @import("hex.zig").hex;
    const Price = struct {
        cents: u32,
        pub fn format(p: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("{d} cents", .{p.cents});
        }
    };
    const User = struct {
        id: u64,
        password_hash: []const u8,
        pub fn logValue(u: @This()) struct { id: u64 } {
            return .{ .id = u.id };
        }
    };
    const Config = struct { host: []const u8, ports: [2]u16, state: union(enum) { idle, running: u32 }, next: ?*const @This() };
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const json: Logger = try .init(failing.allocator(), testing.io, .{ .level = .trace, .source = .{ .default = .full }, .output = .{ .writer = &sink.writer } });
    defer json.deinit();
    const text: Logger = try .init(failing.allocator(), testing.io, .{ .format = .text, .max_record_bytes = 512, .output = .{ .writer = &sink.writer } });
    defer text.deinit();
    failing.fail_index = failing.alloc_index; // every allocation from here on fails
    const before = failing.allocations;

    const ctx = core.Context.root.withTrace(try traceContext("4bf92f3577b34da6a3ce929d0e0e4736", "00f067aa0ba902b7"));
    const inner: Config = .{ .host = "replica", .ports = .{ 1, 2 }, .state = .idle, .next = null };
    var config: Config = .{ .host = "pg", .ports = .{ 5432, 5433 }, .state = .{ .running = 3 }, .next = &inner };
    var user: User = .{ .id = 7, .password_hash = "x" };
    _ = .{ &config, &user };
    const digest = [_]u8{ 0xde, 0xad };
    const huge = &@as([5000]u8, @splat('y'));
    inline for (.{ json, text }) |logger| {
        const handle = logger.withContext(ctx).scoped("alloc.free");
        handle.info("nested", .{ .src = @src(), .config = config, .price = Price{ .cents = 5 }, .user = user, .digest = hex(&digest) });
        handle.warn(huge, .{ .config = config });
        logger.installStdLog();
        std_log.stdLogFn(.info, .alloc, "std {d} {s}", .{ 1, huge });
        uninstallStdLog();
    }
    try testing.expectEqual(before, failing.allocations);
}

test "std.log goes to the installed logger: its scope, its level and its text" {
    var c: Capture = undefined;
    try c.open(.{ .level = .debug });
    defer c.close();
    c.logger.installStdLog();
    std_log.stdLogFn(.info, .users, "user {d} created: {s}", .{ 42, "a\nb\xff" });
    std_log.stdLogFn(.err, .default, "disk {s}", .{"full"});
    std_log.stdLogFn(.debug, .confy, "loaded", .{});
    try c.expect(.json, &.{
        "\",\"level\":\"info\",\"message\":\"user 42 created: a\\nb\u{FFFD}\",\"scope\":\"users\"}",
        "\",\"level\":\"error\",\"message\":\"disk full\"}",
        "\",\"level\":\"debug\",\"message\":\"loaded\",\"scope\":\"confy\"}",
    });
}

test "std.log records follow the logger's levels, scope rules included" {
    var c: Capture = undefined;
    try c.open(.{ .format = .text, .scopes = &.{.{ .prefix = "noisy", .level = .err }} });
    defer c.close();
    c.logger.installStdLog();
    std_log.stdLogFn(.debug, .users, "hidden: below info", .{});
    std_log.stdLogFn(.warn, .noisy, "hidden: noisy logs from err", .{});
    std_log.stdLogFn(.warn, .users, "shown {d}", .{1});
    try c.expect(.text, &.{" WARN  [users] shown 1"});
}

test "a long std.log message is cut between characters" {
    var c: Capture = undefined;
    try c.open(.{ .max_record_bytes = 400 });
    defer c.close();
    c.logger.installStdLog();
    std_log.stdLogFn(.info, .default, "{s}", .{&@as([300]u8, @splat('m')) ++ "ééééééééééééééééééééééééééééééééééééééééééééééééééé"});
    const line = c.out.written();
    try testing.expect(line.len <= 400);
    try testing.expectStringEndsWith(line, "…\",\"truncated\":true}\n");
    try testing.expect(std.unicode.utf8ValidateSlice(line));
    try testing.expect(try std.json.validate(testing.allocator, line[0 .. line.len - 1]));
}

test "deinit and uninstallStdLog send std.log back to its default" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const first: Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &sink.writer } });
    const second: Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &sink.writer } });
    first.installStdLog();
    try testing.expect(std_log.installed() == first.engine);
    second.deinit(); // not the installed one: std.log stays with `first`
    try testing.expect(std_log.installed() == first.engine);
    uninstallStdLog();
    try testing.expect(std_log.installed() == null);
    first.installStdLog();
    first.deinit();
    try testing.expect(std_log.installed() == null);
}

/// A std.log argument that keeps its call inside the bridge until released.
const Gatekeeper = struct {
    entered: *std.atomic.Value(bool),
    released: *const std.atomic.Value(bool),

    pub fn format(g: Gatekeeper, w: *std.Io.Writer) std.Io.Writer.Error!void {
        g.entered.store(true, .seq_cst);
        while (!g.released.load(.seq_cst)) std.Thread.yield() catch {};
        try w.writeAll("released");
    }
};

fn logThroughBridge(g: Gatekeeper) void {
    std_log.stdLogFn(.debug, .bridge, "{f}", .{g});
}

fn callAndMark(comptime f: anytype, args: anytype, done: *std.atomic.Value(bool)) void {
    @call(.auto, f, args);
    done.store(true, .seq_cst);
}

fn deinitLogger(logger: Logger) void {
    logger.deinit();
}

test "deinit of a logger that std.log has moved away from still waits for the calls inside it" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const first: Logger = try .init(testing.allocator, testing.io, .{ .level = .debug, .output = .{ .writer = &sink.writer } });
    const second: Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &sink.writer } });
    defer second.deinit();
    var entered: std.atomic.Value(bool) = .init(false);
    var released: std.atomic.Value(bool) = .init(false);
    var done: std.atomic.Value(bool) = .init(false);
    first.installStdLog();
    const caller = try std.Thread.spawn(.{}, logThroughBridge, .{Gatekeeper{ .entered = &entered, .released = &released }});
    while (!entered.load(.seq_cst)) std.Thread.yield() catch {};
    second.installStdLog(); // std.log moves on; the call above is still inside `first`
    const ender = try std.Thread.spawn(.{}, callAndMark, .{ deinitLogger, .{first}, &done });
    try testing.io.sleep(.fromMilliseconds(20), .awake);
    const ended_early = done.load(.seq_cst);
    released.store(true, .seq_cst);
    caller.join();
    ender.join();
    try testing.expect(!ended_early);
    try testing.expect(done.load(.seq_cst));
}

test "removing the bridge does not wait for std.log calls that went to the default log" {
    var entered: std.atomic.Value(bool) = .init(false);
    var released: std.atomic.Value(bool) = .init(false);
    var done: std.atomic.Value(bool) = .init(false);
    uninstallStdLog();
    // Nothing is installed: this call goes to std.log.defaultLog (one line on stderr).
    const caller = try std.Thread.spawn(.{}, logThroughBridge, .{Gatekeeper{ .entered = &entered, .released = &released }});
    while (!entered.load(.seq_cst)) std.Thread.yield() catch {};
    const remover = try std.Thread.spawn(.{}, callAndMark, .{ uninstallStdLog, .{}, &done });
    var waited: u32 = 0;
    while (!done.load(.seq_cst) and waited < 1000) : (waited += 1) try testing.io.sleep(.fromMilliseconds(1), .awake);
    const returned = done.load(.seq_cst);
    released.store(true, .seq_cst);
    caller.join();
    remover.join();
    try testing.expect(returned);
}

test "the call-site mode is chosen per level" {
    var c: Capture = undefined;
    try c.open(.{ .level = .trace, .source = .{ .default = .none, .err = .full } });
    defer c.close();
    const here = @src();
    c.logger.info("no call site", .{ .src = here });
    c.logger.err("full call site", .{ .src = here });
    c.logger.err("none passed", .{});
    const line = std.fmt.comptimePrint("{d}", .{here.line});
    const column = std.fmt.comptimePrint("{d}", .{here.column});
    try c.expect(.json, &.{
        "\",\"level\":\"info\",\"message\":\"no call site\"}",
        "\",\"level\":\"error\",\"message\":\"full call site\",\"source\":{\"file\":\"Logger.zig\",\"line\":" ++ line ++ ",\"column\":" ++ column ++
            ",\"function\":\"" ++ here.fn_name ++ "\",\"module\":\"" ++ here.module ++ "\"}}",
        "\",\"level\":\"error\",\"message\":\"none passed\"}",
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
    try cut.open(.{ .max_record_bytes = 400 });
    defer cut.close();
    cut.logger.info(long_message, .{});
    cut.logger.info("short", .{});
    cut.logger.debug("filtered", .{});
    var s = cut.logger.stats();
    try testing.expectEqual(@as(u64, 2), s.accepted);
    try testing.expectEqual(@as(u64, 2), s.written);
    try testing.expectEqual(@as(u64, 1), s.truncated);

    var dropped: Capture = undefined;
    try dropped.open(.{ .max_record_bytes = 400, .oversize = .drop });
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

/// A writer that, for each budget in turn, takes that many bytes and then
/// fails once; after the last budget it takes everything.
const Gate = struct {
    budgets: []const usize,
    /// Bytes taken against `budgets[0]`.
    taken: usize = 0,
    sink: std.Io.Writer.Allocating,
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        // The logger writes one slice at a time.
        std.debug.assert(data.len == 1 and splat == 1);
        const gate: *Gate = @alignCast(@fieldParentPtr("writer", w));
        var bytes = data[0];
        if (gate.budgets.len > 0) {
            const budget = gate.budgets[0];
            if (gate.taken == budget) {
                gate.budgets = gate.budgets[1..];
                gate.taken = 0;
                return error.WriteFailed;
            }
            bytes = bytes[0..@min(bytes.len, budget - gate.taken)];
            gate.taken += bytes.len;
        }
        gate.sink.writer.writeAll(bytes) catch return error.WriteFailed;
        return bytes.len;
    }
};

test "after a torn line, a write that sends nothing keeps it open and one that sends only the newline closes it" {
    var gate: Gate = .{ .budgets = &.{ 10, 0, 1 }, .sink = .init(testing.allocator) };
    defer gate.sink.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &gate.writer } });
    defer logger.deinit();
    logger.info("first", .{}); // 10 bytes go out, then the write fails: the line is torn
    logger.info("second", .{}); // nothing goes out: the line stays torn
    logger.info("third", .{}); // only the '\n' that ends the torn line goes out
    logger.info("fourth", .{}); // written whole, on a line of its own
    var lines = std.mem.splitScalar(u8, gate.sink.written(), '\n');
    try testing.expectEqualStrings("{\"timestam", lines.next().?);
    try testing.expectStringEndsWith(lines.next().?, "\"message\":\"fourth\"}");
    try testing.expectEqualStrings("", lines.rest());
    const s = logger.stats();
    try testing.expectEqual(@as(u64, 1), s.written);
    try testing.expectEqual(@as(u64, 3), s.write_errors);
    try testing.expectEqual(@as(u64, 3), s.dropped.write_failed);
    try testing.expectEqual(@as(u64, 1), s.torn_lines);
}

test "past 256 scope names a handle logs without a scope, at the global level" {
    var c: Capture = undefined;
    try c.open(.{ .scopes = &.{.{ .prefix = "late", .level = .debug }} });
    defer c.close();
    var buf: [8]u8 = undefined;
    for (0..scopes.max_scopes) |i| _ = c.logger.scoped(try std.fmt.bufPrint(&buf, "s{d}", .{i}));
    const late = c.logger.scoped("late");
    late.debug("hidden: the late handle follows the global level", .{});
    late.info("m", .{});
    try c.expect(.json, &.{"\",\"level\":\"info\",\"message\":\"m\"}"});
    try testing.expectEqual(@as(u64, 1), c.logger.stats().scopes_overflow);
}

test "a text scope that could pass for a field is quoted" {
    var c: Capture = undefined;
    try c.open(.{ .format = .text });
    defer c.close();
    c.logger.scoped("a] fake=1 [b").info("m", .{});
    c.logger.scoped("db.pool").info("m", .{});
    try c.expect(.text, &.{
        " INFO  [\"a] fake=1 [b\"] m",
        " INFO  [db.pool] m",
    });
}

test "a write that fails mid-line costs that line only" {
    var gate: Gate = .{ .budgets = &.{10}, .sink = .init(testing.allocator) };
    defer gate.sink.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &gate.writer } });
    defer logger.deinit();
    logger.info("first", .{});
    logger.info("second", .{});
    logger.info("third", .{});
    var lines = std.mem.splitScalar(u8, gate.sink.written(), '\n');
    try testing.expectEqualStrings("{\"timestam", lines.next().?); // the 10 bytes that went out
    try testing.expectStringEndsWith(lines.next().?, "\"message\":\"second\"}");
    try testing.expectStringEndsWith(lines.next().?, "\"message\":\"third\"}");
    try testing.expectEqualStrings("", lines.rest());
    const s = logger.stats();
    try testing.expectEqual(@as(u64, 2), s.written);
    try testing.expectEqual(@as(u64, 1), s.write_errors);
    try testing.expectEqual(@as(u64, 1), s.dropped.write_failed);
    try testing.expectEqual(@as(u64, 1), s.torn_lines);
}

test "a closed stdout is noted on stderr once; the records after it are dropped" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // the test needs POSIX pipes
    const io = testing.io;
    const stdout_pipe = try std.Io.Threaded.pipe2(.{});
    const stderr_pipe = try std.Io.Threaded.pipe2(.{});
    const stdout_write = pipeEnd(stdout_pipe[1]);
    const stderr_read = pipeEnd(stderr_pipe[0]);
    const stderr_write = pipeEnd(stderr_pipe[1]);
    defer stdout_write.close(io);
    defer stderr_read.close(io);
    pipeEnd(stdout_pipe[0]).close(io); // nobody reads stdout: writes fail with BrokenPipe

    const logger: Logger = try .init(testing.allocator, io, .{});
    defer logger.deinit();
    logger.engine.stdout = stdout_write;
    logger.engine.stderr = stderr_write;
    logger.info("first", .{});
    logger.info("second", .{});
    stderr_write.close(io);

    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("zefir.log: stdout is closed (BrokenPipe); dropping the records that follow\n", try readToEnd(stderr_read, io, &buf));
    const s = logger.stats();
    try testing.expectEqual(@as(u64, 2), s.accepted);
    try testing.expectEqual(@as(u64, 0), s.written);
    try testing.expectEqual(@as(u64, 1), s.write_errors);
    try testing.expectEqual(@as(u64, 2), s.dropped.write_failed);
}

test "a stdout not open for writing is noted on stderr once" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // the test needs POSIX pipes
    const io = testing.io;
    const stdout_pipe = try std.Io.Threaded.pipe2(.{});
    const stderr_pipe = try std.Io.Threaded.pipe2(.{});
    const stdout_read = pipeEnd(stdout_pipe[0]); // writing to the read end fails with EBADF
    const stderr_read = pipeEnd(stderr_pipe[0]);
    const stderr_write = pipeEnd(stderr_pipe[1]);
    defer stdout_read.close(io);
    defer pipeEnd(stdout_pipe[1]).close(io);
    defer stderr_read.close(io);

    const logger: Logger = try .init(testing.allocator, io, .{});
    defer logger.deinit();
    logger.engine.stdout = stdout_read;
    logger.engine.stderr = stderr_write;
    logger.info("first", .{});
    logger.info("second", .{});
    stderr_write.close(io);

    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("zefir.log: stdout is not open for writing (NotOpenForWriting); dropping the records that follow\n", try readToEnd(stderr_read, io, &buf));
    const s = logger.stats();
    try testing.expectEqual(@as(u64, 0), s.written);
    try testing.expectEqual(@as(u64, 1), s.write_errors);
    try testing.expectEqual(@as(u64, 2), s.dropped.write_failed);
}

test "a full nonblocking stdout drops records and never glues two of them together" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // the test needs POSIX pipes
    const io = testing.io;
    const fds = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true });
    const read_end: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = true } };
    const write_end: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = true } };
    defer read_end.close(io);
    defer write_end.close(io);

    // Fill the pipe, then make room for one page: a long record fits only in part.
    var filled: usize = 0;
    for ([_]usize{ 4096, 1 }) |chunk| {
        const filler: [4096]u8 = @splat('f');
        while (true) filled += write_end.writeStreaming(io, &.{}, &.{filler[0..chunk]}, 1) catch |e| switch (e) {
            error.WouldBlock => break,
            else => return e,
        };
    }
    var all: std.Io.Writer.Allocating = .init(testing.allocator);
    defer all.deinit();
    try readAvailable(read_end, io, &all, 4096);

    const logger: Logger = try .init(testing.allocator, io, .{ .max_record_bytes = 16384 });
    defer logger.deinit();
    logger.engine.stdout = write_end;
    const data: [8000]u8 = @splat('d');
    logger.info("long", .{ .data = @as([]const u8, &data) }); // goes out in part, or not at all
    logger.info("short", .{}); // the pipe may be full again
    try readAvailable(read_end, io, &all, std.math.maxInt(usize));
    logger.info("last", .{});
    try readAvailable(read_end, io, &all, std.math.maxInt(usize));

    const out = all.written()[filled..];
    try testing.expectStringEndsWith(out, "\"message\":\"last\"}\n");
    const start = std.mem.findLast(u8, out, "{\"timestamp\"").?;
    try testing.expect(start == 0 or out[start - 1] == '\n'); // a torn line before it was ended
    try testing.expect(try std.json.validate(testing.allocator, out[start .. out.len - 1]));
    const s = logger.stats();
    try testing.expectEqual(@as(u64, 3), s.accepted);
    try testing.expectEqual(s.accepted, s.written + s.dropped.write_failed);
    try testing.expect(s.write_errors >= 1);
}

fn pipeEnd(fd: std.posix.fd_t) std.Io.File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Reads `file` until its write end is closed.
fn readToEnd(file: std.Io.File, io: std.Io, buf: []u8) ![]u8 {
    var len: usize = 0;
    while (true) {
        len += file.readStreaming(io, &.{buf[len..]}) catch |e| switch (e) {
            error.EndOfStream => return buf[0..len],
            else => return e,
        };
    }
}

/// Reads up to `limit` bytes that a nonblocking pipe holds right now.
fn readAvailable(file: std.Io.File, io: std.Io, out: *std.Io.Writer.Allocating, limit: usize) !void {
    var buf: [4096]u8 = undefined;
    var left = limit;
    while (left > 0) {
        const n = file.readStreaming(io, &.{buf[0..@min(buf.len, left)]}) catch |e| switch (e) {
            error.WouldBlock => return,
            else => return e,
        };
        try out.writer.writeAll(buf[0..n]);
        left -= n;
    }
}
