//! The rules that `mongo.Client` checks before a driver sees a call, once
//! for every driver: the request, then the caller's context. A broken rule
//! of the request is `error.InvalidArgument`; the driver is never called.

const std = @import("std");
const builtin = @import("builtin");
const bson = @import("../bson.zig");
const errors = @import("errors.zig");
const requests = @import("requests.zig");
const Error = errors.Error;
const Diagnostics = errors.Diagnostics;

/// The fields that only the driver writes into a command: `$db` always,
/// the rest with sessions and read preferences of later revisions.
const driver_fields = [_][]const u8{ "$db", "$readPreference", "lsid", "txnNumber", "$clusterTime", "autocommit", "startTransaction" };

/// The fields that the driver writes into a write from its request.
const write_fields = [_][]const u8{ "documents", "updates", "deletes", "ordered" };

pub fn checkCommand(command: *const requests.Command, op: requests.OperationContext, diagnostics: ?*Diagnostics) Error!void {
    try checkDatabase(command.database, diagnostics);
    _ = try checkBody(command.body, op, &.{}, diagnostics);
}

pub fn checkWrite(request: *const requests.WriteRequest, op: requests.OperationContext, diagnostics: ?*Diagnostics) Error!void {
    try checkDatabase(request.database, diagnostics);
    const name = try checkBody(request.body, op, &write_fields, diagnostics);
    const kind = request.kind.command();
    if (!std.mem.eql(u8, name, kind)) return invalid(diagnostics, "a write of kind {s} is the command {s}, but its body starts with '{s}'", .{ kind, kind, name });
    if (request.items.len == 0) return invalid(diagnostics, "the write has no items: it needs at least one", .{});
    if (builtin.mode == .debug) for (request.items, 0..) |item, i| {
        item.validate() catch return invalid(diagnostics, "item {d} of the write is not valid BSON", .{i});
    };
}

/// The caller's context: `DeadlineExceeded` with less than 1 ms left, else
/// `Cancelled` when its token is canceled. The deadline comes first, as
/// in rpc: a server cancels the token of a call at its deadline.
pub fn checkContext(io: std.Io, op: requests.OperationContext, diagnostics: ?*Diagnostics) Error!void {
    if (op.ctx.remaining(std.Io.Clock.awake.now(io))) |left| {
        if (left.nanoseconds < std.time.ns_per_ms) {
            if (diagnostics) |d| d.set(null, null, "less than 1 ms was left of the deadline before the call", .{});
            return error.DeadlineExceeded;
        }
    }
    if (op.ctx.isCancelled()) {
        if (diagnostics) |d| d.set(null, null, "the token was canceled before the call", .{});
        return error.Cancelled;
    }
}

/// After a reply: a token canceled while the call was out.
pub fn interrupted(diagnostics: ?*Diagnostics) Error {
    if (diagnostics) |d| d.set(null, null, "the token was canceled while the call was out; its outcome is dropped", .{});
    return error.Interrupted;
}

/// A database name: 1 to 63 bytes, without NUL and without any of
/// `/\. "$`.
fn checkDatabase(name: []const u8, diagnostics: ?*Diagnostics) Error!void {
    if (name.len == 0 or name.len > 63) return invalid(diagnostics, "a database name is 1 to 63 bytes long; this one is {d}", .{name.len});
    if (std.mem.findAny(u8, name, "\x00/\\. \"$")) |at| {
        return invalid(diagnostics, "a database name holds none of / \\ . \" $, a space or NUL; '{s}' holds byte {d}", .{ name, name[at] });
    }
}

/// Checks the top level of `body` and returns the command's name, its
/// first key. In Debug it validates the whole body too.
fn checkBody(body: bson.RawDocument, op: requests.OperationContext, extra: []const []const u8, diagnostics: ?*Diagnostics) Error![]const u8 {
    var it = body.iterator();
    const first = (it.next() catch return notBson(diagnostics)) orelse
        return invalid(diagnostics, "the command is empty: its first key is its name", .{});
    if (first.key.len == 0 or first.key[0] == '$') {
        return invalid(diagnostics, "the first key of a command is its name, which is not empty and does not start with '$'; got '{s}'", .{first.key});
    }
    var element = first;
    while (true) {
        for (driver_fields) |field| {
            if (std.mem.eql(u8, element.key, field)) return invalid(diagnostics, "the command holds '{s}', which only the driver writes", .{field});
        }
        for (extra) |field| {
            if (std.mem.eql(u8, element.key, field)) return invalid(diagnostics, "the body of a write holds '{s}', which the driver writes from the request", .{field});
        }
        if (op.ctx.deadline != null and std.mem.eql(u8, element.key, "maxTimeMS")) {
            return invalid(diagnostics, "the command holds maxTimeMS and the call has a deadline, from which the driver writes it: drop one of the two", .{});
        }
        element = (it.next() catch return notBson(diagnostics)) orelse break;
    }
    if (builtin.mode == .debug) body.validate() catch return notBson(diagnostics);
    return first.key;
}

fn invalid(diagnostics: ?*Diagnostics, comptime fmt: []const u8, args: anytype) Error {
    if (diagnostics) |d| d.set(null, null, fmt, args);
    return error.InvalidArgument;
}

fn notBson(diagnostics: ?*Diagnostics) Error {
    return invalid(diagnostics, "the command is not valid BSON", .{});
}
