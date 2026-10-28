//! A logger handle: the engine, a scope and the trace ids from
//! `withContext`, copied by value and shared freely between threads.
//! `init` creates the engine every handle points to; `scoped` and
//! `withContext` derive handles.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const Engine = @import("Engine.zig");
const encode = @import("encode.zig");
const hooks = @import("hooks.zig");
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

/// Creates the engine: logging allocates nothing after this, and only
/// `subscribe` allocates again, for its subscriber's queue. The options
/// may be freed once `init` returns; the logger copies what it keeps. Call
/// `deinit` once, after the last record, on any handle of this logger: all
/// of them become invalid. Use one logger per process for stdout: two
/// loggers on one stdout do not coordinate their writes.
///
/// Records read the clock through `io` and, in sync mode, are written
/// through it, so log only from threads or tasks that `io` serves. Pass
/// `init.io`, the `io` that `main(init: std.process.Init)` gets: any thread
/// may log through it, `main`, the tasks of your zio runtime and threads of
/// your own, so the logger can start before the runtime and stop after it.
pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: options.Options) InitError!Logger {
    const engine = try Engine.create(gpa, io, opts);
    return .{ .engine = engine, .scope = &engine.scope_table.root };
}

/// Frees the logger. Without a `shutdown` first it runs one with no time
/// limit: the queue is written and the subscribers handle theirs. After a
/// `shutdown` that timed out it drops what is left and waits only for the
/// write and the handler calls in progress; no summary record follows
/// them. A write or a handler that never returns keeps it waiting too: to
/// exit on time, call `shutdown` with a deadline, and when it times out,
/// let the process exit without `deinit`. Either way it notes on stderr
/// the error records the logger dropped that no summary in the log
/// reported. The std.log bridge stays until the logger's threads have
/// exited, so what handlers log through std.log meanwhile still reaches
/// the logger; while it waits, std.log calls from other threads are
/// refused, as after `shutdown`.
pub fn deinit(self: Logger) void {
    self.engine.destroy();
}

/// Queued mode: waits until every record logged before the call is
/// written, or dropped by a failed write. It does not wait for the summary
/// record of the error records the logger dropped: the writer thread writes
/// it as soon as it can, and `shutdown` reports every one. When `timeout`
/// passes first it returns `error.Timeout`, and `stats().pending` tells how
/// many records are not written yet. Sync mode writes each record before
/// the call that logs it returns: there is nothing to wait for. Blocks the
/// OS thread.
/// Not from a handler or the writer thread, in either mode: that panics in
/// safe builds and returns `error.Timeout` otherwise.
pub fn flush(self: Logger, timeout: std.Io.Timeout) error{Timeout}!void {
    return self.engine.flush(timeout);
}

/// Stops the logger: records logged after it starts are refused and
/// counted in `stats().dropped.closed` (error records in
/// `stats().dropped.err`, reported like every error record the logger
/// drops: by the summary record, or on stderr once no writer thread is
/// left); only what the handlers
/// log while it waits for them still goes out. It waits until the
/// subscribers have handled their queues, then, in queued mode, until the
/// queue is written, and stops the logger's threads. When `timeout`
/// passes first it returns `error.Timeout`: `stats().pending` and
/// `stats().alert_pending` tell how many records are left, another
/// `shutdown` may wait for them again, and `deinit` drops them. `core.Deadline.toTimeout()` gives a
/// timeout. Stop the application's own threads before; a record that
/// another thread is writing at that moment still goes out. Blocks the OS
/// thread. Not from a handler or the writer thread: that panics in safe
/// builds and returns `error.Timeout` otherwise.
pub fn shutdown(self: Logger, timeout: std.Io.Timeout) error{Timeout}!void {
    return self.engine.shutdown(timeout);
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
    self.engine.emit(level, self.scope, self.traceHex(&hex), message, fields);
}

/// Adds a subscriber: from now on it gets a copy of each record of its
/// levels (and scope) on a thread of its own, through a queue of its own,
/// so a slow handler never holds up a caller. A record goes to the
/// subscribers before the output, so they get an error record even when
/// the queue refuses it or stdout is closed; a record too long for
/// `.oversize = .drop` reaches none. A logger takes 8 subscribers in its
/// life; `unsubscribe` gives no slot back. It gets only records that pass
/// the level filter. Its queue takes `capacity` slots of
/// `max_record_bytes` + 112 bytes rounded up to 128 (4224 bytes with
/// 4 KiB records), until `deinit`.
pub fn subscribe(self: Logger, subscription: hooks.Subscription) hooks.SubscribeError!hooks.SubscriptionId {
    return self.engine.subscribe(subscription);
}

/// Removes a subscriber and waits until its thread has handed the records
/// in its queue to the handler and exited: once it returns, the handler is
/// never called again, so its context may go. While the logger runs that
/// wait has no time limit; once `shutdown` has begun, only the call in
/// hand is waited for. Blocks the OS thread. Call it before `deinit`; a
/// second call returns once the first is done. Not from a handler or the
/// writer thread: that panics in safe builds.
pub fn unsubscribe(self: Logger, id: hooks.SubscriptionId) void {
    self.engine.unsubscribe(id);
}

/// Adds an interceptor for the logger's life: none can be removed, so its
/// context, and whatever its filter reads, must outlive the logger. A
/// logger takes 8. It sees every record that passes the level filter and
/// is encoded (not one too long for `.oversize = .drop`), and drops it by
/// returning false.
pub fn use(self: Logger, interceptor: hooks.Interceptor) error{TooManyInterceptors}!void {
    return self.engine.use(interceptor);
}

/// Writes an error record to stderr before it returns, past the queue:
/// for what must be seen even when the regular output is stuck, e.g. right
/// before the process gives up. It takes the handle's scope and trace ids
/// and the logger's format, never allocates, and works after `shutdown`
/// too. At most 100 such records go out at once and 100 per second after
/// that; the rest are left out and counted in
/// `stats().emergency_suppressed`, and the next one written tells how many
/// with `"suppressed":N`. So is an emergency record logged while another
/// one is being written on the same thread (by a field's `format`). A
/// record that fits whole is never cut to make room for that count: the
/// next one tells it then. Not from a signal handler: it takes locks that
/// the interrupted thread may hold.
pub fn emergency(self: Logger, comptime message: []const u8, fields: anytype) void {
    comptime field_checks.check(@TypeOf(fields));
    var hex: encode.TraceHex = undefined;
    self.engine.emergency(self.scope, self.traceHex(&hex), message, fields);
}

fn traceHex(self: Logger, hex: *encode.TraceHex) ?*const encode.TraceHex {
    const ids = self.ids orelse return null;
    hex.* = .{ .trace_id = ids.trace_id.toHex(), .span_id = ids.span_id.toHex() };
    return hex;
}

/// Whether a record at `level` would be written. Field values are computed
/// even when the level is off, so check this before costly ones.
pub fn enabled(self: Logger, level: Level) bool {
    return @backingInt(level) >= @backingInt(self.scope.level.load(.monotonic));
}

/// A handle that writes `name` as its records' scope, in place of this
/// handle's scope. The name is copied, so it need not outlive the handle.
/// It is kept as records write it, escaped, and cut between characters to
/// 128 bytes (`stats().scope_names_truncated` counts each such call):
/// names that agree in those 128 bytes are one scope. The first call with
/// a new name takes a short lock; later calls only search. Past 256 names
/// a handle logs without a scope, at the global level, and
/// `stats().scopes_overflow` counts each such call.
pub fn scoped(self: Logger, name: []const u8) Logger {
    return .{ .engine = self.engine, .scope = self.engine.scope_table.find(name), .ids = self.ids };
}

/// A handle whose records carry the trace and span ids of `ctx`, in place
/// of this handle's; a context without a trace gives a handle without them.
/// The ids are copied, so the handle may outlive `ctx`. A deadline or a
/// cancellation in `ctx` does not affect logging. This is the way to log
/// a context: a `core.Context` among the fields is a compile error.
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
/// bridge once the logger's threads have exited, `zefir.log.uninstallStdLog`
/// does it earlier; both wait for the std.log calls that may still be
/// inside this logger.
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
    var first_live = true;
    defer if (first_live) first.deinit();
    const second: Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &sink.writer } });
    var second_live = true;
    defer if (second_live) second.deinit();
    first.installStdLog();
    try testing.expect(std_log.installed() == first.engine);
    second.deinit(); // not the installed one: std.log stays with `first`
    second_live = false;
    try testing.expect(std_log.installed() == first.engine);
    uninstallStdLog();
    try testing.expect(std_log.installed() == null);
    first.installStdLog();
    first.deinit();
    first_live = false;
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
    var live = true; // until `ender` runs its deinit
    defer if (live) first.deinit();
    const second: Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &sink.writer } });
    defer second.deinit();
    var entered: std.atomic.Value(bool) = .init(false);
    var released: std.atomic.Value(bool) = .init(false);
    var done: std.atomic.Value(bool) = .init(false);
    var ended_early = false;
    first.installStdLog();
    {
        const caller = try std.Thread.spawn(.{}, logThroughBridge, .{Gatekeeper{ .entered = &entered, .released = &released }});
        defer caller.join();
        var ender: ?std.Thread = null;
        defer if (ender) |thread| thread.join();
        defer released.store(true, .seq_cst);
        while (!entered.load(.seq_cst)) std.Thread.yield() catch {};
        second.installStdLog(); // std.log moves on; the call above is still inside `first`
        ender = try std.Thread.spawn(.{}, callAndMark, .{ deinitLogger, .{first}, &done });
        live = false;
        try testing.io.sleep(.fromMilliseconds(20), .awake);
        ended_early = done.load(.seq_cst);
    }
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
    defer caller.join();
    var remover: ?std.Thread = null;
    defer if (remover) |thread| thread.join();
    defer released.store(true, .seq_cst);
    while (!entered.load(.seq_cst)) std.Thread.yield() catch {};
    remover = try std.Thread.spawn(.{}, callAndMark, .{ uninstallStdLog, .{}, &done });
    var waited: u32 = 0;
    while (!done.load(.seq_cst) and waited < 1000) : (waited += 1) try testing.io.sleep(.fromMilliseconds(1), .awake);
    try testing.expect(done.load(.seq_cst));
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
    {
        var threads: [producers + 1]std.Thread = undefined;
        var spawned: usize = 0;
        defer for (threads[0..spawned]) |thread| thread.join();
        for (threads[0..producers], 0..) |*thread, producer| {
            thread.* = try std.Thread.spawn(.{}, produce, .{ logger, producer, per_producer });
            spawned += 1;
        }
        threads[producers] = try std.Thread.spawn(.{}, toggleLevels, .{logger});
        spawned += 1;
    }

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

test "past 256 scope names a handle logs without a scope, at the global level, and each lookup counts" {
    var c: Capture = undefined;
    try c.open(.{ .scopes = &.{.{ .prefix = "late", .level = .debug }} });
    defer c.close();
    var buf: [8]u8 = undefined;
    for (0..scopes.max_scopes) |i| _ = c.logger.scoped(try std.fmt.bufPrint(&buf, "s{d}", .{i}));
    const late = c.logger.scoped("late");
    late.debug("hidden: the late handle follows the global level", .{});
    late.info("m", .{});
    // The table keeps no names past it, so every lookup of one counts:
    // each `scoped` call, and each std.log record, even one below the level.
    _ = c.logger.scoped("late");
    c.logger.installStdLog();
    std_log.stdLogFn(.debug, .late, "hidden: std.log follows the global level too", .{});
    try c.expect(.json, &.{"\",\"level\":\"info\",\"message\":\"m\"}"});
    try testing.expectEqual(@as(u64, 3), c.logger.stats().scopes_overflow);
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

/// Fills a nonblocking pipe until a write would block; returns how many
/// bytes it took.
fn fillPipe(write_end: std.Io.File, io: std.Io) !usize {
    var filled: usize = 0;
    for ([_]usize{ 4096, 1 }) |chunk| {
        const filler: [4096]u8 = @splat('f');
        while (true) filled += write_end.writeStreaming(io, &.{}, &.{filler[0..chunk]}, 1) catch |e| switch (e) {
            error.WouldBlock => break,
            else => return e,
        };
    }
    return filled;
}

/// Waits, at most five seconds, until the writer thread has written or
/// dropped `count` records.
fn waitProcessed(logger: Logger, count: u64) !void {
    for (0..5000) |_| {
        const s = logger.stats();
        if (s.written + s.dropped.write_failed >= count) return;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TestTimedOut;
}

/// A writer that remembers the thread that wrote to it last.
const ThreadSink = struct {
    thread: std.atomic.Value(std.Thread.Id) = .init(0),
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const sink: *ThreadSink = @alignCast(@fieldParentPtr("writer", w));
        sink.thread.store(std.Thread.getCurrentId(), .seq_cst);
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| n += bytes.len;
        return n + data[data.len - 1].len * splat;
    }
};

/// A writer that holds the writer thread inside its first write until
/// `open` is set, then keeps everything it is given.
const Lock = struct {
    entered: std.atomic.Value(bool) = .init(false),
    open: std.atomic.Value(bool) = .init(false),
    sink: std.Io.Writer.Allocating,
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const lock: *Lock = @alignCast(@fieldParentPtr("writer", w));
        lock.entered.store(true, .seq_cst);
        while (!lock.open.load(.seq_cst)) std.Thread.yield() catch {};
        std.debug.assert(splat == 1);
        for (data) |bytes| lock.sink.writer.writeAll(bytes) catch return error.WriteFailed;
        var n: usize = 0;
        for (data) |bytes| n += bytes.len;
        return n;
    }

    fn waitEntered(lock: *Lock) void {
        while (!lock.entered.load(.seq_cst)) std.Thread.yield() catch {};
    }

    /// Records written so far: one line each.
    fn lines(lock: *Lock) usize {
        return std.mem.count(u8, lock.sink.written(), "\n");
    }
};

test "queued, drop_new: a full queue drops the record and counts it; the caller never waits" {
    var lock: Lock = .{ .sink = .init(testing.allocator) };
    defer lock.sink.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{
        .mode = .{ .queued = .{ .capacity = 4, .batch_size = 1 } },
        .output = .{ .writer = &lock.writer },
    });
    var live = true;
    defer if (live) {
        lock.open.store(true, .seq_cst);
        logger.deinit();
    };
    logger.info("held", .{}); // the writer takes it and waits inside the write
    lock.waitEntered();
    for (0..5) |i| logger.info("queued", .{ .i = i }); // four fit, the fifth does not
    const s = logger.stats();
    try testing.expectEqual(@as(u64, 1), s.dropped.queue_full);
    try testing.expectEqual(@as(u64, 4), s.queue_depth);
    try testing.expectEqual(@as(u64, 4), s.queue_capacity);
    lock.open.store(true, .seq_cst);
    try waitProcessed(logger, 5);
    logger.deinit();
    live = false;
    try testing.expectEqual(@as(usize, 5), lock.lines());
}

fn logBlocking(logger: Logger, done: *std.atomic.Value(bool)) void {
    logger.info("waited", .{});
    done.store(true, .seq_cst);
}

test "queued, block: a full queue makes the caller wait for room; nothing is lost" {
    var lock: Lock = .{ .sink = .init(testing.allocator) };
    defer lock.sink.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{
        .mode = .{ .queued = .{ .capacity = 4, .batch_size = 1, .overflow = .block } },
        .output = .{ .writer = &lock.writer },
    });
    var live = true;
    defer if (live) {
        lock.open.store(true, .seq_cst);
        logger.deinit();
    };
    logger.info("held", .{});
    lock.waitEntered();
    for (0..4) |i| logger.info("queued", .{ .i = i });
    var done: std.atomic.Value(bool) = .init(false);
    var waited = false;
    {
        const producer = try std.Thread.spawn(.{}, logBlocking, .{ logger, &done });
        defer producer.join();
        defer lock.open.store(true, .seq_cst);
        try testing.io.sleep(.fromMilliseconds(20), .awake);
        waited = !done.load(.seq_cst);
    }
    try waitProcessed(logger, 6);
    const s = logger.stats();
    logger.deinit();
    live = false;
    try testing.expect(waited);
    try testing.expectEqual(@as(u64, 0), s.dropped.queue_full);
    try testing.expectEqual(@as(usize, 6), lock.lines());
}

test "queued: flush waits until every record logged before it is written" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .mode = .{ .queued = .{ .capacity = 256 } }, .output = .{ .writer = &out.writer } });
    defer logger.deinit();
    for (0..100) |i| logger.info("tick", .{ .i = i });
    try logger.flush(.none);
    try testing.expectEqual(@as(usize, 100), std.mem.count(u8, out.written(), "\n"));
    try testing.expectEqual(@as(u64, 0), logger.stats().pending);
}

test "queued: flush with a deadline gives up while the writer is held" {
    var lock: Lock = .{ .sink = .init(testing.allocator) };
    defer lock.sink.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .mode = .{ .queued = .{} }, .output = .{ .writer = &lock.writer } });
    defer logger.deinit();
    defer lock.open.store(true, .seq_cst);
    logger.info("held", .{});
    lock.waitEntered();
    try testing.expectError(error.Timeout, logger.flush(.{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }));
    lock.open.store(true, .seq_cst);
    try logger.flush(.none);
    try testing.expectEqual(@as(usize, 1), lock.lines());
}

test "queued: a producer stopped between reserving and publishing holds flush back; nothing is lost" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .mode = .{ .queued = .{} }, .output = .{ .writer = &out.writer } });
    defer logger.deinit();
    const q = &logger.engine.queue.?;
    const stopped = try q.reserve(); // a producer stops right after reserving
    var published = false;
    defer if (!published) q.publish(stopped, "{\"stopped\":true}\n");
    logger.info("after", .{});
    try testing.expectError(error.Timeout, logger.flush(.{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }));
    try testing.expectEqual(@as(u64, 2), logger.stats().pending);
    q.publish(stopped, "{\"stopped\":true}\n"); // queued records keep their '\n'
    published = true;
    try logger.flush(.none);
    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    try testing.expectEqualStrings("{\"stopped\":true}", lines.next().?);
    try testing.expectStringEndsWith(lines.next().?, "\"message\":\"after\"}");
    try testing.expectEqualStrings("", lines.rest());
}

/// Waits, at most five seconds, until the writer thread sleeps.
fn waitWriterAsleep(logger: Logger) !void {
    const q = &logger.engine.queue.?;
    for (0..5000) |_| {
        if (q.consumer_sleeping.load(.seq_cst) == 1) return;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TestWriterNeverSlept;
}

test "queued: while a producer holds a reserved slot the writer thread sleeps, and the publish wakes it" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .mode = .{ .queued = .{} }, .output = .{ .writer = &out.writer } });
    defer logger.deinit();
    const q = &logger.engine.queue.?;
    const stopped = try q.reserve();
    const asleep = waitWriterAsleep(logger);
    q.publish(stopped, "{\"stopped\":true}\n");
    try asleep;
    // Well within the writer's one-second recheck: the publish woke it.
    try logger.flush(.{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } });
    try testing.expectEqualStrings("{\"stopped\":true}\n", out.written());
}

test "queued: deinit after a timed-out shutdown wakes a writer thread that waits for a stopped producer" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .mode = .{ .queued = .{} }, .output = .{ .writer = &out.writer } });
    var live = true;
    defer if (live) logger.deinit();
    _ = try logger.engine.queue.?.reserve(); // its producer never goes on
    const timed_out = logger.shutdown(.{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } });
    const asleep = waitWriterAsleep(logger);
    const start = std.Io.Clock.awake.now(testing.io);
    logger.deinit();
    live = false;
    const took = start.durationTo(std.Io.Clock.awake.now(testing.io));
    try testing.expectError(error.Timeout, timed_out);
    try asleep;
    try testing.expect(took.nanoseconds < 500 * std.time.ns_per_ms); // not the one-second recheck
}

/// Waits, at most five seconds, until `count` threads wait on `waiters`.
fn waitWaiters(waiters: *const std.atomic.Value(u32), count: u32) !void {
    for (0..5000) |_| {
        if (waiters.load(.seq_cst) >= count) return;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TestNobodyWaited;
}

fn logThenCheckCancel(logger: Logger) std.Io.Cancelable!void {
    logger.info("waited", .{});
    return testing.io.checkCancel();
}

test "queued, block: a caller's cancel request outlives its wait for room" {
    var lock: Lock = .{ .sink = .init(testing.allocator) };
    defer lock.sink.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{
        .mode = .{ .queued = .{ .capacity = 4, .batch_size = 1, .overflow = .block } },
        .output = .{ .writer = &lock.writer },
    });
    defer logger.deinit();
    defer lock.open.store(true, .seq_cst);
    logger.info("held", .{});
    lock.waitEntered();
    for (0..4) |i| logger.info("queued", .{ .i = i });
    var task = try testing.io.concurrent(logThenCheckCancel, .{logger});
    defer {
        lock.open.store(true, .seq_cst); // the task waits for room until then
        task.cancel(testing.io) catch {};
    }
    const waited = waitWaiters(&logger.engine.queue.?.space_waiters, 1);
    const opener = try std.Thread.spawn(.{}, openLater, .{&lock});
    defer opener.join();
    try testing.expectError(error.Canceled, task.cancel(testing.io));
    try waited;
}

fn flushThenCheckCancel(logger: Logger) std.Io.Cancelable!void {
    logger.flush(.none) catch {};
    return testing.io.checkCancel();
}

test "queued: a caller's cancel request outlives a flush's wait" {
    var lock: Lock = .{ .sink = .init(testing.allocator) };
    defer lock.sink.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .mode = .{ .queued = .{} }, .output = .{ .writer = &lock.writer } });
    defer logger.deinit();
    defer lock.open.store(true, .seq_cst);
    logger.info("held", .{});
    lock.waitEntered();
    var task = try testing.io.concurrent(flushThenCheckCancel, .{logger});
    defer {
        lock.open.store(true, .seq_cst); // the task's flush waits until then
        task.cancel(testing.io) catch {};
    }
    const waited = waitWaiters(&logger.engine.progress_waiters, 1);
    const opener = try std.Thread.spawn(.{}, openLater, .{&lock});
    defer opener.join();
    try testing.expectError(error.Canceled, task.cancel(testing.io));
    try waited;
}

/// Waits until the cancel request lands, then puts it back: it is pending,
/// for certain, when the log call runs.
fn logWhileCancelPending(logger: Logger) std.Io.Cancelable!void {
    while (true) {
        testing.io.checkCancel() catch break;
        std.atomic.spinLoopHint();
    }
    testing.io.recancel();
    logger.info("Logged while a cancel request is pending", .{});
    return testing.io.checkCancel();
}

/// A writer that writes through the caller's Io, as a `File.Writer` does:
/// each write is a cancelation point.
const CancelPoint = struct {
    sink: std.Io.Writer.Allocating,
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        // The logger writes one slice at a time.
        std.debug.assert(data.len == 1 and splat == 1);
        const point: *CancelPoint = @alignCast(@fieldParentPtr("writer", w));
        testing.io.checkCancel() catch return error.WriteFailed;
        point.sink.writer.writeAll(data[0]) catch return error.WriteFailed;
        return data[0].len;
    }
};

test "sync: a log call writes its record to a writer that is a cancelation point while a cancel request is pending, and keeps the request" {
    var point: CancelPoint = .{ .sink = .init(testing.allocator) };
    defer point.sink.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &point.writer } });
    defer logger.deinit();
    var task = try testing.io.concurrent(logWhileCancelPending, .{logger});
    try testing.expectError(error.Canceled, task.cancel(testing.io));
    try testing.expectStringEndsWith(point.sink.written(), "\"message\":\"Logged while a cancel request is pending\"}\n");
    try testing.expectEqual(@as(u64, 1), logger.stats().written);
}

test "sync: a log call writes its record to stdout while a cancel request is pending, and keeps the request" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // the test needs POSIX pipes
    const io = testing.io;
    const fds = try std.Io.Threaded.pipe2(.{});
    const read_end = pipeEnd(fds[0]);
    defer read_end.close(io);
    {
        const write_end = pipeEnd(fds[1]);
        defer write_end.close(io); // after deinit, so the read below ends
        const logger: Logger = try .init(testing.allocator, io, .{});
        defer logger.deinit();
        logger.engine.stdout = write_end;
        var task = try testing.io.concurrent(logWhileCancelPending, .{logger});
        try testing.expectError(error.Canceled, task.cancel(io));
        try testing.expectEqual(@as(u64, 1), logger.stats().written);
    }
    var buf: [256]u8 = undefined;
    try testing.expectStringEndsWith(try readToEnd(read_end, io, &buf), "\"message\":\"Logged while a cancel request is pending\"}\n");
}

/// Waits until the cancel request lands, then puts it back: it is pending,
/// for certain, when `emergency` runs.
fn emergencyThenCheckCancel(logger: Logger) std.Io.Cancelable!void {
    while (true) {
        testing.io.checkCancel() catch break;
        std.atomic.spinLoopHint();
    }
    testing.io.recancel();
    logger.emergency("Going down", .{});
    return testing.io.checkCancel();
}

test "emergency writes its record while a cancel request is pending, and keeps the request" {
    var stderr: StderrFile = try .open();
    defer stderr.close();
    const logger: Logger = try .init(testing.allocator, testing.io, .{});
    var live = true;
    defer if (live) logger.deinit();
    logger.engine.stderr = stderr.file;
    var task = try testing.io.concurrent(emergencyThenCheckCancel, .{logger});
    const result = task.cancel(testing.io);
    const s = logger.stats();
    logger.deinit();
    live = false;
    var buf: [256]u8 = undefined;
    try testing.expectStringEndsWith(try stderr.read(&buf), "\"message\":\"Going down\"}\n");
    try testing.expectError(error.Canceled, result);
    try testing.expectEqual(@as(u64, 1), s.emergency_written);
}

/// A buffered writer whose first flush fails and loses what it held, as a
/// writer whose sink broke for a moment would; later ones keep everything.
const FlakyFlush = struct {
    broke: bool = false,
    sink: std.Io.Writer.Allocating,
    buffer: [1024]u8 = undefined,
    writer: std.Io.Writer = undefined,

    fn open(f: *FlakyFlush) void {
        f.writer = .{ .buffer = &f.buffer, .vtable = &.{ .drain = drain } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const f: *FlakyFlush = @alignCast(@fieldParentPtr("writer", w));
        if (!f.broke) {
            f.broke = true;
            w.end = 0;
            return error.WriteFailed;
        }
        f.sink.writer.writeAll(w.buffered()) catch return error.WriteFailed;
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            f.sink.writer.writeAll(bytes) catch return error.WriteFailed;
            n += bytes.len;
        }
        for (0..splat) |_| f.sink.writer.writeAll(data[data.len - 1]) catch return error.WriteFailed;
        return n + data[data.len - 1].len * splat;
    }
};

fn expectFailedFlushTorn(mode: options.Mode) !void {
    var flaky: FlakyFlush = .{ .sink = .init(testing.allocator) };
    defer flaky.sink.deinit();
    flaky.open();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .mode = mode, .output = .{ .writer = &flaky.writer } });
    var live = true;
    defer if (live) logger.deinit();
    logger.info("first", .{});
    try logger.flush(.none);
    logger.info("second", .{});
    try logger.flush(.none);
    const s = logger.stats();
    logger.deinit();
    live = false;
    const out = flaky.sink.written();
    // How much of the first record went out is unknown: its line is ended
    // before the next record.
    try testing.expect(std.mem.startsWith(u8, out, "\n{"));
    try testing.expectStringEndsWith(out, "\"message\":\"second\"}\n");
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\n"));
    try testing.expectEqual(@as(u64, 1), s.written);
    try testing.expectEqual(@as(u64, 1), s.dropped.write_failed);
    try testing.expectEqual(@as(u64, 1), s.torn_lines);
    try testing.expectEqual(@as(u64, 1), s.write_errors);
}

test "a writer whose flush fails: the record counts as dropped and its line as torn" {
    try expectFailedFlushTorn(.sync);
    try expectFailedFlushTorn(.{ .queued = .{} });
}

/// A buffered writer over a slow sink: each drain sends what the buffer
/// held, then takes as much of the new bytes into the buffer as fits, and
/// those count as written. Its third drain fails and loses what it held.
const SlowSink = struct {
    drains: u32 = 0,
    sink: std.Io.Writer.Allocating,
    buffer: [250]u8 = undefined,
    writer: std.Io.Writer = undefined,

    fn open(s: *SlowSink) void {
        s.writer = .{ .buffer = &s.buffer, .vtable = &.{ .drain = drain } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        // The logger writes one slice at a time.
        std.debug.assert(data.len == 1 and splat == 1);
        const s: *SlowSink = @alignCast(@fieldParentPtr("writer", w));
        s.drains += 1;
        if (s.drains == 3) {
            w.end = 0;
            return error.WriteFailed;
        }
        s.sink.writer.writeAll(w.buffered()) catch return error.WriteFailed;
        const taken = @min(data[0].len, w.buffer.len);
        @memcpy(w.buffer[0..taken], data[0][0..taken]);
        w.end = taken;
        return taken;
    }
};

test "queued: a buffered writer whose write fails mid-batch: the batch counts as dropped and its line as torn" {
    var slow: SlowSink = .{ .sink = .init(testing.allocator) };
    defer slow.sink.deinit();
    slow.open();
    const logger: Logger = try .init(testing.allocator, testing.io, .{
        .format = .text,
        .mode = .{ .queued = .{ .capacity = 64, .batch_size = 64 } },
        .output = .{ .writer = &slow.writer },
    });
    defer logger.deinit();
    // Seven 100-byte lines in one batch: a slot reserved first holds the
    // writer thread back until all of them are in.
    var lines: [7][100]u8 = undefined;
    for (&lines, 0..) |*line, i| {
        line.* = @splat('a' + @as(u8, @intCast(i)));
        line[99] = '\n';
    }
    const q = &logger.engine.queue.?;
    const first = try q.reserve();
    var published = false;
    defer if (!published) q.publish(first, &lines[0]);
    for (lines[1..]) |*line| try q.tryPush(line);
    q.publish(first, &lines[0]);
    published = true;
    try logger.flush(.none); // a, b and half of c reached the sink before the write failed
    logger.info("after", .{});
    try logger.flush(.none);
    const s = logger.stats();
    try testing.expectEqual(@as(u64, 1), s.written);
    try testing.expectEqual(@as(u64, 7), s.dropped.write_failed);
    try testing.expectEqual(@as(u64, 1), s.torn_lines);
    try testing.expectEqual(@as(u64, 1), s.write_errors);
    const out = slow.sink.written();
    try testing.expectStringEndsWith(out, " INFO  after\n");
    const last_line = if (std.mem.findLast(u8, out[0 .. out.len - 1], "\n")) |at| at + 1 else 0;
    try testing.expect(std.ascii.isDigit(out[last_line])); // its timestamp, not the rest of c
}

fn shutdownThenCheckJoined(logger: Logger, joined: *std.atomic.Value(u32)) void {
    logger.shutdown(.none) catch return;
    if (logger.engine.writer_thread.thread == null) _ = joined.fetchAdd(1, .seq_cst);
}

test "queued: two shutdowns at once both return after the writer thread has exited" {
    var lock: Lock = .{ .sink = .init(testing.allocator) };
    defer lock.sink.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .mode = .{ .queued = .{} }, .output = .{ .writer = &lock.writer } });
    var live = true;
    defer if (live) {
        lock.open.store(true, .seq_cst);
        logger.deinit();
    };
    logger.info("held", .{});
    lock.waitEntered();
    var joined: std.atomic.Value(u32) = .init(0);
    {
        var threads: [2]std.Thread = undefined;
        var spawned: usize = 0;
        defer for (threads[0..spawned]) |thread| thread.join();
        defer lock.open.store(true, .seq_cst);
        for (&threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, shutdownThenCheckJoined, .{ logger, &joined });
            spawned += 1;
        }
        try waitWaiters(&logger.engine.progress_waiters, 2);
    }
    logger.deinit();
    live = false;
    try testing.expectEqual(@as(u32, 2), joined.load(.seq_cst));
}

fn flushThenCount(logger: Logger, flushed: *std.atomic.Value(u32)) void {
    logger.flush(.none) catch return;
    _ = flushed.fetchAdd(1, .seq_cst);
}

test "queued: a flush during a shutdown returns once the queue is written" {
    var lock: Lock = .{ .sink = .init(testing.allocator) };
    defer lock.sink.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .mode = .{ .queued = .{} }, .output = .{ .writer = &lock.writer } });
    var live = true;
    defer if (live) {
        lock.open.store(true, .seq_cst);
        logger.deinit();
    };
    logger.info("held", .{});
    lock.waitEntered();
    logger.info("queued", .{});
    var joined: std.atomic.Value(u32) = .init(0);
    var flushed: std.atomic.Value(u32) = .init(0);
    {
        const stopper = try std.Thread.spawn(.{}, shutdownThenCheckJoined, .{ logger, &joined });
        defer stopper.join();
        var flusher: ?std.Thread = null;
        defer if (flusher) |thread| thread.join();
        defer lock.open.store(true, .seq_cst);
        flusher = try std.Thread.spawn(.{}, flushThenCount, .{ logger, &flushed });
        try waitWaiters(&logger.engine.progress_waiters, 2);
    }
    logger.deinit();
    live = false;
    try testing.expectEqual(@as(u32, 1), joined.load(.seq_cst));
    try testing.expectEqual(@as(u32, 1), flushed.load(.seq_cst));
    try testing.expectEqual(@as(usize, 2), lock.lines());
}

test "queued: shutdown writes what is queued, then refuses records and counts them" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .mode = .{ .queued = .{} }, .output = .{ .writer = &out.writer } });
    defer logger.deinit();
    for (0..10) |i| logger.info("before", .{ .i = i });
    try logger.shutdown(.none);
    try logger.shutdown(.none); // a second shutdown has nothing left to do
    logger.info("after", .{});
    const s = logger.stats();
    try testing.expectEqual(@as(usize, 10), std.mem.count(u8, out.written(), "\n"));
    try testing.expectEqual(@as(u64, 1), s.dropped.closed);
    try testing.expectEqual(@as(u64, 10), s.written);
}

fn openLater(lock: *Lock) void {
    testing.io.sleep(.fromMilliseconds(20), .awake) catch {};
    lock.open.store(true, .seq_cst);
}

/// Opens `lock` once `deinit` has told the writer thread to drop what is
/// left. `deinit` waits for the write `lock` holds, so `engine` is alive
/// while this reads it.
fn openOnAbandon(lock: *Lock, engine: *const Engine) void {
    while (!engine.abandon.load(.seq_cst)) std.Thread.yield() catch {};
    lock.open.store(true, .seq_cst);
}

test "queued: a shutdown that times out leaves records pending; deinit then drops them" {
    var lock: Lock = .{ .sink = .init(testing.allocator) };
    defer lock.sink.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .mode = .{ .queued = .{ .batch_size = 1 } }, .output = .{ .writer = &lock.writer } });
    var live = true;
    defer if (live) {
        lock.open.store(true, .seq_cst);
        logger.deinit();
    };
    logger.info("held", .{});
    lock.waitEntered();
    for (0..3) |i| logger.info("queued", .{ .i = i });
    try testing.expectError(error.Timeout, logger.shutdown(.{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }));
    try testing.expectEqual(@as(u64, 4), logger.stats().pending);
    const opener = try std.Thread.spawn(.{}, openOnAbandon, .{ &lock, logger.engine });
    logger.deinit(); // waits for the write in progress, drops the three queued records
    live = false;
    opener.join();
    try testing.expectEqual(@as(usize, 1), lock.lines());
}

test "sync: shutdown refuses later records and counts them" {
    var c: Capture = undefined;
    try c.open(.{});
    defer c.close();
    c.logger.info("before", .{});
    try c.logger.shutdown(.none);
    try c.logger.flush(.none); // nothing to wait for in sync mode
    c.logger.info("after", .{});
    try c.expect(.json, &.{"\",\"level\":\"info\",\"message\":\"before\"}"});
    try testing.expectEqual(@as(u64, 1), c.logger.stats().dropped.closed);
}

test "queued: the writer thread writes the records, not the caller" {
    var sink: ThreadSink = .{};
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .mode = .{ .queued = .{} }, .output = .{ .writer = &sink.writer } });
    var live = true;
    defer if (live) logger.deinit();
    logger.info("m", .{});
    try waitProcessed(logger, 1);
    logger.deinit();
    live = false;
    try testing.expect(sink.thread.load(.seq_cst) != 0);
    try testing.expect(sink.thread.load(.seq_cst) != std.Thread.getCurrentId());
}

test "queued: records reach the output in order, and deinit writes what is left" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{
        .mode = .{ .queued = .{ .capacity = 64, .batch_size = 8 } },
        .output = .{ .writer = &out.writer },
    });
    for (0..50) |i| logger.info("tick", .{ .i = i });
    logger.deinit();
    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    var next: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try testing.expect(try std.json.validate(testing.allocator, line));
        try testing.expectEqual(next, try intAfter(line, "\"i\":"));
        next += 1;
    }
    try testing.expectEqual(@as(usize, 50), next);
}

test "queued: init takes the memory queueBytes names, and gives it all back" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const opts: options.Options = .{ .mode = .{ .queued = .{ .capacity = 256, .batch_size = 16 } }, .max_record_bytes = 1024, .output = .{ .writer = &sink.writer } };
    const logger: Logger = try .init(failing.allocator(), testing.io, opts);
    var live = true;
    defer if (live) logger.deinit();
    try testing.expectEqual(@sizeOf(Engine) + opts.queueBytes(), failing.allocated_bytes);
    logger.deinit();
    live = false;
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "queued: a one-record batch whose write fails mid-record tears that line only" {
    var gate: Gate = .{ .budgets = &.{10}, .sink = .init(testing.allocator) };
    defer gate.sink.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .mode = .{ .queued = .{} }, .output = .{ .writer = &gate.writer } });
    var live = true;
    defer if (live) logger.deinit();
    logger.info("first", .{});
    try waitProcessed(logger, 1);
    logger.info("second", .{});
    try waitProcessed(logger, 2);
    const s = logger.stats();
    logger.deinit();
    live = false;
    var lines = std.mem.splitScalar(u8, gate.sink.written(), '\n');
    try testing.expectEqualStrings("{\"timestam", lines.next().?);
    try testing.expectStringEndsWith(lines.next().?, "\"message\":\"second\"}");
    try testing.expectEqualStrings("", lines.rest());
    try testing.expectEqual(@as(u64, 1), s.written);
    try testing.expectEqual(@as(u64, 1), s.dropped.write_failed);
    try testing.expectEqual(@as(u64, 1), s.torn_lines);
}

/// A writer that holds the writer thread inside its first write until
/// `open` is set, as `Lock` does, and fails once: write number `cut`
/// (from 1) takes its bytes through line break number `lines` and `extra`
/// bytes more, then the write after it fails. A cut that leaves nothing
/// fails at once. Every other write takes everything.
const FailingLock = struct {
    cut: usize,
    lines: usize = 0,
    extra: usize = 0,
    entered: std.atomic.Value(bool) = .init(false),
    open: std.atomic.Value(bool) = .init(false),
    /// The writer thread's alone.
    writes: usize = 0,
    fail_next: bool = false,
    sink: std.Io.Writer.Allocating,
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        // The logger writes one slice at a time.
        std.debug.assert(data.len == 1 and splat == 1);
        const lock: *FailingLock = @alignCast(@fieldParentPtr("writer", w));
        lock.writes += 1;
        if (lock.writes == 1) {
            lock.entered.store(true, .seq_cst);
            while (!lock.open.load(.seq_cst)) std.Thread.yield() catch {};
        }
        if (lock.fail_next) {
            lock.fail_next = false;
            return error.WriteFailed;
        }
        var bytes = data[0];
        if (lock.writes == lock.cut) {
            var keep: usize = 0;
            for (0..lock.lines) |_| keep = if (std.mem.findScalarPos(u8, bytes, keep, '\n')) |at| at + 1 else bytes.len;
            keep = @min(bytes.len, keep + lock.extra);
            if (keep == 0) return error.WriteFailed;
            bytes = bytes[0..keep];
            lock.fail_next = true;
        }
        lock.sink.writer.writeAll(bytes) catch return error.WriteFailed;
        return bytes.len;
    }
};

/// Waits, at most five seconds, until a writer holds the writer thread.
fn waitHeld(entered: *const std.atomic.Value(bool)) !void {
    for (0..5000) |_| {
        if (entered.load(.seq_cst)) return;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TestWriterNeverEntered;
}

test "queued: a batch write that fails mid-record drops the rest of the batch; the next record starts a new line" {
    // The batch's write takes its first record and 10 bytes of the second.
    var lock: FailingLock = .{ .cut = 2, .lines = 1, .extra = 10, .sink = .init(testing.allocator) };
    defer lock.sink.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .mode = .{ .queued = .{} }, .output = .{ .writer = &lock.writer } });
    defer logger.deinit();
    defer lock.open.store(true, .seq_cst);
    logger.info("held", .{});
    try waitHeld(&lock.entered);
    for (1..5) |i| logger.info("queued", .{ .i = i }); // one batch of four
    lock.open.store(true, .seq_cst);
    try logger.flush(.none);
    logger.info("after", .{});
    try logger.flush(.none);
    var lines = std.mem.splitScalar(u8, lock.sink.written(), '\n');
    try testing.expectStringEndsWith(lines.next().?, "\"message\":\"held\"}");
    try testing.expectStringEndsWith(lines.next().?, "\"message\":\"queued\",\"i\":1}");
    try testing.expectEqualStrings("{\"timestam", lines.next().?);
    try testing.expectStringEndsWith(lines.next().?, "\"message\":\"after\"}");
    try testing.expectEqualStrings("", lines.rest());
    const s = logger.stats();
    try testing.expectEqual(@as(u64, 3), s.written);
    try testing.expectEqual(@as(u64, 3), s.dropped.write_failed);
    try testing.expectEqual(@as(u64, 1), s.torn_lines);
    try testing.expectEqual(@as(u64, 1), s.write_errors);
}

test "queued: a batch write that fails right after a whole record counts that record written and tears no line" {
    // The batch's write takes its first record whole, then fails.
    var lock: FailingLock = .{ .cut = 2, .lines = 1, .sink = .init(testing.allocator) };
    defer lock.sink.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .mode = .{ .queued = .{ .batch_size = 8 } }, .output = .{ .writer = &lock.writer } });
    defer logger.deinit();
    defer lock.open.store(true, .seq_cst);
    logger.info("held", .{});
    try waitHeld(&lock.entered);
    logger.info("rec1", .{});
    logger.info("rec2", .{}); // one batch with rec1
    lock.open.store(true, .seq_cst);
    try logger.flush(.none);
    logger.info("rec3", .{});
    try logger.flush(.none);
    const out = lock.sink.written();
    try testing.expect(std.mem.find(u8, out, "\n\n") == null);
    var lines = std.mem.splitScalar(u8, out, '\n');
    try testing.expectStringEndsWith(lines.next().?, "\"message\":\"held\"}");
    try testing.expectStringEndsWith(lines.next().?, "\"message\":\"rec1\"}");
    try testing.expectStringEndsWith(lines.next().?, "\"message\":\"rec3\"}");
    try testing.expectEqualStrings("", lines.rest());
    const s = logger.stats();
    try testing.expectEqual(@as(u64, 3), s.written);
    try testing.expectEqual(@as(u64, 1), s.dropped.write_failed);
    try testing.expectEqual(@as(u64, 0), s.torn_lines);
    try testing.expectEqual(@as(u64, 1), s.write_errors);
}

test "queued: a stdout that stays full drops the batch after a short retry" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // the test needs POSIX pipes
    const io = testing.io;
    const fds = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true });
    const read_end: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = true } };
    const write_end: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = true } };
    defer read_end.close(io);
    defer write_end.close(io);
    const filled = try fillPipe(write_end, io);

    const logger: Logger = try .init(testing.allocator, io, .{ .mode = .{ .queued = .{} } });
    defer logger.deinit();
    logger.engine.stdout = write_end;
    logger.info("lost", .{});
    try waitProcessed(logger, 1);
    var s = logger.stats();
    try testing.expectEqual(@as(u64, 0), s.written);
    try testing.expectEqual(@as(u64, 1), s.dropped.write_failed);
    try testing.expectEqual(@as(u64, 0), s.torn_lines);

    var all: std.Io.Writer.Allocating = .init(testing.allocator);
    defer all.deinit();
    try readAvailable(read_end, io, &all, std.math.maxInt(usize));
    logger.info("kept", .{});
    try waitProcessed(logger, 2);
    try readAvailable(read_end, io, &all, std.math.maxInt(usize));
    s = logger.stats();
    try testing.expectEqual(@as(u64, 1), s.written);
    const out = all.written()[filled..];
    try testing.expect(std.mem.startsWith(u8, out, "{\"timestamp\""));
    try testing.expectStringEndsWith(out, "\"message\":\"kept\"}\n");
}

test "queued: a stdout that is full for a moment keeps the batch" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // the test needs POSIX pipes
    const io = testing.io;
    const fds = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true });
    const read_end: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = true } };
    const write_end: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = true } };
    defer read_end.close(io);
    defer write_end.close(io);
    const logger: Logger = try .init(testing.allocator, io, .{ .mode = .{ .queued = .{} } });
    defer logger.deinit();
    logger.engine.stdout = write_end;
    var all: std.Io.Writer.Allocating = .init(testing.allocator);
    defer all.deinit();
    // The writer thread meets a full pipe and retries for 10 ms; room comes
    // a millisecond later. A round in which this thread made room only after
    // 9 ms tells nothing, as the retries may have run out: it is tried again.
    for (0..5) |_| {
        all.clearRetainingCapacity();
        const filled = try fillPipe(write_end, io);
        const before = logger.stats();
        const start = std.Io.Clock.awake.now(io);
        logger.info("kept", .{});
        // Until the writer thread has it; a late pop only makes a late round.
        while (logger.stats().queue_depth != 0) {
            if (start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds > 5 * std.time.ns_per_s) return error.TestTimedOut;
            try io.sleep(.fromMicroseconds(50), .awake);
        }
        try io.sleep(.fromMilliseconds(1), .awake);
        try readAvailable(read_end, io, &all, std.math.maxInt(usize));
        const in_time = start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds < 9 * std.time.ns_per_ms;
        try waitProcessed(logger, before.written + before.dropped.write_failed + 1);
        try readAvailable(read_end, io, &all, std.math.maxInt(usize));
        if (!in_time) continue;
        const s = logger.stats();
        try testing.expectEqual(before.written + 1, s.written);
        try testing.expectEqual(before.write_errors, s.write_errors);
        const out = all.written()[filled..];
        try testing.expect(std.mem.startsWith(u8, out, "{\"timestamp\""));
        try testing.expectStringEndsWith(out, "\"message\":\"kept\"}\n");
        return;
    }
    return error.SkipZigTest; // this machine never made room in time
}

test "queued: a closed stdout is noted on stderr once by the writer thread" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // the test needs POSIX pipes
    const io = testing.io;
    const stdout_pipe = try std.Io.Threaded.pipe2(.{});
    const stderr_pipe = try std.Io.Threaded.pipe2(.{});
    const stdout_write = pipeEnd(stdout_pipe[1]);
    const stderr_read = pipeEnd(stderr_pipe[0]);
    const stderr_write = pipeEnd(stderr_pipe[1]);
    defer stdout_write.close(io);
    defer stderr_read.close(io);
    pipeEnd(stdout_pipe[0]).close(io);

    const logger: Logger = try .init(testing.allocator, io, .{ .mode = .{ .queued = .{} } });
    var live = true;
    defer if (live) logger.deinit();
    logger.engine.stdout = stdout_write;
    logger.engine.stderr = stderr_write;
    logger.info("first", .{});
    try waitProcessed(logger, 1);
    logger.info("second", .{});
    try waitProcessed(logger, 2);
    const s = logger.stats();
    logger.deinit();
    live = false;
    stderr_write.close(io);
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("zefir.log: stdout is closed (BrokenPipe); dropping the records that follow\n", try readToEnd(stderr_read, io, &buf));
    try testing.expectEqual(@as(u64, 0), s.written);
    try testing.expectEqual(@as(u64, 2), s.dropped.write_failed);
}

test "queued: error records the full queue refuses are reported in the log by one summary record" {
    var lock: Lock = .{ .sink = .init(testing.allocator) };
    defer lock.sink.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{
        .mode = .{ .queued = .{ .capacity = 4, .batch_size = 1 } },
        .output = .{ .writer = &lock.writer },
    });
    defer logger.deinit();
    defer lock.open.store(true, .seq_cst);
    logger.info("held", .{});
    lock.waitEntered();
    for (0..4) |i| logger.info("queued", .{ .i = i });
    logger.err("lost", .{});
    logger.err("lost", .{});
    logger.info("lost", .{});
    var s = logger.stats();
    try testing.expectEqual(@as(u64, 2), s.dropped.err);
    try testing.expectEqual(@as(u64, 1), s.dropped.queue_full);
    lock.open.store(true, .seq_cst);
    try logger.flush(.none);
    const out = lock.sink.written();
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, out, "\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "zefir.log"));
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (std.mem.find(u8, line, "zefir.log") == null) continue;
        try testing.expect(try std.json.validate(testing.allocator, line));
        try testing.expectStringEndsWith(line, "\",\"level\":\"error\",\"message\":\"zefir.log: error records dropped\",\"suppressed\":2}");
    }
    s = logger.stats();
    try testing.expectEqual(@as(u64, 5), s.written); // the summary is the logger's own record
}

test "queued: in text the summary of dropped error records is a line of its own" {
    var lock: Lock = .{ .sink = .init(testing.allocator) };
    defer lock.sink.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{
        .format = .text,
        .mode = .{ .queued = .{ .capacity = 2, .batch_size = 1 } },
        .output = .{ .writer = &lock.writer },
    });
    defer logger.deinit();
    defer lock.open.store(true, .seq_cst);
    logger.info("held", .{});
    lock.waitEntered();
    for (0..2) |i| logger.info("queued", .{ .i = i });
    logger.err("lost", .{});
    lock.open.store(true, .seq_cst);
    try logger.flush(.none);
    var lines = std.mem.splitScalar(u8, lock.sink.written(), '\n');
    _ = lines.next(); // "held"
    try testing.expectStringEndsWith(lines.next().?, " ERROR zefir.log: error records dropped suppressed=1");
}

/// A buffered writer that holds the writer thread inside its first drain
/// until `open` is set; drain number `fail_drain` (from 1) fails and loses
/// what the buffer held, as `FlakyFlush` does.
const FlakyFlushLock = struct {
    fail_drain: usize,
    entered: std.atomic.Value(bool) = .init(false),
    open: std.atomic.Value(bool) = .init(false),
    /// The writer thread's alone.
    drains: usize = 0,
    sink: std.Io.Writer.Allocating,
    buffer: [1024]u8 = undefined,
    writer: std.Io.Writer = undefined,

    fn start(f: *FlakyFlushLock) void {
        f.writer = .{ .buffer = &f.buffer, .vtable = &.{ .drain = drain } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const f: *FlakyFlushLock = @alignCast(@fieldParentPtr("writer", w));
        f.drains += 1;
        if (f.drains == 1) {
            f.entered.store(true, .seq_cst);
            while (!f.open.load(.seq_cst)) std.Thread.yield() catch {};
        }
        if (f.drains == f.fail_drain) {
            w.end = 0;
            return error.WriteFailed;
        }
        f.sink.writer.writeAll(w.buffered()) catch return error.WriteFailed;
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            f.sink.writer.writeAll(bytes) catch return error.WriteFailed;
            n += bytes.len;
        }
        for (0..splat) |_| f.sink.writer.writeAll(data[data.len - 1]) catch return error.WriteFailed;
        return n + data[data.len - 1].len * splat;
    }
};

/// Holds the writer thread on "held", fills a queue of 2 and has it refuse
/// one error record, then lets the writer go and flushes; returns the
/// stats. `lock` is a `FailingLock` or a `FlakyFlushLock`.
fn logPastFullQueue(lock: anytype) !Engine.Stats {
    const logger: Logger = try .init(testing.allocator, testing.io, .{
        .mode = .{ .queued = .{ .capacity = 2, .batch_size = 1 } },
        .output = .{ .writer = &lock.writer },
    });
    defer logger.deinit();
    defer lock.open.store(true, .seq_cst);
    logger.info("held", .{});
    try waitHeld(&lock.entered);
    for (0..2) |i| logger.info("queued", .{ .i = i });
    logger.err("lost", .{}); // refused: the queue is full
    lock.open.store(true, .seq_cst);
    try logger.flush(.none);
    return logger.stats();
}

/// How the summary of one dropped error record ends.
const summary_of_one = "\"message\":\"zefir.log: error records dropped\",\"suppressed\":1}";

test "queued: a summary of dropped error records whose write fails keeps its count for the next summary" {
    // Write 2, the summary after "held", fails with nothing sent.
    var lock: FailingLock = .{ .cut = 2, .sink = .init(testing.allocator) };
    defer lock.sink.deinit();
    const s = try logPastFullQueue(&lock);
    const out = lock.sink.written();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, summary_of_one));
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, out, "\n"));
    try testing.expectEqual(@as(u64, 1), s.dropped.err);
    try testing.expectEqual(@as(u64, 1), s.write_errors);
    try testing.expectEqual(@as(u64, 3), s.written);
}

test "queued: a summary after a torn line ends that line, and the record after it starts its own" {
    // Write 1, "held", sends 10 bytes, then the next write fails: its line is torn.
    var lock: FailingLock = .{ .cut = 1, .extra = 10, .sink = .init(testing.allocator) };
    defer lock.sink.deinit();
    const s = try logPastFullQueue(&lock);
    var lines = std.mem.splitScalar(u8, lock.sink.written(), '\n');
    try testing.expectEqualStrings("{\"timestam", lines.next().?);
    const summary = lines.next().?;
    try testing.expectStringEndsWith(summary, summary_of_one);
    try testing.expect(try std.json.validate(testing.allocator, summary));
    try testing.expectStringEndsWith(lines.next().?, "\"message\":\"queued\",\"i\":0}");
    try testing.expectStringEndsWith(lines.next().?, "\"message\":\"queued\",\"i\":1}");
    try testing.expectEqualStrings("", lines.rest());
    try testing.expectEqual(@as(u64, 1), s.torn_lines);
    try testing.expectEqual(@as(u64, 2), s.written);
}

test "queued: a summary of dropped error records whose flush fails keeps its count for the next summary" {
    // Drain 2 is the flush of the summary after "held": it fails.
    var flaky: FlakyFlushLock = .{ .fail_drain = 2, .sink = .init(testing.allocator) };
    defer flaky.sink.deinit();
    flaky.start();
    const s = try logPastFullQueue(&flaky);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, flaky.sink.written(), summary_of_one));
    try testing.expectEqual(@as(u64, 1), s.torn_lines);
    try testing.expectEqual(@as(u64, 3), s.written);
}

test "queued: logging, waits for room, the error summary, emergency, flush and shutdown never allocate" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var dropping_lock: Lock = .{ .sink = .init(testing.allocator) };
    defer dropping_lock.sink.deinit();
    var blocking_lock: Lock = .{ .sink = .init(testing.allocator) };
    defer blocking_lock.sink.deinit();
    const dropping: Logger = try .init(failing.allocator(), testing.io, .{ .mode = .{ .queued = .{ .capacity = 4, .batch_size = 1 } }, .output = .{ .writer = &dropping_lock.writer } });
    defer dropping.deinit();
    defer dropping_lock.open.store(true, .seq_cst);
    const blocking: Logger = try .init(failing.allocator(), testing.io, .{ .mode = .{ .queued = .{ .capacity = 2, .batch_size = 1, .overflow = .block } }, .output = .{ .writer = &blocking_lock.writer } });
    defer blocking.deinit();
    defer blocking_lock.open.store(true, .seq_cst);
    failing.fail_index = failing.alloc_index; // every allocation from here on fails
    const before = failing.allocations;

    dropping.info("held", .{});
    dropping_lock.waitEntered();
    for (0..4) |i| dropping.info("queued", .{ .i = i });
    dropping.err("dropped", .{});
    dropping.info("dropped", .{});
    dropping_lock.open.store(true, .seq_cst);
    try dropping.flush(.none);

    blocking.info("held", .{});
    blocking_lock.waitEntered();
    for (0..2) |i| blocking.info("queued", .{ .i = i });
    var done: std.atomic.Value(bool) = .init(false);
    const producer = try std.Thread.spawn(.{}, logBlocking, .{ blocking, &done });
    const waited = waitWaiters(&blocking.engine.queue.?.space_waiters, 1);
    blocking_lock.open.store(true, .seq_cst);
    producer.join();
    try waited;
    try blocking.flush(.none);

    {
        var stderr: StderrFile = try .open();
        defer stderr.close();
        dropping.engine.stderr = stderr.file;
        dropping.emergency("Going down", .{ .code = 7 });
    }
    try dropping.shutdown(.none);
    try blocking.shutdown(.none);
    try testing.expectEqual(before, failing.allocations);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, dropping_lock.sink.written(), "zefir.log: error records dropped"));
    try testing.expectEqual(@as(usize, 4), blocking_lock.lines());
}

test "emergency: a record with no room for the count goes out without it, and the next one tells" {
    var stderr: StderrFile = try .open();
    defer stderr.close();
    // The smallest record that holds every mandatory part.
    const smallest: u32 = @intCast(encode.mandatoryBytes(.json, 0, scopes.max_name_bytes));
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .max_record_bytes = smallest });
    var live = true;
    defer if (live) logger.deinit();
    logger.engine.stderr = stderr.file;
    const long_scope: [scopes.max_name_bytes]u8 = @splat('s');
    const ctx = core.Context.root.withTrace(try traceContext("4bf92f3577b34da6a3ce929d0e0e4736", "00f067aa0ba902b7"));
    const widest = logger.scoped(&long_scope).withContext(ctx);
    logger.engine.bucket.tokens = 0;
    logger.engine.bucket.earned_at = std.math.maxInt(i64); // earns nothing for now
    logger.emergency("Dropped", .{});
    logger.emergency("Dropped", .{});
    logger.engine.bucket.earned_at = 0; // long ago: the bucket is full again
    widest.emergency("Message", .{}); // whole, 13 bytes short of the limit: `,"suppressed":2` takes 15
    logger.emergency("Next", .{});
    const s = logger.stats();
    logger.deinit();
    live = false;
    var buf: [2048]u8 = undefined;
    var lines = std.mem.splitScalar(u8, try stderr.read(&buf), '\n');
    const whole = lines.next().?;
    try testing.expect(std.mem.find(u8, whole, "suppressed") == null);
    try testing.expect(std.mem.find(u8, whole, "truncated") == null);
    try testing.expectStringEndsWith(lines.next().?, "\"message\":\"Next\",\"suppressed\":2}");
    try testing.expectEqual(@as(u64, 2), s.emergency_written);
}

test "emergency: a record that fits is never cut to make room for the count" {
    var stderr: StderrFile = try .open();
    defer stderr.close();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .max_record_bytes = 512 });
    logger.engine.stderr = stderr.file;
    const detail: [419]u8 = @splat('d');
    logger.engine.bucket.refuse(); // a record left out before
    logger.emergency("Disk full", .{ .detail = @as([]const u8, detail[0..400]) }); // 491 bytes whole: the count fits beside it
    logger.engine.bucket.refuse();
    logger.emergency("Disk full", .{ .detail = @as([]const u8, &detail) }); // 510 bytes whole: the count does not fit
    logger.emergency("Next", .{});
    const s = logger.stats();
    logger.deinit();
    var buf: [2048]u8 = undefined;
    var lines = std.mem.splitScalar(u8, try stderr.read(&buf), '\n');
    const told = lines.next().?;
    try testing.expectEqual(@as(usize, 490 + ",\"suppressed\":1".len), told.len);
    try testing.expectStringEndsWith(told, "dd\",\"suppressed\":1}");
    const whole = lines.next().?;
    try testing.expectEqual(@as(usize, 509), whole.len);
    try testing.expectStringEndsWith(whole, "dd\"}");
    try testing.expectStringEndsWith(lines.next().?, "\"message\":\"Next\",\"suppressed\":1}");
    try testing.expectEqual(@as(u64, 0), s.truncated);
    try testing.expectEqual(@as(u64, 3), s.emergency_written);
}

/// The logger's stderr as a file in a temporary directory, which `read`
/// gives back at any time; unlike a pipe, it works on every OS.
const StderrFile = struct {
    tmp: testing.TmpDir,
    file: std.Io.File,

    fn open() !StderrFile {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .file = try tmp.dir.createFile(testing.io, "stderr", .{}) };
    }

    /// Everything written to the file so far.
    fn read(f: *StderrFile, buf: []u8) ![]u8 {
        return f.tmp.dir.readFile(testing.io, "stderr", buf);
    }

    /// An empty file next to it, opened read-only: every write to it fails.
    fn readOnly(f: *StderrFile, name: []const u8) !std.Io.File {
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "" });
        return f.tmp.dir.openFile(testing.io, name, .{});
    }

    fn close(f: *StderrFile) void {
        f.file.close(testing.io);
        f.tmp.cleanup();
    }
};

test "a stdout opened read-only: POSIX notes it on stderr once, Windows counts each failed write" {
    var stderr: StderrFile = try .open();
    defer stderr.close();
    const read_only = try stderr.readOnly("stdout");
    defer read_only.close(testing.io);
    const logger: Logger = try .init(testing.allocator, testing.io, .{});
    defer logger.deinit();
    logger.engine.stdout = read_only;
    logger.engine.stderr = stderr.file;
    logger.info("first", .{});
    logger.info("second", .{});
    const s = logger.stats();
    var buf: [512]u8 = undefined;
    const note = try stderr.read(&buf);
    try testing.expectEqual(@as(u64, 0), s.written);
    try testing.expectEqual(@as(u64, 2), s.dropped.write_failed);
    if (builtin.os.tag == .windows) {
        // A write without write access fails with AccessDenied, which is
        // not a closed stdout: each record tries again.
        try testing.expectEqualStrings("", note);
        try testing.expectEqual(@as(u64, 2), s.write_errors);
    } else {
        try testing.expectEqualStrings("zefir.log: stdout is not open for writing (NotOpenForWriting); dropping the records that follow\n", note);
        try testing.expectEqual(@as(u64, 1), s.write_errors);
    }
}

/// A pipe for the logger's stderr; POSIX only.
const StderrPipe = struct {
    read_end: std.Io.File,
    write_end: std.Io.File,
    write_open: bool = true,

    fn open() !StderrPipe {
        const fds = try std.Io.Threaded.pipe2(.{});
        return .{ .read_end = pipeEnd(fds[0]), .write_end = pipeEnd(fds[1]) };
    }

    fn close(p: *StderrPipe) void {
        if (p.write_open) p.write_end.close(testing.io);
        p.read_end.close(testing.io);
    }
};

/// Reads a pipe at most 512 bytes at a time, with a yield after each read,
/// so the pipe stays full and a long record goes out in parts: lines
/// written at once from several threads would mix.
const SlowReader = struct {
    file: std.Io.File,
    buf: []u8,
    len: usize = 0,
    /// Bytes read once `buf` was full.
    lost: usize = 0,

    fn run(r: *SlowReader) void {
        var spare: [512]u8 = undefined;
        while (true) {
            const room = r.buf[r.len..];
            const into = if (room.len > 0) room[0..@min(512, room.len)] else &spare;
            // Ends once the write end is closed.
            const n = r.file.readStreaming(testing.io, &.{into}) catch return;
            if (room.len > 0) r.len += n else r.lost += n;
            std.Thread.yield() catch {};
        }
    }
};

/// Calls `emergency` `calls` times with a field of `payload_len` bytes.
/// With a short field it pauses after every tenth call, so the bucket earns
/// tokens while calls are left out, and the next records tell of them.
fn emergencies(logger: Logger, worker: usize, calls: usize, payload_len: usize) void {
    var payload: [12000]u8 = undefined;
    @memset(&payload, 'a' + @as(u8, @intCast(worker)));
    for (0..calls) |i| {
        logger.emergency("Going down", .{ .worker = worker, .i = i, .payload = @as([]const u8, payload[0..payload_len]) });
        if (payload_len < 100 and i % 10 == 9) testing.io.sleep(.fromMilliseconds(15), .awake) catch {};
    }
}

/// Runs `emergencies` on eight threads at once.
fn emergenciesAtOnce(logger: Logger, calls: usize, payload_len: usize) !void {
    var threads: [8]std.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    for (&threads, 0..) |*thread, worker| {
        thread.* = try std.Thread.spawn(.{}, emergencies, .{ logger, worker, calls, payload_len });
        started += 1;
    }
}

/// What eight threads calling `emergency` at once left in the stats:
/// first 12 long records each, within the burst, then 50 short ones each.
const Emergencies = struct { burst: Engine.Stats, all: Engine.Stats, untold: u64 };

fn emergenciesFromThreads(stderr: std.Io.File) !Emergencies {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .max_record_bytes = 16384, .output = .{ .writer = &sink.writer } });
    defer logger.deinit();
    logger.engine.stderr = stderr;
    try emergenciesAtOnce(logger, 12, 12000); // each record longer than PIPE_BUF
    const burst = logger.stats();
    try emergenciesAtOnce(logger, 50, 10); // past the burst: most are left out
    return .{ .burst = burst, .all = logger.stats(), .untold = logger.engine.bucket.refused };
}

test "emergency lines from several threads at once stay whole, and every call is counted and told" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // the test needs POSIX pipes
    var stderr: StderrPipe = try .open();
    defer stderr.close();
    const buf = try testing.allocator.alloc(u8, 4 << 20);
    defer testing.allocator.free(buf);
    var reader: SlowReader = .{ .file = stderr.read_end, .buf = buf };
    const reading = try std.Thread.spawn(.{}, SlowReader.run, .{&reader});
    const result = emergenciesFromThreads(stderr.write_end);
    stderr.write_end.close(testing.io); // the reader meets the end of the pipe
    stderr.write_open = false;
    reading.join();
    const got = try result;
    try testing.expectEqual(@as(usize, 0), reader.lost);
    var lines = std.mem.splitScalar(u8, buf[0..reader.len], '\n');
    var written: u64 = 0;
    var told: u64 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue; // the piece after the final '\n'
        written += 1;
        try testing.expect(try std.json.validate(testing.allocator, line));
        const key = "\"suppressed\":";
        if (std.mem.find(u8, line, key)) |at| told += try std.fmt.parseInt(u64, std.mem.trimEnd(u8, line[at + key.len ..], "}"), 10);
    }
    try testing.expectEqual(@as(u64, 8 * 12), got.burst.emergency_written);
    try testing.expectEqual(@as(u64, 8 * (12 + 50)), got.all.emergency_written + got.all.emergency_suppressed);
    try testing.expectEqual(got.all.emergency_written, written);
    // Each call left out is told by a later record, or still waits in the bucket.
    try testing.expect(told > 0);
    try testing.expectEqual(got.all.emergency_suppressed, told + got.untold);
}

test "error records refused after shutdown are counted, and deinit notes them on stderr" {
    var stderr: StderrFile = try .open();
    defer stderr.close();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .mode = .{ .queued = .{} }, .output = .{ .writer = &out.writer } });
    var live = true;
    defer if (live) logger.deinit();
    logger.engine.stderr = stderr.file;
    try logger.shutdown(.none);
    logger.err("late", .{});
    logger.err("late", .{});
    logger.info("late", .{});
    const s = logger.stats();
    logger.deinit();
    live = false;
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("zefir.log: error records dropped and not in the log: 2\n", try stderr.read(&buf));
    try testing.expectEqual(@as(u64, 2), s.dropped.err);
    try testing.expectEqual(@as(u64, 1), s.dropped.closed);
    try testing.expectEqualStrings("", out.written());
}

test "sync: an error record too long for .drop counts in dropped.err, and deinit notes it on stderr" {
    var stderr: StderrFile = try .open();
    defer stderr.close();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .oversize = .drop, .max_record_bytes = 512, .output = .{ .writer = &out.writer } });
    logger.engine.stderr = stderr.file;
    const data: [1024]u8 = @splat('d');
    logger.err("Too long", .{ .data = @as([]const u8, &data) });
    logger.info("Too long", .{ .data = @as([]const u8, &data) });
    const s = logger.stats();
    logger.deinit();
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("zefir.log: error records dropped and not in the log: 1\n", try stderr.read(&buf));
    try testing.expectEqual(@as(u64, 1), s.dropped.err);
    try testing.expectEqual(@as(u64, 1), s.dropped.oversize); // the info record
    try testing.expectEqualStrings("", out.written());
}

test "queued: an error record too long for .drop is reported by the summary record" {
    var c: Capture = undefined;
    try c.open(.{ .mode = .{ .queued = .{ .capacity = 4 } }, .oversize = .drop, .max_record_bytes = 512 });
    defer c.close();
    const data: [1024]u8 = @splat('d');
    c.logger.err("Too long", .{ .data = @as([]const u8, &data) });
    c.logger.info("Too long", .{ .data = @as([]const u8, &data) });
    // A dropped record takes no slot in the queue: flush waits for this
    // one, and the summary is written before it returns.
    c.logger.info("After", .{});
    try c.logger.flush(.none);
    const s = c.logger.stats();
    try testing.expectEqual(@as(u64, 1), s.dropped.err);
    try testing.expectEqual(@as(u64, 1), s.dropped.oversize);
    // The writer thread may write the summary before "After" or after it.
    const out = c.out.written();
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\",\"level\":\"info\",\"message\":\"After\"}\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\",\"level\":\"error\",\"message\":\"zefir.log: error records dropped\",\"suppressed\":1}\n"));
}

test "queued: an error record too long for .drop wakes the sleeping writer thread, which reports it at once" {
    var c: Capture = undefined;
    try c.open(.{ .mode = .{ .queued = .{ .capacity = 4 } }, .oversize = .drop, .max_record_bytes = 512 });
    defer c.close();
    try waitWriterAsleep(c.logger);
    const data: [1024]u8 = @splat('d');
    c.logger.err("Too long", .{ .data = @as([]const u8, &data) });
    // Well within the writer's one-second recheck: the refusal woke it, and
    // it took the count for its summary.
    const start = std.Io.Clock.awake.now(testing.io);
    while (c.logger.engine.errors_unreported.load(.seq_cst) != 0) {
        if (start.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds > 900 * std.time.ns_per_ms) return error.TestWriterNotWoken;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try c.logger.shutdown(.none);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, c.out.written(), "\",\"level\":\"error\",\"message\":\"zefir.log: error records dropped\",\"suppressed\":1}\n"));
}

test "queued: deinit after a timed-out shutdown writes no summary record; it notes the error records on stderr" {
    var stderr: StderrFile = try .open();
    defer stderr.close();
    var lock: Lock = .{ .sink = .init(testing.allocator) };
    defer lock.sink.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .mode = .{ .queued = .{ .batch_size = 1 } }, .output = .{ .writer = &lock.writer } });
    var running = true;
    defer if (running) logger.deinit();
    defer lock.open.store(true, .seq_cst);
    logger.engine.stderr = stderr.file;
    logger.info("held", .{});
    lock.waitEntered();
    try testing.expectError(error.Timeout, logger.shutdown(.{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }));
    logger.err("late", .{}); // refused: no summary has reported it yet
    const opener = try std.Thread.spawn(.{}, openOnAbandon, .{ &lock, logger.engine });
    running = false;
    logger.deinit(); // waits for the write in progress, and starts no other
    opener.join();
    try testing.expectEqual(@as(usize, 1), lock.lines());
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("zefir.log: error records dropped and not in the log: 1\n", try stderr.read(&buf));
}

test "emergency writes to stderr at once, past the queue, and after shutdown too" {
    var stderr: StderrFile = try .open();
    defer stderr.close();
    var lock: Lock = .{ .sink = .init(testing.allocator) };
    defer lock.sink.deinit();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .mode = .{ .queued = .{} }, .output = .{ .writer = &lock.writer } });
    defer logger.deinit();
    defer lock.open.store(true, .seq_cst);
    logger.engine.stderr = stderr.file;
    logger.info("held", .{});
    lock.waitEntered();
    logger.scoped("disk").emergency("Disk full", .{ .free = 0 });
    var buf: [512]u8 = undefined;
    const first = try stderr.read(&buf);
    try testing.expectStringEndsWith(first, "\",\"level\":\"error\",\"message\":\"Disk full\",\"scope\":\"disk\",\"free\":0}\n");
    try testing.expect(try std.json.validate(testing.allocator, first[0 .. first.len - 1]));
    lock.open.store(true, .seq_cst);
    try logger.shutdown(.none);
    logger.emergency("After shutdown", .{});
    const s = logger.stats();
    try testing.expectStringEndsWith(try stderr.read(&buf), "\",\"level\":\"error\",\"message\":\"After shutdown\"}\n");
    try testing.expectEqual(@as(u64, 2), s.emergency_written);
    try testing.expectEqual(@as(u64, 1), s.accepted);
    try testing.expectEqual(@as(usize, 1), lock.lines());
}

test "emergency: records past the rate limit are left out and counted; the next one says how many" {
    var stderr: StderrFile = try .open();
    defer stderr.close();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .format = .text });
    logger.engine.stderr = stderr.file;
    logger.engine.bucket.tokens = 0;
    logger.engine.bucket.earned_at = std.math.maxInt(i64); // earns nothing for now
    for (0..3) |_| logger.emergency("Dropped", .{});
    logger.engine.bucket.earned_at = 0; // long ago: the bucket is full again
    logger.emergency("Kept", .{});
    const s = logger.stats();
    logger.deinit();
    var buf: [256]u8 = undefined;
    try testing.expectStringEndsWith(try stderr.read(&buf), " ERROR Kept suppressed=3\n");
    try testing.expectEqual(@as(u64, 1), s.emergency_written);
    try testing.expectEqual(@as(u64, 3), s.emergency_suppressed);
}

test "emergency: a record too long for .drop is left out, and the next one tells of it" {
    var stderr: StderrFile = try .open();
    defer stderr.close();
    const logger: Logger = try .init(testing.allocator, testing.io, .{ .oversize = .drop, .max_record_bytes = 512 });
    logger.engine.stderr = stderr.file;
    const data: [1024]u8 = @splat('d');
    logger.emergency("Too long", .{ .data = @as([]const u8, &data) });
    logger.emergency("Next", .{});
    const s = logger.stats();
    logger.deinit();
    var buf: [512]u8 = undefined;
    try testing.expectStringEndsWith(try stderr.read(&buf), "\"message\":\"Next\",\"suppressed\":1}\n");
    try testing.expectEqual(@as(u64, 1), s.emergency_written);
    try testing.expectEqual(@as(u64, 1), s.emergency_suppressed);
    try testing.expectEqual(@as(u64, 0), s.dropped.oversize);
}

test "emergency: a failed write to stderr leaves the record out, and the next one tells of it" {
    var stderr: StderrFile = try .open();
    defer stderr.close();
    const read_only = try stderr.readOnly("read-only");
    defer read_only.close(testing.io);
    const logger: Logger = try .init(testing.allocator, testing.io, .{});
    logger.engine.stderr = read_only;
    logger.emergency("Lost", .{});
    logger.engine.stderr = stderr.file;
    logger.emergency("Next", .{});
    const s = logger.stats();
    logger.deinit();
    var buf: [512]u8 = undefined;
    try testing.expectStringEndsWith(try stderr.read(&buf), "\"message\":\"Next\",\"suppressed\":1}\n");
    try testing.expectEqual(@as(u64, 1), s.emergency_written);
    try testing.expectEqual(@as(u64, 1), s.emergency_suppressed);
}

var app_clock_reads: std.atomic.Value(u32) = .init(0);
var counting_vtable: std.Io.VTable = undefined;

fn countingNow(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
    _ = app_clock_reads.fetchAdd(1, .seq_cst);
    return testing.io.vtable.now(userdata, clock);
}

/// `testing.io`, counting the reads of its clock.
fn countingIo() std.Io {
    counting_vtable = testing.io.vtable.*;
    counting_vtable.now = countingNow;
    return .{ .userdata = testing.io.userdata, .vtable = &counting_vtable };
}

test "emergency does not use the application's Io, not even its clock" {
    var stderr: StderrFile = try .open();
    defer stderr.close();
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const logger: Logger = try .init(testing.allocator, countingIo(), .{ .output = .{ .writer = &sink.writer } });
    logger.engine.stderr = stderr.file;
    const before = app_clock_reads.load(.seq_cst);
    logger.emergency("Going down", .{});
    const by_emergency = app_clock_reads.load(.seq_cst) - before;
    logger.info("Regular", .{});
    const by_info = app_clock_reads.load(.seq_cst) - before - by_emergency;
    logger.deinit();
    try testing.expectEqual(@as(u32, 0), by_emergency);
    try testing.expectEqual(@as(u32, 1), by_info);
}

/// Calls `emergency` from inside the record being written.
const Reentrant = struct {
    logger: Logger,

    pub fn format(r: Reentrant, w: *std.Io.Writer) std.Io.Writer.Error!void {
        r.logger.emergency("Inner", .{});
        try w.writeAll("outer value");
    }
};

test "an emergency call made while an emergency record is being written is left out" {
    var stderr: StderrFile = try .open();
    defer stderr.close();
    const logger: Logger = try .init(testing.allocator, testing.io, .{});
    logger.engine.stderr = stderr.file;
    logger.emergency("Outer", .{ .value = Reentrant{ .logger = logger } });
    const s = logger.stats();
    logger.deinit();
    var buf: [256]u8 = undefined;
    const lines = try stderr.read(&buf);
    try testing.expectStringEndsWith(lines, "\",\"level\":\"error\",\"message\":\"Outer\",\"value\":\"outer value\"}\n");
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, lines, "\n"));
    try testing.expectEqual(@as(u64, 1), s.emergency_written);
    try testing.expectEqual(@as(u64, 1), s.emergency_suppressed);
}
