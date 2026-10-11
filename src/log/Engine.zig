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
    /// Records cut to `max_record_bytes`; they end with "truncated":true.
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
output: options.Output,
/// `,"service.name":"…"…`, written into every JSON record; empty for text.
service: []const u8,
scope_table: scopes.Table,
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
        .output = opts.output,
        .service = service,
        .scope_table = undefined,
    };
    try engine.scope_table.init(opts.level, opts.scopes);
    return engine;
}

pub fn destroy(engine: *Engine) void {
    const gpa = engine.gpa;
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
