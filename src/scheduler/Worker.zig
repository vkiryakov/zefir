//! `scheduler.Worker(Jobs)`: runs the jobs of `Jobs`, a struct of pointers
//! to job types, in several instances of a service at once.
//!
//! ```zig
//! const Jobs = struct { invoices: *SendInvoice, cleanup: *NightlyCleanup };
//! var worker: scheduler.Worker(Jobs) = try .init(gpa, io, store, .{ .invoices = &invoices, .cleanup = &cleanup }, .{ .instance = "shop" });
//! defer worker.deinit(io);
//! try worker.start(io);
//! // ... until SIGTERM:
//! try worker.shutdown(io, .fromNow(io, .{ .raw = .fromSeconds(25), .clock = .awake }));
//! ```
//!
//! `start` writes the records of the jobs the code declares with
//! `.repeat`, then starts one poll task and `workers` slot tasks. The poll
//! claims the due records of the worker's jobs, atomically and no more than
//! the free slots; a slot runs the job's `run` in a task of its own,
//! renews the lease every `renew_every` while it runs, and records the
//! outcome on condition of its claim. A run that cannot confirm its lease
//! stops before another instance could take the job over; a run whose
//! record was taken over or removed stops at its next renewal. While the
//! store fails, the poll waits with growing pauses and no job runs.
//!
//! The lifecycle methods are those of a bean of zefir.App: under App the
//! worker stops together with the servers, before its store. Do not move
//! the worker after `start`. In safe builds a call on another `std.Io`
//! than the one of `init`, a call on a moved worker, and a `deinit` while
//! another task is in `wait`, `run` or `shutdown` panic. `gpa` must be
//! thread-safe: the tasks of the worker allocate from it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = @import("Store.zig");
const Instant = @import("Instant.zig");
const record = @import("record.zig");
const job_type = @import("Job.zig");
const payload = @import("payload.zig");
const signature = @import("signature.zig");
const Context = @import("Context.zig").Context;
const Engine = @import("worker/Engine.zig");
const Policy = @import("worker/policy.zig").Policy;
const declared = @import("worker/declared.zig");
const Stats = @import("worker/stats.zig").Stats;

/// The worker of the jobs of `Jobs`: `struct { invoices: *SendInvoice,
/// cleanup: *NightlyCleanup }`. The compiler checks every job type, that
/// each field points to one, and that no two share a name.
pub fn Worker(comptime Jobs: type) type {
    comptime checkJobs(Jobs);
    const names = @typeInfo(Jobs).@"struct".field_names;
    return struct {
        const Self = @This();

        engine: Engine,
        entries: [names.len]Engine.Entry,

        pub const Options = Engine.Options;
        pub const State = Engine.State;
        pub const InitError = Engine.InitError;
        pub const StartError = Engine.StartError;
        pub const WaitError = Engine.WaitError;
        pub const ShutdownError = Engine.ShutdownError;

        /// Checks the settings, without I/O and without tasks. `store` and
        /// the jobs outlive the worker.
        pub fn init(gpa: Allocator, io: Io, store: Store, jobs: Jobs, options: Options) InitError!Self {
            const split = comptime declared.split(Jobs);
            var w: Self = .{ .engine = try .init(gpa, io, store, split.any_key, split.keyed_only, options), .entries = undefined };
            inline for (names, 0..) |name, i| w.entries[i] = entryOf(@typeInfo(@FieldType(Jobs, name)).pointer.child, @field(jobs, name));
            return w;
        }

        /// Writes the records of the declared jobs (none: no call of the
        /// store), then starts the poll and the slots. A store that fails
        /// here gives its error, and nothing runs; a create of a declared
        /// record that ends `OutcomeUnknown` is no failure, as the record
        /// read again tells whether it was made. A second `start` is
        /// `error.InvalidState`. Do not move the worker afterwards.
        pub fn start(w: *Self, io: Io) StartError!void {
            w.engine.checkUse(io);
            return w.engine.start(io, &w.entries);
        }

        /// `start` and `wait`: for a program whose main work the worker is.
        pub fn run(w: *Self, io: Io) (StartError || WaitError)!void {
            try w.start(io);
            return w.wait(io);
        }

        /// Whether the worker is running: not starting, draining or
        /// stopped. A store that fails does not change it, since the
        /// worker waits for the store. Thread-safe; for health checks.
        pub fn isReady(w: *const Self) bool {
            return w.engine.isReady();
        }

        /// The state now. Thread-safe.
        pub fn state(w: *const Self) State {
            return w.engine.state();
        }

        /// The counters since the start. Thread-safe.
        pub fn stats(w: *const Self) Stats {
            return w.engine.stats();
        }

        /// Stops claiming and begins the stop: the jobs claimed and not
        /// started go back to the store at once, and the runs get
        /// `shutdown_grace` to end. From any task, without waiting; a
        /// second call does nothing.
        pub fn requestStop(w: *Self, io: Io) void {
            w.engine.checkUse(io);
            w.engine.requestStop(io);
        }

        /// `requestStop`, then a wait for the stop. The deadline cuts
        /// `shutdown_grace`: the runs still going are cancelled 2 s and 250
        /// ms before it, and their jobs go back with contexts that end 500
        /// ms before it, so that the worker stops 250 ms before it. Of
        /// several calls the earliest deadline counts.
        ///
        /// `error.ShutdownTimeout`, 250 ms before the deadline: a handler
        /// has not ended since its cancel. With every handler ended,
        /// `shutdown` waits for the worker's own calls of the store until
        /// the deadline itself, and one that has not returned by then is
        /// error.ShutdownTimeout too: a call on its way when the stop began
        /// ends by `store_timeout`. The worker stays draining, and `deinit`
        /// would wait for it: end the process.
        pub fn shutdown(w: *Self, io: Io, deadline: Io.Clock.Timestamp) ShutdownError!void {
            w.engine.checkUse(io);
            return w.engine.shutdown(io, deadline);
        }

        /// Waits until the worker stopped. The errors of the store never
        /// come here: while the store fails, the worker waits for it.
        /// `error.InvalidState` before `start`.
        pub fn wait(w: *Self, io: Io) WaitError!void {
            w.engine.checkUse(io);
            return w.engine.wait(io);
        }

        /// Stops the worker if it runs, waits for the stop without a limit
        /// and frees it. No task may be in `wait`, `run` or `shutdown`.
        pub fn deinit(w: *Self, io: Io) void {
            w.engine.checkUse(io);
            w.engine.deinit(io);
            w.* = undefined;
        }
    };
}

/// The checks of `Jobs` that the job types alone cannot make: each field
/// is a pointer to a job type, and no two types share a name.
fn checkJobs(comptime Jobs: type) void {
    const prefix = "scheduler: Worker(Jobs): ";
    const info = switch (@typeInfo(Jobs)) {
        .@"struct" => |s| s,
        else => @compileError(prefix ++ "Jobs is a struct of pointers to the jobs of the worker: struct { invoices: *SendInvoice }; got " ++ signature.shortName(Jobs)),
    };
    for (info.field_names, info.field_types) |name, T| {
        const J: ?type = switch (@typeInfo(T)) {
            .pointer => |p| if (p.size == .one and !p.attrs.@"const") p.child else null,
            else => null,
        };
        if (J == null) {
            const Shown = switch (@typeInfo(T)) {
                .pointer => |p| p.child,
                else => T,
            };
            @compileError(prefix ++ "a field of Jobs points to a job: " ++ name ++ ": *" ++ signature.shortName(Shown));
        }
        job_type.assertJob(J.?);
    }
    for (info.field_types, 0..) |T, i| {
        const J = @typeInfo(T).pointer.child;
        for (info.field_types[0..i]) |Before| {
            const B = @typeInfo(Before).pointer.child;
            if (std.mem.eql(u8, B.scheduler_job.name, J.scheduler_job.name))
                @compileError(prefix ++ signature.shortName(B) ++ " and " ++ signature.shortName(J) ++ " share the name \"" ++ J.scheduler_job.name ++ "\"");
        }
    }
}

/// The entry of the job `job` of type `J`.
fn entryOf(comptime J: type, job: *J) Engine.Entry {
    const gen = struct {
        /// What a job without `Payload` gets: nothing reads it.
        const nothing: u8 = 0;

        fn read(arena: Allocator, json: []const u8) Engine.Read {
            const value = payload.decode(J, arena, json) catch |err| return switch (err) {
                error.OutOfMemory => .out_of_memory,
                else => .unreadable,
            };
            if (comptime !job_type.hasPayload(J)) return .{ .payload = &nothing };
            const p = arena.create(J.Payload) catch return .out_of_memory;
            p.* = value;
            return .{ .payload = p };
        }

        fn call(ptr: *anyopaque, ctx: *Context, p: *const anyopaque) anyerror!void {
            const self: *J = @ptrCast(@alignCast(ptr));
            if (comptime !job_type.hasPayload(J)) return self.run(ctx);
            const value: *const J.Payload = @ptrCast(@alignCast(p));
            return self.run(ctx, value.*);
        }

        fn wanted(arena: Allocator, now: Instant, life: record.Life) error{ OutOfMemory, InvalidArgument }!Store.CreateRequest {
            return declared.wanted(J, arena, now, life);
        }
    };
    return .{
        .policy = .of(J),
        .type_name = comptime signature.shortName(J),
        .job = job,
        .read = gen.read,
        .call = gen.call,
        .wanted = if (comptime J.scheduler_job.repeat != null) gen.wanted else null,
    };
}
