//! Subscribers and interceptors. A subscriber gets copies of the records
//! it asked for on a thread of its own, through a queue of its own, so a
//! slow alert never holds up a caller. An interceptor sees each record at
//! the caller, after it is encoded, and may drop it.

const std = @import("std");
const encode = @import("encode.zig");
const scopes = @import("scopes.zig");
const writer = @import("writer.zig");
const Queue = @import("Queue.zig");
const Engine = @import("Engine.zig");
const Level = @import("level.zig").Level;

const Io = std.Io;

/// Subscribers a logger takes in its life, the unsubscribed ones included.
pub const max_subscribers = 8;
/// Interceptors a logger takes in its life; none can be removed.
pub const max_interceptors = 8;

/// A record as subscribers and interceptors see it. It is valid only
/// during the call: copy what you keep.
pub const Event = struct {
    level: Level,
    /// When the record was logged.
    timestamp: Io.Timestamp,
    /// The scope as the record writes it, escaped; empty without one.
    scope: []const u8,
    /// The message as the record writes it: escaped, and cut when the
    /// record is.
    message: []const u8,
    /// Lowercase hex, when the record has a trace.
    trace_id: ?[]const u8 = null,
    span_id: ?[]const u8 = null,
    /// The whole record in the logger's format, without its final '\n':
    /// what goes to the output, redacted as the output is. Redaction does
    /// not reach into std.log text or the text a type's `format` writes
    /// (but for a `std.Uri`'s password).
    line: []const u8,
};

pub const Handler = *const fn (context: ?*anyopaque, event: *const Event) anyerror!void;

pub const Subscription = struct {
    /// The levels it gets, e.g. `&.{.err}`.
    levels: []const Level,
    /// Only records of this scope and its subscopes (`zefir.rpc` covers
    /// `zefir.rpc.server`, not `zefir.rpcx`); null for any record.
    scope: ?[]const u8 = null,
    /// Records its queue holds: a power of two, at least 2. A record that
    /// finds it full is dropped and counted in `stats().alert_dropped`.
    capacity: u32 = 256,
    /// Passed to `handler` as is.
    context: ?*anyopaque = null,
    /// Runs on the subscriber's own thread, one record at a time, so it
    /// may take its time: a network call, with its own timeout. That thread
    /// is the logger's, not a task of the application's `io`: under an
    /// evented `io`, make the handler's calls through an `Io` that serves
    /// any thread, such as a `std.Io.Threaded` of its own (deinit it after
    /// `unsubscribe`). An error is counted in `stats().alert_failures`; the
    /// record is not retried. It may log through the logger: what it logs
    /// on its own thread goes to the output only, never to subscribers (in
    /// sync mode under an application Io that is not a `std.Io.Threaded` it
    /// is dropped, see `stats().hook_errors`). Threads and Io tasks it hands
    /// work to (`io.async`, `io.concurrent`, a worker of the application's)
    /// log like any caller, so their error records reach the subscribers
    /// again and can loop: log such a failure from the handler after
    /// `await`, or return it. It must not call `unsubscribe`, `flush` or
    /// `shutdown`: that panics in safe builds.
    handler: Handler,
};

pub const SubscriptionId = enum(u8) { _ };

pub const SubscribeError = error{
    /// The logger has taken 8 subscribers in its life.
    TooManySubscribers,
    CapacityNotPowerOfTwo,
    /// A queue holds at least 2 records.
    CapacityTooSmall,
    /// An empty scope; null stands for every scope.
    EmptyPrefix,
    /// The logger is shut down.
    ShutDown,
    OutOfMemory,
    /// The subscriber's thread could not be started.
    SystemResources,
};

pub const Interceptor = struct {
    /// Passed to `filter` as is. An interceptor cannot be removed, so this,
    /// and whatever `filter` reads, must outlive the logger.
    context: ?*anyopaque = null,
    /// Runs at the caller for each record that passes the level filter,
    /// once it is encoded (a record too long for `.oversize = .drop` never
    /// is), in the order the interceptors were added; false drops the
    /// record, counted in `stats().filtered`. It must not block or log: a
    /// record logged from it is dropped and counted in
    /// `stats().hook_errors`.
    filter: *const fn (context: ?*anyopaque, event: *const Event) bool,
};

/// Set while this thread runs interceptors: a record logged from one is
/// dropped.
pub threadlocal var in_interceptor = false;
/// The engine whose subscriber thread this is: its records skip the
/// subscribers, and it must not stop them.
pub threadlocal var subscriber_of: ?*const Engine = null;

/// What a subscriber's queue keeps of a record besides the record itself.
const Head = struct {
    timestamp: Io.Timestamp,
    scope: *const scopes.Entry,
    message: encode.Span,
    trace: ?encode.TraceHex,
    level: Level,
};

/// The bytes a subscriber's queue slot takes beyond the record.
pub const head_bytes = @sizeOf(Head);

pub fn levelBit(level: Level) u8 {
    return @as(u8, 1) << @intCast(@backingInt(level));
}

pub const Subscriber = struct {
    engine: *Engine,
    levels: u8,
    /// The scope prefix as scope names are kept; `prefix_len == 0` for
    /// every scope.
    prefix: [scopes.max_name_bytes]u8,
    prefix_len: u8,
    context: ?*anyopaque,
    handler: Handler,
    queue: Queue,
    /// One record as `pop` copies it out: its head, then the record.
    record: []u8,
    thread: Engine.Joinable = .{},
    /// Cleared by `unsubscribe`: records stop going to it.
    active: std.atomic.Value(bool) = .init(true),
    /// Set when the subscriber must stop after the call in hand, without
    /// the records still queued: by `unsubscribe` once `shutdown` has
    /// begun, and by `deinit` after a `shutdown` that timed out.
    stop: std.atomic.Value(bool) = .init(false),

    pub fn wants(s: *const Subscriber, level: Level, scope: []const u8) bool {
        if (s.levels & levelBit(level) == 0 or !s.active.load(.acquire)) return false;
        return s.prefix_len == 0 or scopes.covers(s.prefix[0..s.prefix_len], scope);
    }

    /// Copies the record into the subscriber's queue, or counts why not.
    pub fn offer(s: *Subscriber, level: Level, scope: *const scopes.Entry, header: encode.Header, encoded: encode.Encoded, record: []const u8) void {
        const head: Head = .{
            .timestamp = header.timestamp,
            .scope = scope,
            .message = encoded.message,
            .trace = if (header.trace) |trace| trace.* else null,
            .level = level,
        };
        s.queue.tryPushParts(&.{ std.mem.asBytes(&head), record }) catch |e| switch (e) {
            error.Full => s.engine.countAlertDropped(),
            error.Closed => {}, // being unsubscribed
        };
    }

    /// The subscriber's thread: hands each record to the handler until the
    /// queue is closed and drained, or the logger gives up on it.
    pub fn run(s: *Subscriber) void {
        subscriber_of = s.engine;
        defer s.engine.subscriberExited();
        const q = &s.queue;
        var ends: [1]usize = undefined;
        var yields: u32 = 0;
        while (!s.stop.load(.acquire)) {
            if (q.pop(s.record, &ends) == 1) {
                yields = 0;
                s.deliver(s.record[0..ends[0]]);
                continue;
            }
            if (!q.waitNext(writer.idle_recheck, &yields, &s.stop)) return;
        }
    }

    fn deliver(s: *Subscriber, bytes: []const u8) void {
        const head = std.mem.bytesToValue(Head, bytes[0..head_bytes]);
        const record = bytes[head_bytes .. bytes.len - 1]; // without the '\n'
        const event: Event = .{
            .level = head.level,
            .timestamp = head.timestamp,
            .scope = head.scope.name(),
            .message = record[head.message.start..][0..head.message.len],
            .trace_id = if (head.trace) |*trace| &trace.trace_id else null,
            .span_id = if (head.trace) |*trace| &trace.span_id else null,
            .line = record,
        };
        s.handler(s.context, &event) catch s.engine.countAlertFailure();
    }
};

/// The subscribers and interceptors of one logger. Both lists only grow:
/// a slot below its count is set for good, so a caller reads them with one
/// load and no lock.
pub const Registry = struct {
    subscribers: [max_subscribers]Subscriber = undefined,
    subscriber_count: std.atomic.Value(u32) = .init(0),
    /// The levels some active subscriber gets, a bit per level: records of
    /// other levels cost one load and an AND.
    levels: std.atomic.Value(u8) = .init(0),
    interceptors: [max_interceptors]Interceptor = undefined,
    interceptor_count: std.atomic.Value(u32) = .init(0),
    /// Held while subscribers or interceptors are added or removed; taken
    /// through the logger's own Io.
    lock: Io.Mutex = .init,
    /// Subscriber threads still running; `shutdown` waits for none.
    live: std.atomic.Value(u32) = .init(0),

    pub fn subscriberSlots(r: *Registry) []Subscriber {
        return r.subscribers[0..r.subscriber_count.load(.acquire)];
    }

    pub fn activeInterceptors(r: *const Registry) []const Interceptor {
        return r.interceptors[0..r.interceptor_count.load(.acquire)];
    }

    /// Whether a record at `level` goes to a subscriber; never from a
    /// subscriber's own thread.
    pub fn wanted(r: *const Registry, engine: *const Engine, level: Level) bool {
        return r.levels.load(.acquire) & levelBit(level) != 0 and subscriber_of != engine;
    }

    /// Sets `levels` from the active subscribers; the lock is held.
    pub fn recomputeLevels(r: *Registry) void {
        var mask: u8 = 0;
        for (r.subscriberSlots()) |*s| {
            if (s.active.load(.acquire)) mask |= s.levels;
        }
        r.levels.store(mask, .release);
    }
};

/// The event of a record a caller has just encoded.
pub fn eventOf(level: Level, scope: *const scopes.Entry, header: encode.Header, encoded: encode.Encoded, record: []const u8) Event {
    const line = record[0 .. record.len - 1];
    return .{
        .level = level,
        .timestamp = header.timestamp,
        .scope = scope.name(),
        .message = line[encoded.message.start..][0..encoded.message.len],
        .trace_id = if (header.trace) |trace| &trace.trace_id else null,
        .span_id = if (header.trace) |trace| &trace.span_id else null,
        .line = line,
    };
}

test "a level has one bit" {
    try std.testing.expectEqual(@as(u8, 1), levelBit(.trace));
    try std.testing.expectEqual(@as(u8, 16), levelBit(.err));
}
