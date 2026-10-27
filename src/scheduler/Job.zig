//! The declaration of a job type, `scheduler.Job`, and its policy:
//! `Retry`, `Misfire`, `WhenDone`. A job is a Zig type: its dependencies
//! are its fields, the data of one run is its `Payload`, and its work is
//! `run`:
//!
//! ```zig
//! const SendInvoice = struct {
//!     billing: *Billing,
//!
//!     pub const scheduler_job: scheduler.Job = .{
//!         .name = "send-invoice",
//!         .timeout = .fromSeconds(30),
//!         .retry = .{ .give_up_on = &.{error.OrderGone} },
//!     };
//!
//!     /// The data of one run: the store keeps it as JSON.
//!     pub const Payload = struct { order_id: u64, amount_cents: u64, note: ?[]const u8 = null };
//!
//!     pub fn run(self: *SendInvoice, ctx: *scheduler.Context, payload: Payload) !void {
//!         try self.billing.send(ctx.operation(), ctx.io(), payload.order_id, ctx.info().run_key);
//!     }
//! };
//! ```
//!
//! A job without `Payload` has a `run` without the third parameter. A
//! repeating job that the code declares has `.repeat`: the worker keeps its
//! record, with the key "". `Ref.of`, `Client.schedule` and
//! `Worker(Jobs)` check a job type at compile time; a mistake stops the
//! build with a message that names the type and what to write.
//!
//! The payload is written by `std.json.Stringify` and read by
//! `std.json.parseFromSliceLeaky`: numbers, strings, bools, enums (by
//! name), optionals, slices and structs. A reader skips the fields it does
//! not know and gives a missing field its default, so a field with a
//! default can be added without breaking the records of an older version;
//! an incompatible change is a new name.

const std = @import("std");
const Duration = std.Io.Duration;
const Schedule = @import("schedule/Schedule.zig");
const args = @import("schedule/args.zig");
const record = @import("record.zig");
const signature = @import("signature.zig");
const Context = @import("Context.zig").Context;
const Retention = record.Retention;

/// The declaration of a job type:
/// `pub const scheduler_job: scheduler.Job = .{ .name = "send-invoice" };`.
pub const Job = struct {
    /// The name under which the store keeps the records of the job: 1–64
    /// bytes of a–z, 0–9, '-', '_' and '.', starting with a letter or a
    /// digit. Keep it while records of the job exist: nobody runs a record
    /// of an old name.
    name: []const u8,
    /// How long one run may take; null is no limit. When it passes, the
    /// run is cancelled and counts as a failed attempt (`error.Timeout`).
    timeout: ?Duration = null,
    retry: Retry = .{},
    /// A repeating job that the code declares: the worker keeps its record,
    /// with the key "".
    repeat: ?Schedule = null,
    /// What to do with the runs of a repeating job that did not start in
    /// time.
    misfire: Misfire = .coalesce,
    /// The history of the runs: none (the default), for a time, or always.
    history: Retention = .none,
    /// What to do with a one-shot job that finished.
    when_done: WhenDone = .{},
};

/// How a job tries again after a failed attempt.
pub const Retry = struct {
    /// Attempts in all, the first one included; 1 is no retry. null: 5 for
    /// a one-shot job, 1 for a repeating one (its next run plays the
    /// retry).
    attempts: ?u32 = null,
    /// The pause after the first failed attempt.
    delay: Duration = .fromSeconds(1),
    /// How much longer each next pause is; 1 keeps the pause constant.
    multiplier: u32 = 5,
    /// The longest pause. Each pause is shorter than its count by a random
    /// 0–20 %.
    max_delay: Duration = .fromSeconds(120),
    /// The errors after which no attempt follows: `&.{error.OrderGone}`.
    give_up_on: []const anyerror = &.{},
};

/// A run of a repeating job that did not start in time.
pub const Misfire = union(enum) {
    /// One run for all the runs missed, and the next one counted from now.
    coalesce,
    /// No run that comes later than this.
    skip: Duration,
};

/// What to do with a one-shot job that finished.
pub const WhenDone = struct {
    /// A succeeded job: removed at once by default.
    succeeded: Retention = .none,
    /// A failed job: kept 30 days by default, to see it in `list` and give
    /// it back its attempts with `client.retry`.
    failed: Retention = .{ .keep_for = .fromSeconds(30 * 24 * 60 * 60) },
};

/// Stops the build unless `J` is a job type: a declaration of type `Job`
/// with a right name and policy, a struct `Payload` if any, and `run` of
/// the expected signature. Internal to the module.
pub fn assertJob(comptime J: type) void {
    comptime {
        @setEvalBranchQuota(10_000);
        const T = signature.shortName(J);
        const prefix = "scheduler: " ++ T ++ ": ";
        const declared = switch (@typeInfo(J)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(J, "scheduler_job"),
            else => false,
        };
        if (!declared)
            @compileError("scheduler: " ++ T ++ " has no scheduler_job: declare pub const scheduler_job: scheduler.Job = .{ .name = \"" ++ kebab(T) ++ "\" };");
        const Declaration = @TypeOf(J.scheduler_job);
        if (Declaration != Job)
            @compileError("scheduler: " ++ T ++ ".scheduler_job is " ++ described(Declaration) ++ ": write pub const scheduler_job: scheduler.Job = .{ … }");
        const job: Job = J.scheduler_job;
        if (!record.validJobName(job.name))
            @compileError(prefix ++ "the name " ++ std.fmt.comptimePrint("\"{f}\"", .{args.Quoted{ .text = job.name }}) ++
                ": a name is 1–64 bytes of a-z, 0-9, '-', '_' and '.', starting with a letter or a digit");
        if (hasPayload(J)) {
            const object = @TypeOf(J.Payload) == type and switch (@typeInfo(J.Payload)) {
                .@"struct" => |s| !s.is_tuple,
                else => false,
            };
            if (!object) @compileError(prefix ++ "Payload is the JSON object of a run: a struct");
        }
        if (!runMatches(J)) {
            const payload = if (hasPayload(J)) ", payload: " ++ T ++ ".Payload" else "";
            @compileError(prefix ++ "expected pub fn run(self: *" ++ T ++ ", ctx: *scheduler.Context" ++ payload ++ ") !void");
        }
        if (job.repeat) |s| {
            // fixedDelay is no inline function: its value is checked here.
            switch (s.internal) {
                .invalid => |problem| @compileError(prefix ++ "repeat: " ++ std.fmt.comptimePrint("{f}", .{problem})),
                else => {},
            }
            if (hasPayload(J)) for (@typeInfo(J.Payload).@"struct".field_attrs) |attrs| {
                if (attrs.default_value_ptr == null)
                    @compileError(prefix ++ "the declared record of a repeat gets Payload{}: give every field of Payload a default, or drop .repeat");
            };
        }
        const retry = job.retry;
        if (retry.attempts) |n| if (n == 0) @compileError(prefix ++ "retry.attempts is 0: write 1 or more, or null for the default");
        if (retry.multiplier == 0) @compileError(prefix ++ "retry.multiplier is 0: write 1 for a constant pause, or more");
        if (retry.delay.nanoseconds <= 0) @compileError(prefix ++ "retry.delay must be more than zero");
        if (retry.max_delay.nanoseconds < retry.delay.nanoseconds) @compileError(prefix ++ "retry.max_delay is less than retry.delay");
        if (job.timeout) |timeout| if (timeout.nanoseconds <= 0) @compileError(prefix ++ "timeout must be more than zero");
        checkKeep(prefix ++ "history", job.history);
        checkKeep(prefix ++ "when_done.succeeded", job.when_done.succeeded);
        checkKeep(prefix ++ "when_done.failed", job.when_done.failed);
        switch (job.misfire) {
            .coalesce => {},
            .skip => |threshold| if (threshold.nanoseconds <= 0) @compileError(prefix ++ "misfire.skip must be more than zero"),
        }
    }
}

/// Whether the job type `J` declares a `Payload`. Internal to the module.
pub fn hasPayload(comptime J: type) bool {
    return @hasDecl(J, "Payload");
}

/// The payload of a run of `J`: `J.Payload`, or `void` for a job without
/// one. Internal to the module.
pub fn PayloadOf(comptime J: type) type {
    assertJob(J);
    return if (hasPayload(J)) J.Payload else void;
}

/// What `J.run` returns: an error union of `void`. Internal to the module.
pub fn RunResult(comptime J: type) type {
    assertJob(J);
    return @typeInfo(@TypeOf(J.run)).@"fn".return_type.?;
}

/// Whether `J.run` is `fn (*J, *Context, J.Payload) E!void`, or without
/// the payload for a job without `Payload`.
fn runMatches(comptime J: type) bool {
    if (!@hasDecl(J, "run")) return false;
    const info = switch (@typeInfo(@TypeOf(J.run))) {
        .@"fn" => |f| f,
        else => return false,
    };
    if (info.is_generic or info.attrs.varargs) return false;
    const params: []const type = if (hasPayload(J)) &.{ *J, *Context, J.Payload } else &.{ *J, *Context };
    if (info.param_types.len != params.len) return false;
    for (info.param_types, params) |have, want| {
        if ((have orelse return false) != want) return false;
    }
    return switch (@typeInfo(info.return_type orelse return false)) {
        .error_union => |u| u.payload == void,
        else => false,
    };
}

/// Stops the build when `keep` keeps for no time; `field` names it.
fn checkKeep(comptime field: []const u8, comptime keep: Retention) void {
    switch (keep) {
        .none, .forever => {},
        .keep_for => |time| if (time.nanoseconds <= 0) @compileError(field ++ ".keep_for must be more than zero"),
    }
}

/// The type of a declaration in a message: "a []const u8", or "an
/// anonymous struct" for a literal without a type, whose name has a number
/// of the compiler.
fn described(comptime T: type) []const u8 {
    const anonymous = switch (@typeInfo(T)) {
        .@"struct" => |s| s.field_attrs.len > 0 and for (s.field_attrs) |attrs| {
            if (!attrs.@"comptime") break false;
        } else true,
        else => false,
    };
    return if (anonymous) "an anonymous struct" else "a " ++ signature.shortName(T);
}

/// The name of a type as a job name, for the hint: "SendInvoice" is
/// "send-invoice", "HTTPPoller" is "http-poller".
fn kebab(comptime name: []const u8) []const u8 {
    var out: []const u8 = "";
    for (name, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            const after_word = i > 0 and (std.ascii.isLower(name[i - 1]) or std.ascii.isDigit(name[i - 1]));
            const ends_acronym = i > 0 and std.ascii.isUpper(name[i - 1]) and i + 1 < name.len and std.ascii.isLower(name[i + 1]);
            if (after_word or ends_acronym) out = out ++ "-";
            out = out ++ [1]u8{std.ascii.toLower(c)};
        } else {
            out = out ++ [1]u8{c};
        }
    }
    return out;
}
