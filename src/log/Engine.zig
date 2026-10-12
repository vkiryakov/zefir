//! The engine behind every handle of one logger: the options, the service
//! fragment, the scope table, the output and the counters. It lives on the
//! heap, so handles can point to it.

const std = @import("std");
const encode = @import("encode.zig");
const escape = @import("escape.zig");
const options = @import("options.zig");
const scopes = @import("scopes.zig");
const std_log = @import("std_log.zig");
const Queue = @import("Queue.zig");
const writer = @import("writer.zig");
const rate_limit = @import("emergency.zig");
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
    /// The queue capacity is not a power of two.
    CapacityNotPowerOfTwo,
    /// The writer thread would take no records per write.
    BatchSizeZero,
    /// The writer thread of the queued mode could not be started.
    SystemResources,
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
    /// New scope names that found the scope table full, from `scoped` and
    /// from std.log records; those log without a scope, at the global
    /// level, and each such lookup takes the table's short lock again.
    scopes_overflow: u64,
    /// `scoped` calls whose name was cut to 128 bytes.
    scope_names_truncated: u64,
    /// Queued mode: records in the queue now, and the most it holds.
    queue_depth: u64,
    queue_capacity: u64,
    /// Queued mode: records accepted and not yet written or dropped; after
    /// a `shutdown` that timed out, the records `deinit` drops.
    pending: u64,
    /// Records `emergency` wrote to stderr.
    emergency_written: u64,
    /// `emergency` records left out: past the rate limit (100 at once, then
    /// 100 per second), or logged while an emergency record was being
    /// written on the same thread. The next one written tells how many
    /// with `"suppressed":N`.
    emergency_suppressed: u64,

    pub const Dropped = struct {
        /// Longer than `max_record_bytes` with `.oversize = .drop`.
        oversize: u64,
        /// The write failed, or stdout was already closed.
        write_failed: u64,
        /// Queued mode, `.drop_new`: the queue was full.
        queue_full: u64,
        /// Logged after `shutdown`.
        closed: u64,
        /// Records at `.err` refused because the queue was full or the
        /// logger was shut down; not counted in `queue_full` or `closed`.
        /// The writer thread reports them in the log with one record,
        /// "zefir.log: error records dropped" with `"suppressed":N`;
        /// `shutdown` and `deinit` note on stderr those it could not.
        err: u64,
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
/// Keeps the logger's own stderr lines whole; taken through its own Io.
stderr_lock: Io.Mutex = .init,
/// `emergency`'s rate limit.
bucket: rate_limit.Bucket = .{},
/// The last record broke off mid-line, so the next one starts with '\n'.
/// Guarded by `output_lock` in sync mode; the writer thread's own in
/// queued mode.
torn: bool = false,
/// stdout is closed for good: records are dropped from now on.
dead: std.atomic.Value(bool) = .init(false),
/// Queued mode: the queue, what to do when it is full, and the writer
/// thread with its batch (a line break that may end a torn line, then the
/// records) and the records' ends in it.
queue: ?Queue = null,
overflow: options.OverflowPolicy = .drop_new,
batch: []u8 = &.{},
batch_ends: []usize = &.{},
writer_thread: ?std.Thread = null,
/// Whether a call has joined, or is joining, the writer thread.
writer_joined: std.atomic.Value(bool) = .init(false),
/// Records logged once the logger is not running are refused.
state: std.atomic.Value(State) = .init(.running),
/// Queued mode: queue positions the writer thread has written or dropped.
/// `flush` and `shutdown` wait for it to reach theirs.
processed: Counter = .init(0),
/// Bumped after each batch; `flush` and `shutdown` wait on it.
progress: std.atomic.Value(u32) = .init(0),
progress_waiters: std.atomic.Value(u32) = .init(0),
/// Set by `deinit` after a `shutdown` that timed out: the writer thread
/// stops without writing what is left.
abandon: std.atomic.Value(bool) = .init(false),
/// Error records dropped that no summary has reported yet.
errors_unreported: Counter = .init(0),
counters: Counters = .{},

const State = enum(u8) { running, stopping, stopped };

const Counter = std.atomic.Value(u64);

const Counters = struct {
    accepted: Counter = .init(0),
    written: Counter = .init(0),
    dropped_oversize: Counter = .init(0),
    dropped_write_failed: Counter = .init(0),
    dropped_queue_full: Counter = .init(0),
    dropped_closed: Counter = .init(0),
    dropped_err: Counter = .init(0),
    write_errors: Counter = .init(0),
    truncated: Counter = .init(0),
    torn_lines: Counter = .init(0),
    emergency_written: Counter = .init(0),
    emergency_suppressed: Counter = .init(0),
};

/// Set while this thread writes an emergency record: an emergency call
/// from inside it (a field's `format`) is left out.
threadlocal var emergency_active = false;

fn bump(counter: *Counter) void {
    _ = counter.fetchAdd(1, .monotonic);
}

fn bumpBy(counter: *Counter, n: usize) void {
    if (n != 0) _ = counter.fetchAdd(n, .monotonic);
}

pub fn create(gpa: std.mem.Allocator, io: Io, opts: options.Options) InitError!*Engine {
    if (opts.max_record_bytes > max_record_limit) return error.RecordLimitTooLarge;
    switch (opts.mode) {
        .sync => {},
        .queued => |q| {
            if (q.capacity == 0 or !std.math.isPowerOfTwo(q.capacity)) return error.CapacityNotPowerOfTwo;
            if (q.batch_size == 0) return error.BatchSizeZero;
        },
    }
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
    switch (opts.mode) {
        .sync => {},
        .queued => |q| try engine.startQueue(q, opts.max_record_bytes),
    }
    return engine;
}

/// Allocates the queue and the batch, and starts the writer thread.
fn startQueue(engine: *Engine, q: options.Queued, max_record_bytes: u32) InitError!void {
    const gpa = engine.gpa;
    engine.queue = try Queue.init(gpa, q.capacity, max_record_bytes, engine.own.io());
    errdefer engine.queue.?.deinit(gpa);
    engine.batch = try gpa.alloc(u8, 1 + @as(usize, q.batch_size) * max_record_bytes);
    errdefer gpa.free(engine.batch);
    engine.batch_ends = try gpa.alloc(usize, q.batch_size);
    errdefer gpa.free(engine.batch_ends);
    engine.overflow = q.overflow;
    engine.writer_thread = std.Thread.spawn(.{}, writer.run, .{engine}) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SystemResources,
    };
}

pub fn destroy(engine: *Engine) void {
    std_log.uninstallIf(engine);
    const gpa = engine.gpa;
    if (engine.queue) |*q| {
        // Without a shutdown first, everything accepted is written. After
        // one that timed out, what is left is dropped: only the write in
        // progress is waited for.
        if (engine.state.load(.acquire) == .running) {
            engine.shutdown(.none) catch {};
        } else {
            // seq_cst: pairs with the writer's announcement that it sleeps
            // in `waitForPublish`, so one of the two sees the other.
            engine.abandon.store(true, .seq_cst);
            q.wakeConsumer();
        }
        engine.joinWriter();
        q.deinit(gpa);
        gpa.free(engine.batch);
        gpa.free(engine.batch_ends);
    }
    engine.noteDroppedErrors();
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
            .queue_full = c.dropped_queue_full.load(.monotonic),
            .closed = c.dropped_closed.load(.monotonic),
            .err = c.dropped_err.load(.monotonic),
        },
        .write_errors = c.write_errors.load(.monotonic),
        .truncated = c.truncated.load(.monotonic),
        .torn_lines = c.torn_lines.load(.monotonic),
        .scopes_overflow = engine.scope_table.overflow.load(.monotonic),
        .scope_names_truncated = engine.scope_table.names_truncated.load(.monotonic),
        .queue_depth = if (engine.queue) |*q| q.depth() else 0,
        .queue_capacity = if (engine.queue) |*q| q.mask + 1 else 0,
        .pending = if (engine.queue) |*q| q.reserved() -| engine.processed.load(.monotonic) else 0,
        .emergency_written = c.emergency_written.load(.monotonic),
        .emergency_suppressed = c.emergency_suppressed.load(.monotonic),
    };
}

/// Queued mode: waits until the writer thread has written, or dropped,
/// every record accepted before the call.
pub fn flush(engine: *Engine, timeout: Io.Timeout) error{Timeout}!void {
    if (engine.queue == null) return;
    try engine.refuseOnOwnThread();
    return engine.waitProcessed(engine.queue.?.reserved(), timeout);
}

/// Refuses records from now on; in queued mode waits until the queue is
/// written and the writer thread has exited. After a call that timed out,
/// another one waits again.
pub fn shutdown(engine: *Engine, timeout: Io.Timeout) error{Timeout}!void {
    try engine.refuseOnOwnThread();
    _ = engine.state.cmpxchgStrong(.running, .stopping, .acq_rel, .monotonic);
    if (engine.queue) |*q| {
        try engine.waitProcessed(q.close(), timeout);
        engine.joinWriter();
    }
    engine.state.store(.stopped, .release);
    engine.noteDroppedErrors();
}

/// `flush` and `shutdown` on the writer thread (an output writer that
/// calls them) would wait for that thread itself: a panic in safe builds,
/// `error.Timeout` at once otherwise.
fn refuseOnOwnThread(engine: *const Engine) error{Timeout}!void {
    if (writer.thread_of != engine) return;
    if (std.debug.runtime_safety) @panic("zefir.log: flush or shutdown called from the logger's writer thread would wait for itself");
    return error.Timeout;
}

/// Waits until the writer thread has processed every queue position before
/// `target`, or `timeout` passes.
fn waitProcessed(engine: *Engine, target: u64, timeout: Io.Timeout) error{Timeout}!void {
    const io = engine.own.io();
    // Not a cancelation point: a cancel request for the caller's task stays
    // for the task's own next one.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    const deadline = timeout.toDeadline(io);
    _ = engine.progress_waiters.fetchAdd(1, .seq_cst);
    defer _ = engine.progress_waiters.fetchSub(1, .seq_cst);
    while (true) {
        // Read the epoch first: a batch done after this read bumps it, so
        // the wait below returns at once instead of missing the wake-up.
        const epoch = engine.progress.load(.seq_cst);
        if (engine.processed.load(.seq_cst) >= target) return;
        if (deadline.toDurationFromNow(io)) |left| {
            if (left.raw.nanoseconds <= 0) return error.Timeout;
        }
        io.futexWaitTimeout(u32, &engine.progress.raw, epoch, deadline) catch {};
    }
}

/// For the writer thread: counts `n` more queue positions as written or
/// dropped, and wakes the `flush` and `shutdown` calls waiting for them.
pub fn markProcessed(engine: *Engine, n: usize) void {
    _ = engine.processed.fetchAdd(n, .seq_cst);
    // Bump before reading the waiter count: a waiter that missed the new
    // count either sees the new epoch or is seen here.
    _ = engine.progress.fetchAdd(1, .seq_cst);
    if (engine.progress_waiters.load(.seq_cst) != 0) engine.own.io().futexWake(u32, &engine.progress.raw, std.math.maxInt(u32));
}

fn joinWriter(engine: *Engine) void {
    if (!engine.writer_joined.swap(true, .acq_rel)) engine.writer_thread.?.join();
}

/// Encodes and writes one record; the caller has checked the level.
pub fn emit(engine: *Engine, comptime level: Level, scope: *const scopes.Entry, trace: ?*const encode.TraceHex, comptime message: []const u8, fields: anytype) void {
    if (!engine.accept(level)) return;
    // One byte more than the longest record: room for the '\n' that ends a
    // torn line.
    var buf: [1 + max_record_limit]u8 = undefined;
    const out = buf[1..][0..engine.max_record_bytes];
    const header = engine.headerFor(level, scope, trace);
    const encoded = switch (engine.format) {
        inline else => |format| encode.record(format, level, message, out, header, fields),
    };
    engine.finish(level, &buf, encoded);
}

/// `emit` for a message formatted at run time: the std.log bridge.
pub fn emitFormatted(engine: *Engine, comptime level: Level, scope: *const scopes.Entry, comptime format: []const u8, args: anytype) void {
    if (!engine.accept(level)) return;
    var buf: [1 + max_record_limit]u8 = undefined;
    const out = buf[1..][0..engine.max_record_bytes];
    const header = engine.headerFor(level, scope, null);
    const encoded = switch (engine.format) {
        inline else => |f| encode.recordFormatted(f, level, format, args, out, header),
    };
    engine.finish(level, &buf, encoded);
}

/// Counts a record that passed the level filter; false when the logger is
/// shut down or stdout is closed, and the record is dropped.
fn accept(engine: *Engine, comptime level: Level) bool {
    bump(&engine.counters.accepted);
    if (engine.state.load(.monotonic) != .running) {
        engine.refuse(level, &engine.counters.dropped_closed);
        return false;
    }
    if (!engine.dead.load(.monotonic)) return true;
    bump(&engine.counters.dropped_write_failed);
    return false;
}

/// Counts a record refused because the queue is full or the logger is
/// shut down: in `counter`, or in `dropped.err` for an error record, which
/// a summary then reports.
fn refuse(engine: *Engine, comptime level: Level, counter: *Counter) void {
    if (level != .err) return bump(counter);
    bump(&engine.counters.dropped_err);
    bump(&engine.errors_unreported);
}

fn headerFor(engine: *Engine, comptime level: Level, scope: *const scopes.Entry, trace: ?*const encode.TraceHex) encode.Header {
    return .{
        .timestamp = Io.Clock.real.now(engine.io),
        .service = engine.service,
        .scope = scope.name(),
        .scope_quoted = scope.quoted,
        .source = engine.source_modes[@backingInt(level)],
        .trace = trace,
        .oversize = engine.oversize,
    };
}

/// Writes or queues the record encoded in `buf[1..]`, or counts why there
/// is none.
fn finish(engine: *Engine, comptime level: Level, buf: []u8, encoded: ?encode.Encoded) void {
    const done = encoded orelse return bump(&engine.counters.dropped_oversize);
    if (done.truncated) bump(&engine.counters.truncated);
    if (engine.queue) |*q| return engine.enqueue(level, q, buf[1..][0..done.len]);
    engine.write(buf, done.len);
}

/// Queued mode: copies the record into the queue; the writer thread
/// writes it.
fn enqueue(engine: *Engine, comptime level: Level, q: *Queue, bytes: []const u8) void {
    const pushed = switch (engine.overflow) {
        .drop_new => q.tryPush(bytes),
        .block => q.pushBlocking(bytes),
    };
    pushed catch |e| engine.refuse(level, switch (e) {
        error.Full => &engine.counters.dropped_queue_full,
        error.Closed => &engine.counters.dropped_closed,
    });
}

/// `Logger.emergency`: writes the record to stderr at once, through the
/// logger's own Io, if the rate limit lets it out.
pub fn emergency(engine: *Engine, scope: *const scopes.Entry, trace: ?*const encode.TraceHex, comptime message: []const u8, fields: anytype) void {
    if (emergency_active) {
        engine.bucket.refuse();
        return bump(&engine.counters.emergency_suppressed);
    }
    const io = engine.own.io();
    const left_out = engine.bucket.take(Io.Clock.awake.now(io).nanoseconds) orelse
        return bump(&engine.counters.emergency_suppressed);
    emergency_active = true;
    defer emergency_active = false;
    var buf: [max_record_limit]u8 = undefined;
    const out = buf[0..engine.max_record_bytes];
    var header = engine.headerFor(.err, scope, trace);
    header.timestamp = Io.Clock.real.now(io);
    const done = switch (engine.format) {
        inline else => |f| encodeTelling(f, message, out, header, fields, left_out),
    } orelse {
        engine.bucket.giveBack(left_out);
        return bump(&engine.counters.dropped_oversize);
    };
    if (!done.told) engine.bucket.giveBack(left_out);
    if (done.truncated) bump(&engine.counters.truncated);
    if (engine.writeStderr(out[0..done.len])) bump(&engine.counters.emergency_written);
}

const Told = struct { len: usize, truncated: bool, told: bool };

/// Encodes an error record that tells, with `"suppressed":N`, of the
/// `left_out` records before it, when there are any and it has room for
/// that.
fn encodeTelling(comptime f: options.Format, comptime message: []const u8, out: []u8, header: encode.Header, fields: anytype, left_out: u64) ?Told {
    if (left_out > 0 and out.len > encode.suppressed_max_bytes) {
        if (encode.record(f, .err, message, out[0 .. out.len - encode.suppressed_max_bytes], header, fields)) |done|
            return .{ .len = encode.appendSuppressed(f, out, done.len, left_out), .truncated = done.truncated, .told = true };
    }
    const done = encode.record(f, .err, message, out, header, fields) orelse return null;
    return .{ .len = done.len, .truncated = done.truncated, .told = left_out == 0 };
}

/// For the writer thread: writes the `n` records the queue copied into
/// the batch with one write loop, through the logger's own Io, and counts
/// them.
pub fn writeBatch(engine: *Engine, n: usize) void {
    const ends = engine.batch_ends[0..n];
    if (engine.dead.load(.monotonic)) return bumpBy(&engine.counters.dropped_write_failed, n);
    const lead: usize = @intFromBool(engine.torn);
    engine.batch[0] = '\n';
    const bytes = engine.batch[1 - lead .. 1 + ends[n - 1]];
    var sent: usize = 0;
    engine.writeRetrying(bytes, &sent) catch |e| return engine.failed(e, ends, sent, lead);
    engine.torn = false;
    bumpBy(&engine.counters.written, n);
}

/// For the writer thread: writes one record in place of the error records
/// dropped since the last one, "zefir.log: error records dropped" with
/// `"suppressed":N`. It is the logger's own record, not counted in
/// `written`. While stdout is dead the count waits for `shutdown`.
pub fn reportDroppedErrors(engine: *Engine) void {
    if (engine.errors_unreported.load(.monotonic) == 0 or engine.dead.load(.monotonic)) return;
    const n = engine.errors_unreported.swap(0, .monotonic);
    const out = engine.batch[1..][0..engine.max_record_bytes];
    const header: encode.Header = .{
        .timestamp = Io.Clock.real.now(engine.own.io()),
        .service = engine.service,
        .scope = "",
        .oversize = .truncate,
    };
    const len = switch (engine.format) {
        inline else => |f| blk: {
            const room = out[0 .. out.len - encode.suppressed_max_bytes];
            const done = encode.record(f, .err, "zefir.log: error records dropped", room, header, .{}) orelse break :blk null;
            break :blk encode.appendSuppressed(f, out, done.len, n);
        },
    } orelse {
        _ = engine.errors_unreported.fetchAdd(n, .monotonic);
        return;
    };
    const lead: usize = @intFromBool(engine.torn);
    engine.batch[0] = '\n';
    var sent: usize = 0;
    engine.writeRetrying(engine.batch[1 - lead .. 1 + len], &sent) catch |e| {
        if (e == error.FlushFailed or sent < lead + len) _ = engine.errors_unreported.fetchAdd(n, .monotonic);
        return engine.broke(e, sent, lead);
    };
    engine.torn = false;
}

/// Notes on stderr the error records dropped that no summary in the log
/// reports: those refused once the writer thread was gone, or while stdout
/// was dead.
fn noteDroppedErrors(engine: *Engine) void {
    const n = engine.errors_unreported.swap(0, .monotonic);
    if (n == 0) return;
    var buf: [96]u8 = undefined;
    const note = std.fmt.bufPrint(&buf, "zefir.log: error records dropped and not in the log: {d}\n", .{n}) catch unreachable; // `buf` fits the longest count
    _ = engine.writeStderr(note);
}

/// Writes one of the logger's own lines to stderr, whole, through its own
/// Io; false when the write failed.
fn writeStderr(engine: *Engine, bytes: []const u8) bool {
    const io = engine.own.io();
    // Not a cancelation point, as above: the line goes out, and a cancel
    // request stays.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    engine.stderr_lock.lockUncancelable(io);
    defer engine.stderr_lock.unlock(io);
    engine.stderr.writeStreamingAll(io, bytes) catch return false;
    return true;
}

/// The writer thread's write: a stdout someone made nonblocking gets up to
/// 10 ms of retries before the write fails.
fn writeRetrying(engine: *Engine, bytes: []const u8, sent: *usize) WriteError!void {
    const io = engine.own.io();
    switch (engine.output) {
        .writer => |w| return writeWriter(w, bytes, sent),
        .stdout => for (0..10) |_| {
            writeFile(engine.stdout, io, bytes, sent) catch |e| switch (e) {
                error.WouldBlock => {
                    io.sleep(.fromMilliseconds(1), .awake) catch {};
                    continue;
                },
                else => return e,
            };
            return;
        } else return writeFile(engine.stdout, io, bytes, sent),
    }
}

const WriteError = Io.File.Writer.Error || Io.Writer.Error || error{FlushFailed};

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
    result catch |e| return engine.failed(e, &.{len}, sent, lead);
    engine.torn = false;
    bump(&engine.counters.written);
}

/// Counts a write of the records ending at `ends` that failed after `sent`
/// bytes, `lead` of them a '\n' that ends a torn line: the records sent
/// whole are written, the rest dropped. A record cut mid-line costs that
/// line only: the next record starts with '\n'.
fn failed(engine: *Engine, e: WriteError, ends: []const usize, sent: usize, lead: usize) void {
    var whole: usize = 0;
    // After a failed flush none of the records counts as written.
    if (e != error.FlushFailed) {
        while (whole < ends.len and lead + ends[whole] <= sent) whole += 1;
    }
    bumpBy(&engine.counters.written, whole);
    bumpBy(&engine.counters.dropped_write_failed, ends.len - whole);
    engine.broke(e, sent, lead + if (whole > 0) ends[whole - 1] else 0);
}

/// Counts a write that failed after `sent` bytes, the last whole record
/// in them ending at `boundary`.
fn broke(engine: *Engine, e: WriteError, sent: usize, boundary: usize) void {
    bump(&engine.counters.write_errors);
    if (e == error.FlushFailed or sent > boundary) {
        engine.torn = true;
        bump(&engine.counters.torn_lines);
    } else if (sent > 0) {
        engine.torn = false; // the write stopped between records
    }
    switch (e) {
        error.BrokenPipe, error.NotOpenForWriting => engine.die(e),
        else => {}, // e.g. WouldBlock on a stdout someone made nonblocking: drop these records only
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
    _ = engine.writeStderr(note);
}

/// Writes `bytes` with streaming writes; `File.writer()` would be
/// positional and overwrite the start of a redirected file. On failure
/// `sent` says how much reached the OS.
fn writeFile(file: Io.File, io: Io, bytes: []const u8, sent: *usize) Io.File.Writer.Error!void {
    while (sent.* < bytes.len) sent.* += try file.writeStreaming(io, &.{}, &.{bytes[sent.*..]}, 1);
}

/// Writes and flushes `bytes`. A buffered writer does not tell how much
/// went out when its flush fails: `error.FlushFailed` counts the records as
/// dropped and the line as torn, so the next record starts on a new line.
fn writeWriter(w: *Io.Writer, bytes: []const u8, sent: *usize) (Io.Writer.Error || error{FlushFailed})!void {
    while (sent.* < bytes.len) sent.* += try w.write(bytes[sent.*..]);
    w.flush() catch return error.FlushFailed;
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
    try testing.expectError(error.CapacityNotPowerOfTwo, create(gpa, io, .{ .mode = .{ .queued = .{ .capacity = 1000 } } }));
    try testing.expectError(error.CapacityNotPowerOfTwo, create(gpa, io, .{ .mode = .{ .queued = .{ .capacity = 0 } } }));
    try testing.expectError(error.BatchSizeZero, create(gpa, io, .{ .mode = .{ .queued = .{ .batch_size = 0 } } }));
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
