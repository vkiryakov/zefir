//! The engine behind every handle of one logger: the options, the service
//! fragment, the scope table, the output and the counters. It lives on the
//! heap, so handles can point to it.

const std = @import("std");
const encode = @import("encode.zig");
const escape = @import("escape.zig");
const options = @import("options.zig");
const scopes = @import("scopes.zig");
const Level = @import("level.zig").Level;

const Io = std.Io;
const Engine = @This();
const testing = std.testing;

/// The largest `max_record_bytes`, '\n' included: the line limit of
/// containerd.
pub const max_record_limit = 16 * 1024;
/// The four service fields together.
pub const max_service_bytes = 1024;

pub const InitError = error{
    OutOfMemory,
    /// The service fields together exceed 1 KiB.
    ServiceTooLong,
    /// `max_record_bytes` exceeds 16384.
    RecordLimitTooLarge,
    /// `max_record_bytes` cannot hold what every record has: the time, the
    /// level, the service fields and the longest scope.
    RecordLimitTooSmall,
    /// More than 64 scope rules.
    TooManyRules,
    /// A scope rule with an empty prefix.
    EmptyPrefix,
};

/// What a logger has done since `init`.
pub const Stats = struct {
    /// Records that passed the level filter.
    accepted: u64,
    /// Records that reached the output in full.
    written: u64,
    dropped: Dropped,
    /// Write calls that failed.
    write_errors: u64,
    /// Records cut to `max_record_bytes`; they end with "truncated":true
    /// (` truncated=true` in text).
    truncated: u64,
    /// Records that broke off mid-line because a write failed; the next
    /// record starts on a new line.
    torn_lines: u64,
    /// `scoped` calls that found the scope table full; those handles log
    /// without a scope, at the global level.
    scopes_overflow: u64,
    /// `scoped` calls whose name was cut to 128 bytes.
    scope_names_truncated: u64,

    pub const Dropped = struct {
        /// Longer than `max_record_bytes` with `.oversize = .drop`.
        oversize: u64,
        /// The write failed, or stdout was already closed.
        write_failed: u64,
    };
};

gpa: std.mem.Allocator,
io: Io,
format: options.Format,
max_record_bytes: u32,
oversize: options.OversizePolicy,
/// The call-site mode of each level, by `@backingInt(level)`.
source_modes: [level_count]options.SourceMode,
output: options.Output,
/// `,"service.name":"…"…`, written into every JSON record; empty for text.
service: []const u8,
scope_table: scopes.Table,
/// What `.stdout` writes to; tests point it at a pipe.
stdout: Io.File,
output_lock: Io.Mutex = .init,
/// The logger's own Io, for the stderr note about a closed stdout, so the
/// note never depends on the application's Io.
own: Io.Threaded = .init_single_threaded,
/// Where that note goes; tests point it at a pipe.
stderr: Io.File,
/// The last record broke off mid-line, so the next one starts with '\n'.
/// Guarded by `output_lock`.
torn: bool = false,
/// stdout is closed for good: records are dropped from now on.
dead: std.atomic.Value(bool) = .init(false),
counters: Counters = .{},

const Counter = std.atomic.Value(u64);

const Counters = struct {
    accepted: Counter = .init(0),
    written: Counter = .init(0),
    dropped_oversize: Counter = .init(0),
    dropped_write_failed: Counter = .init(0),
    write_errors: Counter = .init(0),
    truncated: Counter = .init(0),
    torn_lines: Counter = .init(0),
};

fn bump(counter: *Counter) void {
    _ = counter.fetchAdd(1, .monotonic);
}

pub fn create(gpa: std.mem.Allocator, io: Io, opts: options.Options) InitError!*Engine {
    if (opts.max_record_bytes > max_record_limit) return error.RecordLimitTooLarge;
    if (serviceBytes(opts.service) > max_service_bytes) return error.ServiceTooLong;
    const service: []const u8 = if (opts.format == .json) try encodeService(gpa, opts.service) else &.{};
    errdefer gpa.free(service);
    if (opts.max_record_bytes < encode.mandatoryBytes(opts.format, service.len, scopes.max_name_bytes))
        return error.RecordLimitTooSmall;
    const engine = try gpa.create(Engine);
    errdefer gpa.destroy(engine);
    engine.* = .{
        .gpa = gpa,
        .io = io,
        .format = opts.format,
        .max_record_bytes = opts.max_record_bytes,
        .oversize = opts.oversize,
        .source_modes = sourceModes(opts.source),
        .output = opts.output,
        .service = service,
        .scope_table = undefined,
        .stdout = .stdout(),
        .stderr = .stderr(),
    };
    try engine.scope_table.init(opts.level, opts.scopes);
    return engine;
}

pub fn destroy(engine: *Engine) void {
    const gpa = engine.gpa;
    engine.own.deinit();
    gpa.free(engine.service);
    gpa.destroy(engine);
}

pub fn stats(engine: *Engine) Stats {
    const c = &engine.counters;
    return .{
        .accepted = c.accepted.load(.monotonic),
        .written = c.written.load(.monotonic),
        .dropped = .{
            .oversize = c.dropped_oversize.load(.monotonic),
            .write_failed = c.dropped_write_failed.load(.monotonic),
        },
        .write_errors = c.write_errors.load(.monotonic),
        .truncated = c.truncated.load(.monotonic),
        .torn_lines = c.torn_lines.load(.monotonic),
        .scopes_overflow = engine.scope_table.overflow.load(.monotonic),
        .scope_names_truncated = engine.scope_table.names_truncated.load(.monotonic),
    };
}

/// Encodes and writes one record; the caller has checked the level.
pub fn emit(engine: *Engine, comptime level: Level, scope: *const scopes.Entry, trace: ?*const encode.TraceHex, comptime message: []const u8, fields: anytype) void {
    bump(&engine.counters.accepted);
    if (engine.dead.load(.monotonic)) return bump(&engine.counters.dropped_write_failed);
    // One byte more than the longest record: room for the '\n' that ends a
    // torn line.
    var buf: [1 + max_record_limit]u8 = undefined;
    const header: encode.Header = .{
        .timestamp = Io.Clock.real.now(engine.io),
        .service = engine.service,
        .scope = scope.name(),
        .scope_quoted = scope.quoted,
        .source = engine.source_modes[@backingInt(level)],
        .trace = trace,
        .oversize = engine.oversize,
    };
    const out = buf[1..][0..engine.max_record_bytes];
    const encoded = switch (engine.format) {
        inline else => |format| encode.record(format, level, message, out, header, fields),
    } orelse return bump(&engine.counters.dropped_oversize);
    if (encoded.truncated) bump(&engine.counters.truncated);
    engine.write(&buf, encoded.len);
}

const WriteError = Io.File.Writer.Error || Io.Writer.Error;

/// Writes the record in `buf[1..][0..len]` under the output lock, through
/// the application's Io. `buf[0]` is free for the '\n' that ends a torn
/// line.
fn write(engine: *Engine, buf: []u8, len: usize) void {
    const io = engine.io;
    // A log call is never a cancelation point: the record goes out whole.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    engine.output_lock.lockUncancelable(io);
    defer engine.output_lock.unlock(io);

    const lead: usize = @intFromBool(engine.torn);
    buf[0] = '\n';
    const bytes = buf[1 - lead .. 1 + len];
    var sent: usize = 0;
    const result = switch (engine.output) {
        .stdout => writeFile(engine.stdout, io, bytes, &sent),
        .writer => |w| writeWriter(w, bytes, &sent),
    };
    result catch |e| return engine.failed(e, sent, lead);
    engine.torn = false;
    bump(&engine.counters.written);
}

/// Counts a failed write. A record cut mid-line costs that line only: the
/// next record starts with '\n'.
fn failed(engine: *Engine, e: WriteError, sent: usize, lead: usize) void {
    bump(&engine.counters.write_errors);
    bump(&engine.counters.dropped_write_failed);
    if (sent > lead) {
        engine.torn = true;
        bump(&engine.counters.torn_lines);
    } else if (sent > 0) {
        engine.torn = false; // only the '\n' that ends the previous torn line went out
    }
    switch (e) {
        error.BrokenPipe, error.NotOpenForWriting => engine.die(e),
        else => {}, // e.g. WouldBlock on a stdout someone made nonblocking: drop this record only
    }
}

/// stdout is closed: drop every record from now on, and say so on stderr
/// once, through the logger's own Io.
fn die(engine: *Engine, e: WriteError) void {
    if (engine.dead.swap(true, .monotonic)) return;
    const note = switch (e) {
        error.BrokenPipe => "zefir.log: stdout is closed (BrokenPipe); dropping the records that follow\n",
        else => "zefir.log: stdout is not open for writing (NotOpenForWriting); dropping the records that follow\n",
    };
    engine.stderr.writeStreamingAll(engine.own.io(), note) catch {};
}

/// Writes `bytes` with streaming writes; `File.writer()` would be
/// positional and overwrite the start of a redirected file. On failure
/// `sent` says how much reached the OS.
fn writeFile(file: Io.File, io: Io, bytes: []const u8, sent: *usize) Io.File.Writer.Error!void {
    while (sent.* < bytes.len) sent.* += try file.writeStreaming(io, &.{}, &.{bytes[sent.*..]}, 1);
}

/// Writes and flushes `bytes`. A failed flush counts all of them as sent:
/// a buffered writer does not tell how much went out.
fn writeWriter(w: *Io.Writer, bytes: []const u8, sent: *usize) Io.Writer.Error!void {
    while (sent.* < bytes.len) sent.* += try w.write(bytes[sent.*..]);
    w.flush() catch |e| {
        sent.* = bytes.len;
        return e;
    };
}

const level_count = std.enums.values(Level).len;

fn sourceModes(source: options.SourceOptions) [level_count]options.SourceMode {
    var modes: [level_count]options.SourceMode = undefined;
    for (std.enums.values(Level)) |level| modes[@backingInt(level)] = source.mode(level);
    return modes;
}

const service_keys = [_][]const u8{ "service.name", "service.instance.id", "service.version", "deployment.environment.name" };

fn serviceValues(service: options.Service) [4]?[]const u8 {
    return .{ service.name, service.instance_id, service.version, service.environment };
}

fn serviceBytes(service: options.Service) usize {
    var total: usize = 0;
    for (serviceValues(service)) |value| total += if (value) |v| v.len else 0;
    return total;
}

/// The service fields as one JSON fragment, encoded once at init.
fn encodeService(gpa: std.mem.Allocator, service: options.Service) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (service_keys, serviceValues(service)) |name, value| {
        const v = value orelse continue;
        if (v.len == 0) continue;
        out.writer.print(",\"{s}\":\"", .{name}) catch return error.OutOfMemory;
        escape.write(&out.writer, v) catch return error.OutOfMemory;
        out.writer.writeByte('"') catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

test "create checks the options" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testing.expectError(error.RecordLimitTooLarge, create(gpa, io, .{ .max_record_bytes = max_record_limit + 1 }));
    try testing.expectError(error.RecordLimitTooSmall, create(gpa, io, .{ .max_record_bytes = 100 }));
    try testing.expectError(error.ServiceTooLong, create(gpa, io, .{ .service = .{ .name = &@as([1025]u8, @splat('n')) } }));
    try testing.expectError(error.EmptyPrefix, create(gpa, io, .{ .scopes = &.{.{ .prefix = "", .level = .debug }} }));
    var rules: [scopes.max_rules + 1]options.ScopeRule = undefined;
    var names: [scopes.max_rules + 1][8]u8 = undefined;
    for (&rules, &names, 0..) |*rule, *name, i| rule.* = .{ .prefix = try std.fmt.bufPrint(name, "r{d}", .{i}), .level = .debug };
    try testing.expectError(error.TooManyRules, create(gpa, io, .{ .scopes = &rules }));
    const largest = try create(gpa, io, .{ .max_record_bytes = max_record_limit });
    largest.destroy();
}

test "the service fragment: OpenTelemetry names, fixed order, empty fields left out" {
    const json = try create(testing.allocator, testing.io, .{ .service = .{
        .name = "user \"svc\"",
        .instance_id = "",
        .version = "1.0.0",
        .environment = "prod",
    } });
    defer json.destroy();
    try testing.expectEqualStrings(",\"service.name\":\"user \\\"svc\\\"\",\"service.version\":\"1.0.0\",\"deployment.environment.name\":\"prod\"", json.service);
    const text = try create(testing.allocator, testing.io, .{ .format = .text, .service = .{ .name = "svc" } });
    defer text.destroy();
    try testing.expectEqualStrings("", text.service);
}

test "create frees what it took when an allocation fails" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        const engine = create(failing.allocator(), testing.io, .{ .service = .{ .name = "svc", .version = "1.0.0" } }) catch |e| {
            try testing.expectEqual(@as(InitError, error.OutOfMemory), e);
            continue;
        };
        engine.destroy();
        break;
    }
}
