//! What `scheduler.Worker(Jobs)` does, without its type parameter: the
//! settings, the state and the counters, and from the start on the poll
//! task, the slot tasks and the stop. `Worker(Jobs)` hands it its jobs as
//! entries, each with its policy and its run behind function pointers.
//! Internal to the module.

const std = @import("std");
const Io = std.Io;
const Duration = Io.Duration;
const Allocator = std.mem.Allocator;
const Diagnostics = @import("../Diagnostics.zig");
const Instant = @import("../Instant.zig");
const Store = @import("../Store.zig");
const record = @import("../record.zig");
const Context = @import("../Context.zig").Context;
const Policy = @import("policy.zig").Policy;
const Stats = @import("stats.zig").Stats;
const Counters = @import("stats.zig").Counters;

const Engine = @This();

pub const Options = struct {
    /// How many jobs this instance runs at once.
    workers: u16 = 10,
    /// How long a claim lives without a renewal, by the store's clock.
    lease: Duration = .fromSeconds(60),
    /// How often a running job renews its lease; `init` wants `lease` more
    /// than twice this.
    renew_every: Duration = .fromSeconds(20),
    /// How often to ask the store when it did not say when the next job
    /// is due.
    poll_every: Duration = .fromSeconds(1),
    /// The deadline of each call of the store.
    store_timeout: Duration = .fromSeconds(5),
    /// How long the running jobs go on after a stop is asked for.
    shutdown_grace: Duration = .fromSeconds(10),
    /// How long `start` waits for the records of the declared jobs.
    start_timeout: Duration = .fromSeconds(10),
    /// The longest pause of the poll while the store fails.
    max_backoff: Duration = .fromSeconds(30),
    /// How long in a row a job may stay unreadable for every instance that
    /// claims it before it ends `failed`. Longer than the longest rollout.
    unreadable_limit: Duration = .fromSeconds(60 * 60),
    /// The name of this instance in logs and records, 1–64 bytes of UTF-8
    /// without NUL; the worker adds 16 random bytes in hex: "shop/7f3a…".
    instance: []const u8 = "worker",
    /// Why `init` refused the settings.
    diagnostics: ?*Diagnostics = null,
};

/// Where a worker is: built, starting, running, stopping (no new claims,
/// the runs end), stopped.
pub const State = enum(u8) { configured, starting, running, draining, stopped };
pub const InitError = error{ InvalidArgument, OutOfMemory };
pub const StartError = Store.StoreError || error{ InvalidState, ConcurrencyUnavailable, Contended };
pub const WaitError = error{ InvalidState, Canceled };
pub const ShutdownError = error{ ShutdownTimeout, Canceled };

/// A job of the worker behind function pointers.
pub const Entry = struct {
    policy: Policy,
    /// The name of the job's type, for the hints of the logs.
    type_name: []const u8,
    job: *anyopaque,
    /// The payload of a run, read from its JSON into `arena`.
    read: *const fn (arena: Allocator, json: []const u8) Read,
    /// The job's `run`, with what `read` gave.
    call: *const fn (job: *anyopaque, ctx: *Context, payload: *const anyopaque) anyerror!void,
    /// The record a declared job wants; null without `.repeat`.
    wanted: ?*const fn (arena: Allocator, now: Instant, life: record.Life) error{ OutOfMemory, InvalidArgument }!Store.CreateRequest,
};

pub const Read = union(enum) {
    payload: *const anyopaque,
    /// The JSON does not read as the job's `Payload`.
    unreadable,
    out_of_memory,
};

gpa: Allocator,
io: Io,
store: Store,
options: Options,
/// "<options.instance>/<32 hex>", the owner of every claim.
instance: []u8,
/// The names of the jobs that a claim takes with any key, and only with
/// a key (`declared.split`).
any_key: []const []const u8,
keyed_only: []const []const u8,
/// What `start` hands over; nothing reads it before.
entries: []const Entry = &.{},

/// Guards the fields below it that are no atomics, for short sections
/// without a call of the store, a wait or a log line.
mutex: Io.Mutex = .init,
state_value: std.atomic.Value(State) = .init(.configured),
/// The address of the worker since `start`: a moved worker panics.
home: std.atomic.Value(usize) = .init(0),
/// Tasks inside `wait`, `run` or `shutdown`: `deinit` panics while any is.
in_calls: std.atomic.Value(u32) = .init(0),
/// Set once the worker stopped: every task of it ended.
stopped: Io.Event = .unset,
counters: Counters = .{},

/// Checks the settings and names this instance, without I/O.
pub fn init(gpa: Allocator, io: Io, store: Store, any_key: []const []const u8, keyed_only: []const []const u8, options: Options) InitError!Engine {
    const d = options.diagnostics;
    if (options.workers == 0) return refuse(d, "workers: 0; a worker runs 1 or more jobs at once", .{});
    inline for (.{ "lease", "renew_every", "poll_every", "store_timeout", "shutdown_grace", "start_timeout", "max_backoff", "unreadable_limit" }) |name| {
        const value: Duration = @field(options, name);
        if (value.nanoseconds <= 0) return refuse(d, name ++ ": {f}; it must be more than zero", .{value});
    }
    if (options.lease.nanoseconds <= options.renew_every.nanoseconds *| 2)
        return refuse(d, "lease: {f}; it must be more than 2 × renew_every ({f})", .{ options.lease, options.renew_every });
    const rule = "an instance is 1–64 bytes of UTF-8 without NUL";
    const name = options.instance;
    if (name.len == 0) return refuse(d, "instance: empty; " ++ rule, .{});
    if (name.len > 64) return refuse(d, "instance: {d} bytes; " ++ rule, .{name.len});
    if (std.mem.findScalar(u8, name, 0) != null) return refuse(d, "instance: it holds a NUL; " ++ rule, .{});
    if (!std.unicode.utf8ValidateSlice(name)) return refuse(d, "instance: not UTF-8; " ++ rule, .{});
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    const instance = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ name, std.fmt.bytesToHex(bytes, .lower) });
    return .{ .gpa = gpa, .io = io, .store = store, .options = options, .instance = instance, .any_key = any_key, .keyed_only = keyed_only };
}

fn refuse(d: ?*Diagnostics, comptime format: []const u8, args: anytype) error{InvalidArgument} {
    if (d) |x| x.set(null, format, args);
    return error.InvalidArgument;
}

/// In safe builds: a call on a worker moved after its `start`, or on
/// another `std.Io` than the one of `init`, panics.
pub fn checkUse(e: *const Engine, io: Io) void {
    if (!std.debug.runtime_safety) return;
    e.checkHome();
    // Two instances of one implementation share the table, so the
    // instance counts too.
    if (io.vtable != e.io.vtable or io.userdata != e.io.userdata)
        @panic("zefir-scheduler: a call on another std.Io than the worker's: pass the io of Worker.init");
}

fn checkHome(e: *const Engine) void {
    if (!std.debug.runtime_safety) return;
    const home = e.home.load(.monotonic);
    if (home != 0 and home != @intFromPtr(e)) @panic("zefir-scheduler: Worker moved after start(): keep it where start() ran");
}

pub fn state(e: *const Engine) State {
    e.checkHome();
    return e.state_value.load(.acquire);
}

pub fn isReady(e: *const Engine) bool {
    return e.state() == .running;
}

pub fn stats(e: *const Engine) Stats {
    e.checkHome();
    return e.counters.snapshot(e.options.workers);
}

/// Stops claiming and begins the stop; from any task, without waiting.
pub fn requestStop(e: *Engine, io: Io) void {
    e.mutex.lockUncancelable(io);
    defer e.mutex.unlock(io);
    switch (e.state_value.load(.monotonic)) {
        .configured => {
            e.state_value.store(.stopped, .release);
            e.stopped.set(io);
        },
        else => {},
    }
}

/// Waits until the worker stopped.
pub fn wait(e: *Engine, io: Io) WaitError!void {
    if (e.state_value.load(.acquire) == .configured) return error.InvalidState;
    _ = e.in_calls.fetchAdd(1, .acq_rel);
    defer _ = e.in_calls.fetchSub(1, .acq_rel);
    try e.stopped.wait(io);
}

/// Stops the worker if it runs, waits for the stop and frees it.
pub fn deinit(e: *Engine, io: Io) void {
    if (e.in_calls.load(.acquire) != 0)
        @panic("zefir-scheduler: Worker.deinit() while a task is in wait, run or shutdown: let it return first");
    e.requestStop(io);
    e.gpa.free(e.instance);
    e.* = undefined;
}
