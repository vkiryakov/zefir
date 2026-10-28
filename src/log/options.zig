//! Logger options. Every field has a default. confy can read the service
//! and the level from the application's configuration, and the scope rules
//! from a JSON file only: no environment variable, `.env` or INI file holds
//! a list of structs. `Options` itself cannot be a field of the
//! configuration, as its mode and output are unions, which confy does not
//! read: read the parts and pass them to `init`.

const std = @import("std");
const Level = @import("level.zig").Level;

pub const Options = struct {
    /// Service fields, written into every JSON record.
    service: Service = .{},
    /// The global threshold: records below it are not written.
    level: Level = .info,
    /// Initial levels of scopes; change them later with `setScopeLevel`.
    scopes: []const ScopeRule = &.{},
    format: Format = .json,
    /// `.sync` (the default) or `.{ .queued = .{} }`, the mode for services.
    mode: Mode = .sync,
    /// How much of the call site, `.src = @src()`, records write per level.
    source: SourceOptions = .{},
    /// The longest record, '\n' included: at most 16384, and at least 304
    /// in JSON plus the service fields as JSON writes them
    /// (`,"service.name":"api"` adds 21), or 250 in text. Longer records
    /// are cut or dropped, see `oversize`.
    max_record_bytes: u32 = 4096,
    oversize: OversizePolicy = .truncate,
    output: Output = .stdout,

    /// The memory `init` takes for the queue in queued mode: `capacity`
    /// slots of `max_record_bytes` + 16 bytes rounded up to 128, and one
    /// batch of `batch_size` records with their ends. None in sync mode.
    /// Saturates at the largest `usize`, which no allocator can give.
    pub fn queueBytes(o: Options) usize {
        const q = switch (o.mode) {
            .sync => return 0,
            .queued => |q| q,
        };
        const slot = std.mem.alignForward(u64, @as(u64, o.max_record_bytes) + 16, 128);
        const total = @as(u64, q.capacity) *| slot +| 1 +| @as(u64, q.batch_size) *| (@as(u64, o.max_record_bytes) + @sizeOf(usize));
        return std.math.cast(usize, total) orelse std.math.maxInt(usize);
    }
};

/// The bytes one queue slot takes: a 16-byte header and the record,
/// rounded up to 128 so that two slots never share a cache line.
pub fn slotSize(max_record_bytes: u32) usize {
    return std.mem.alignForward(usize, @as(usize, max_record_bytes) + 16, 128);
}

pub const Mode = union(enum) {
    /// Each call writes its record before it returns, through the
    /// application's `io`: simple, and a record is out even if the process
    /// dies right after.
    sync,
    /// Each call copies its record into a queue: no lock, and no system
    /// call unless a logger thread (the writer, or a subscriber's) sleeps
    /// and has to be woken, which at low rates is almost every record. A
    /// producer stopped between taking a slot and filling it holds back
    /// the records after it. A writer thread writes the queue in batches:
    /// callers do not wait for the output, only, with `.overflow = .block`,
    /// for room in the queue. The mode for services; `flush` and `shutdown`
    /// drain it.
    queued: Queued,
};

pub const Queued = struct {
    /// Records the queue holds; a power of two, at least 2. Each takes a slot of
    /// `max_record_bytes` + 16 bytes, rounded up to 128: with 4 KiB
    /// records the default takes 17 MiB (see `Options.queueBytes`). It is
    /// the burst the logger absorbs while the output is stuck; past it,
    /// records are dropped or wait, by `overflow`.
    capacity: u32 = 4096,
    /// Records the writer thread takes for one write. With a slow output
    /// fewer, larger writes keep up longer; past 128 the benchmark gains
    /// little.
    batch_size: u32 = 128,
    overflow: OverflowPolicy = .drop_new,
};

pub const OverflowPolicy = enum {
    /// A record that finds the queue full is dropped and counted; the
    /// caller never waits.
    drop_new,
    /// The caller waits for room. That blocks an OS thread, so it is not
    /// for event loops, zio tasks or RPC workers.
    block,
};

/// OpenTelemetry resource fields; empty ones are not written. All four
/// together may take at most 1 KiB.
pub const Service = struct {
    /// Written as `service.name`.
    name: ?[]const u8 = null,
    /// Written as `service.instance.id`.
    instance_id: ?[]const u8 = null,
    /// Written as `service.version`.
    version: ?[]const u8 = null,
    /// Written as `deployment.environment.name`.
    environment: ?[]const u8 = null,
};

/// The level of one scope and its subscopes: `zefir.rpc` covers `zefir.rpc`
/// and `zefir.rpc.server`, not `zefir.rpcx`. The longest matching prefix
/// wins.
pub const ScopeRule = struct {
    prefix: []const u8,
    level: Level,
};

pub const Format = enum {
    /// One JSON object per line.
    json,
    /// One line per record for people:
    /// `2026-10-10T21:08:00.123Z INFO  [users] User created user_id=42`.
    text,
};

pub const SourceMode = enum {
    /// Leave the call site out.
    none,
    /// `"source":{"file":"users.zig","line":84}`; in text `src=users.zig:84`.
    file_line,
    /// Also the column, the function and the module; in text
    /// `src=users.zig:84:5 src.function=create src.module=app`.
    full,
};

/// The call-site mode of each level; a level without its own uses
/// `default`. Only records that pass `.src = @src()` have a call site.
pub const SourceOptions = struct {
    default: SourceMode = .file_line,
    trace: ?SourceMode = null,
    debug: ?SourceMode = null,
    info: ?SourceMode = null,
    warn: ?SourceMode = null,
    err: ?SourceMode = null,

    /// The mode records at `level` use.
    pub fn mode(o: SourceOptions, level: Level) SourceMode {
        const own = switch (level) {
            .trace => o.trace,
            .debug => o.debug,
            .info => o.info,
            .warn => o.warn,
            .err => o.err,
        };
        return own orelse o.default;
    }
};

pub const OversizePolicy = enum {
    /// Cut the message and leave out the fields that do not fit, and the
    /// call site when not even the message cut to "…" leaves room for it;
    /// end the record with `"truncated":true` (` truncated=true` in text).
    truncate,
    /// Drop the whole record and count it: in `dropped.oversize`, an error
    /// record in `dropped.err`, reported like the other error records the
    /// logger drops, and an emergency record in `emergency_suppressed`. No
    /// interceptor or subscriber gets it: there is no line to give them.
    drop,
};

pub const Output = union(enum) {
    /// The process's standard output.
    stdout,
    /// A writer the application owns, for tests and embedding. It must
    /// outlive the logger. Each write is flushed: one record per write in
    /// sync mode, a batch of records in queued mode, from the writer
    /// thread. The logger calls it from one thread at a time, so it need
    /// not be thread-safe, but it must not log through the same logger
    /// (that call could wait for itself) or call its `flush` or `shutdown`.
    /// The writer thread is an OS thread of the logger's, not a task of your
    /// zio runtime: in queued mode a writer that does I/O, such as a
    /// `File.Writer`, is made with `init.io`, the `io` that
    /// `main(init: std.process.Init)` gets, which serves any thread. A
    /// writer with a buffer does not tell how much went out when a write or
    /// its flush fails: the records of that write are then counted as
    /// dropped, and the next record starts on a new line.
    writer: *std.Io.Writer,
};

test "defaults: JSON to stdout at info, 4 KiB records, cut when longer" {
    const o: Options = .{};
    try std.testing.expectEqual(Level.info, o.level);
    try std.testing.expectEqual(Format.json, o.format);
    try std.testing.expectEqual(@as(u32, 4096), o.max_record_bytes);
    try std.testing.expectEqual(OversizePolicy.truncate, o.oversize);
    try std.testing.expect(o.output == .stdout);
    try std.testing.expectEqual(@as(usize, 0), o.scopes.len);
    try std.testing.expectEqual(@as(?[]const u8, null), o.service.name);
    try std.testing.expectEqual(SourceMode.file_line, o.source.mode(.info));
}

test "queued mode: defaults and the memory init takes for it" {
    const o: Options = .{ .mode = .{ .queued = .{} } };
    try std.testing.expectEqual(@as(u32, 4096), o.mode.queued.capacity);
    try std.testing.expectEqual(@as(u32, 128), o.mode.queued.batch_size);
    try std.testing.expectEqual(OverflowPolicy.drop_new, o.mode.queued.overflow);
    // 4096 slots of 4096 + 16 bytes rounded up to 128, and one batch of 128
    // records (and the line break that may lead it) with their ends.
    try std.testing.expectEqual(@as(usize, 4096 * 4224 + 1 + 128 * (4096 + @sizeOf(usize))), o.queueBytes());
    try std.testing.expectEqual(@as(usize, 0), (Options{}).queueBytes());
    try std.testing.expectEqual(@as(usize, 384), slotSize(300));
    // Sizes no machine has saturate instead of overflowing.
    const huge: Options = .{ .mode = .{ .queued = .{ .capacity = 1 << 31, .batch_size = std.math.maxInt(u32) } }, .max_record_bytes = std.math.maxInt(u32) };
    try std.testing.expectEqual(@as(usize, std.math.maxInt(usize)), huge.queueBytes());
}

test "a level's own source mode outranks the default" {
    const s: SourceOptions = .{ .default = .none, .err = .full, .debug = .file_line };
    try std.testing.expectEqual(SourceMode.none, s.mode(.info));
    try std.testing.expectEqual(SourceMode.full, s.mode(.err));
    try std.testing.expectEqual(SourceMode.file_line, s.mode(.debug));
}
