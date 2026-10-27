//! One call of `mongo.SchedulerStore`: the caller's context and memory, a
//! scratch arena for the commands and replies, and how the errors of
//! zefir-mongo become those of the store contract.
//!
//! A `writeConcernError` is no failure of the write: it ran, without its
//! write concern, and the reply still says what it did. zefir-mongo gives
//! it as `WriteFailed`, or `Timeout` for code 50, with the result in the
//! `partial` of a write or the `failure_reply` of a findAndModify, and the
//! operation returns that result and logs a warning (`ran`).
//!
//! Any other error of zefir-mongo falls in one of three classes. "Not
//! sent" (`Unavailable`, `DeadlineExceeded`, …) changed nothing.
//! "Answered" (`CommandFailed`, `WriteFailed` of items the server refused)
//! and "no reply" (`ConnectionLost`, `Timeout`, …) may have run: the
//! operation reads the record again by the mark its write left. Applied, it
//! gives the normal result; not applied, an answered write is
//! `error.Refused`, with the server's code, and one without a reply may
//! still arrive, so it is `error.OutcomeUnknown` unless sending it again
//! changes nothing (rule 7 of the contract): a renewal, or the upsert of a
//! create while no claim can have taken its record.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const bson = @import("mongo-bson");
const scheduler = @import("scheduler");
const mongo = @import("../root.zig");
const SchedulerStore = @import("../SchedulerStore.zig");
const documents = @import("documents.zig");
const Store = scheduler.Store;
const StoreError = Store.StoreError;
const Call = @This();

const log = std.log.scoped(.mongo);

store: *SchedulerStore,
io: Io,
ctx: core.Context,
/// The memory of the result: `CallOptions.allocator`.
out: Allocator,
d: ?*scheduler.Diagnostics,
/// The operation, for the texts: "create".
what: []const u8,
scratch: std.heap.ArenaAllocator,
/// What zefir-mongo said of the latest error of the call's main command.
md: mongo.Diagnostics = .{},

pub fn init(store: *SchedulerStore, io: Io, ctx: core.Context, options: Store.CallOptions, what: []const u8) Call {
    return .{ .store = store, .io = io, .ctx = ctx, .out = options.allocator, .d = options.diagnostics, .what = what, .scratch = .init(store.gpa) };
}

pub fn deinit(c: *Call) void {
    c.scratch.deinit();
}

/// Rules 3 and 4 of the contract, before anything goes out.
pub fn check(c: *Call) StoreError!void {
    if (c.ctx.remaining(Io.Clock.awake.now(c.io))) |left| {
        if (left.nanoseconds < std.time.ns_per_ms) return c.fail(error.DeadlineExceeded, null, "{s}: less than 1 ms was left of the deadline before the call", .{c.what});
    }
    if (c.ctx.isCancelled()) return c.fail(error.Cancelled, null, "{s}: the token was cancelled before the call", .{c.what});
}

pub fn a(c: *Call) Allocator {
    return c.scratch.allocator();
}

pub fn op(c: *const Call) mongo.OperationContext {
    return .of(c.ctx);
}

pub fn jobs(c: *const Call) mongo.Collection {
    return mongo.Database.init(c.store.client, c.store.database, &c.store.ids).collection(c.store.jobs);
}

pub fn runs(c: *const Call) mongo.Collection {
    return mongo.Database.init(c.store.client, c.store.database, &c.store.ids).collection(c.store.runs);
}

/// `"<job>/<key>"`, the `_id` of the record of `ref`, in the scratch; null
/// when the name of the job breaks its rule, so that no record has it.
pub fn id(c: *Call, ref: scheduler.Ref) Allocator.Error!?[]const u8 {
    if (!documents.validJobName(ref.job)) return null;
    return try std.fmt.allocPrint(c.a(), "{s}/{s}", .{ ref.job, ref.key });
}

/// The record of `id` as it is now, read into the scratch; null when there
/// is none. The driver's details go to `md`.
pub fn read(c: *Call, record_id: []const u8, md: *mongo.Diagnostics) (mongo.Error || documents.ReadError)!?documents.Read {
    const doc = (try c.jobs().findOne(c.io, c.op(), .{ ._id = record_id }, .{ .allocator = c.a(), .diagnostics = md })) orelse return null;
    var problem: documents.Problem = .{};
    return documents.readRecord(c.a(), doc.raw(), &problem) catch |err| {
        if (err == error.Corrupt) c.corruptText(doc.raw(), &problem);
        return err;
    };
}

/// The record that `raw` holds, copied into the caller's memory.
pub fn record(c: *Call, raw: bson.RawDocument) StoreError!scheduler.Record {
    const r = try c.decode(raw);
    return try documents.recordOut(c.out, &r.record);
}

/// The record that `raw` holds, its strings in `raw`.
pub fn decode(c: *Call, raw: bson.RawDocument) StoreError!documents.Read {
    var problem: documents.Problem = .{};
    return documents.readRecord(c.a(), raw, &problem) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Corrupt => c.corrupt(raw, &problem),
    };
}

/// `raw` is no record or row of the store, as `problem` says.
pub fn corrupt(c: *Call, raw: bson.RawDocument, problem: *const documents.Problem) StoreError {
    c.corruptText(raw, problem);
    return error.Corrupt;
}

fn corruptText(c: *Call, raw: bson.RawDocument, problem: *const documents.Problem) void {
    const doc_id = if (raw.get("_id") catch null) |value| switch (value) {
        .string => |text| text,
        else => "?",
    } else "?";
    if (c.d) |x| x.set(null, "{s}: the document {s} is not one of the store: {s}", .{ c.what, doc_id, problem.message() });
}

pub const Class = enum {
    /// Nothing went out.
    not_sent,
    /// The server answered with an error: the write may have run.
    answered,
    /// No reply: the write may have run, and may still arrive.
    no_reply,
    memory,
};

pub fn classOf(err: mongo.Error) Class {
    return switch (err) {
        error.InvalidArgument,
        error.Unsupported,
        error.Closed,
        error.Unavailable,
        error.AuthenticationFailed,
        error.PoolExhausted,
        error.DeadlineExceeded,
        error.Cancelled,
        => .not_sent,
        error.CommandFailed, error.WriteFailed => .answered,
        error.ConnectionLost, error.Timeout, error.Interrupted, error.IncompleteWrite, error.ProtocolViolation => .no_reply,
        error.OutOfMemory => .memory,
    };
}

/// `err` of a command that changed nothing: one that did not go out, a
/// read, or a write that is known not to have run. The text is zefir-mongo's.
pub fn nothing(c: *Call, err: mongo.Error) StoreError {
    const mapped: StoreError = switch (err) {
        error.InvalidArgument, error.Unsupported => error.InvalidArgument,
        error.Unavailable, error.PoolExhausted, error.Closed, error.ConnectionLost, error.IncompleteWrite, error.ProtocolViolation => error.Unavailable,
        error.DeadlineExceeded, error.Timeout => error.DeadlineExceeded,
        error.Cancelled, error.Interrupted => error.Cancelled,
        error.AuthenticationFailed, error.CommandFailed, error.WriteFailed => error.Refused,
        error.OutOfMemory => error.OutOfMemory,
    };
    return c.fail(mapped, code(&c.md), "{s}: error.{t} of zefir-mongo: {s}", .{ c.what, err, c.md.message() });
}

/// The write that failed with `err` is known not to have run: the server
/// answered, and the record read again shows it.
pub fn refused(c: *Call, err: mongo.Error) StoreError {
    return c.fail(error.Refused, code(&c.md), "{s}: the server refused the write, error.{t}: {s}", .{ c.what, err, c.md.message() });
}

/// The write that failed with `err` may have run: reading the record again
/// failed with `again`, or cannot tell whether the write may still arrive.
pub fn unknown(c: *Call, err: mongo.Error, again: ?anyerror) StoreError {
    if (again) |e| return c.fail(error.OutcomeUnknown, code(&c.md), "{s}: the write may have run (error.{t} of zefir-mongo: {s}), and reading the record again failed: error.{t}", .{ c.what, err, c.md.message(), e });
    return c.fail(error.OutcomeUnknown, code(&c.md), "{s}: the write may have run (error.{t} of zefir-mongo: {s}) and may still arrive", .{ c.what, err, c.md.message() });
}

/// The write that failed with `err` may have run, and what changed the
/// record since, read again, left no mark of it.
pub fn unknownSince(c: *Call, err: mongo.Error) StoreError {
    return c.fail(error.OutcomeUnknown, code(&c.md), "{s}: the write may have run (error.{t} of zefir-mongo: {s}), and what changed the record since leaves no mark of it", .{ c.what, err, c.md.message() });
}

/// The write that failed with `err` ran, by its reply or the record read
/// again; one that ran without its write concern, the log says.
pub fn ran(c: *Call, err: mongo.Error) void {
    if (!unconfirmed(err, &c.md)) return;
    log.warn("SchedulerStore: {s}: the server answered error.{t} (code {d}: {s}), yet the write is in place: its write concern is not confirmed", .{ c.what, err, code(&c.md) orelse 0, c.md.message() });
}

/// Whether a write that failed with `err`, and that ran, ran without its
/// write concern: the server answered with an error, a `writeConcernError`
/// among them, or with MaxTimeMSExpired, code 50, which zefir-mongo gives
/// as `error.Timeout`, while it waited for it.
pub fn unconfirmed(err: mongo.Error, md: *const mongo.Diagnostics) bool {
    return classOf(err) == .answered or (err == error.Timeout and code(md) == 50);
}

/// Whether the write whose `partial` result, an `UpdateResult` or a
/// `DeleteResult`, its error left in `known` ran without its write
/// concern: a `writeConcernError`, and no item that the server refused.
/// The rest of `known` is then what the write did.
pub fn ranUnconfirmed(known: anytype) bool {
    return known.write_errors.len == 0 and known.write_concern_errors.len > 0;
}

/// What a findAndModify did that ran without its write concern: the
/// document it changed, or none.
pub const Modified = struct { value: ?bson.RawDocument };

/// What the findAndModify whose error left `reply`, its `failure_reply`,
/// did: with a `writeConcernError`, it ran, and `value` holds the
/// document it changed or null; null when it did not run so.
pub fn modifiedUnconfirmed(reply: ?bson.OwnedDocument) ?Modified {
    const doc = (reply orelse return null).raw();
    if ((doc.get("writeConcernError") catch null) == null) return null;
    const value = (doc.get("value") catch null) orelse return null;
    return switch (value) {
        .document => |found| .{ .value = found },
        .null => .{ .value = null },
        else => null,
    };
}

pub fn invalid(c: *Call, comptime fmt: []const u8, args: anytype) error{InvalidArgument} {
    if (c.d) |x| x.set(null, fmt, args);
    return error.InvalidArgument;
}

/// An error of `bson.Builder` while the call writes its command: a string
/// of the request that is not UTF-8.
pub fn built(c: *Call, err: bson.Builder.Error) StoreError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidBson => c.invalid("{s}: a string of the request is not UTF-8", .{c.what}),
    };
}

fn fail(c: *Call, err: StoreError, server_code: ?i32, comptime fmt: []const u8, args: anytype) StoreError {
    if (c.d) |x| x.set(server_code, fmt, args);
    return err;
}

/// The server's code of the latest error, when it gave one.
pub fn code(md: *const mongo.Diagnostics) ?i32 {
    const server = md.server orelse return null;
    return if (server.code != 0) server.code else null;
}
