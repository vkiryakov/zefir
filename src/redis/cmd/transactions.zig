//! `cmd.watch` and `cmd.unwatch`: the keys that the next transaction of a
//! `redis.Conn` depends on. A transaction after WATCH runs only while none
//! of its keys changed, and gives null otherwise. Both keep state on the
//! connection they go on, so only a Conn runs them, with `conn.run` or in
//! `conn.pipeline`: on the client, and inside a transaction, they stop the
//! build. `conn.release` closes a connection that may still watch keys,
//! rather than send UNWATCH behind the caller's back; EXEC unwatches every
//! key, whatever its outcome.
//!
//! ```zig
//! var conn = try client.acquire(io, op);
//! defer conn.release(io);
//! try conn.run(io, op, redis.cmd.watch(&.{"stock:coffee"}), .{});
//! ```

const std = @import("std");
const resp = @import("../resp.zig");
const contract = @import("contract.zig");
const Diagnostics = @import("../errors.zig").Diagnostics;

/// WATCH `keys`: one key at least, which the command borrows while it
/// runs.
pub fn watch(keys: []const []const u8) Watch {
    return .{ .keys = keys };
}

/// UNWATCH: no key of the connection is under WATCH after it.
pub fn unwatch() Unwatch {
    return .{};
}

/// The type of `cmd.watch(keys)`.
pub const Watch = struct {
    keys: []const []const u8,

    pub const Reply = void;

    pub const scope: contract.Scope = .{ .connection = .{
        .watching = true,
        .on_client = "WATCH holds its keys on the connection it goes on",
        .in_transaction = "WATCH inside a transaction is refused by the server: run it with conn.run before the transaction",
    } };

    /// No keys is InvalidArgument: the server would refuse it.
    pub fn check(c: Watch, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
        if (c.keys.len > 0) return;
        if (diagnostics) |d| d.set(null, null, "redis.cmd.watch: no keys: WATCH takes one or more", .{});
        return error.InvalidArgument;
    }

    pub fn write(c: Watch, w: resp.Writer) resp.Writer.Error!void {
        try w.arrayHeader(1 + c.keys.len);
        try w.bulk("WATCH");
        for (c.keys) |key| try w.bulk(key);
    }

    pub fn read(_: Watch, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!void {
        return resp.decode(void, r, arena, diagnostics);
    }

    pub fn name(_: Watch) []const u8 {
        return "WATCH";
    }
};

/// The type of `cmd.unwatch()`.
pub const Unwatch = struct {
    pub const Reply = void;

    pub const scope: contract.Scope = .{ .connection = .{
        .watching = false,
        .on_client = "UNWATCH ends the WATCH of the connection it goes on",
        .in_transaction = "UNWATCH inside a transaction is no use, since EXEC unwatches every key: leave it out",
    } };

    pub fn check(_: Unwatch, _: ?*Diagnostics) error{InvalidArgument}!void {}

    pub fn write(_: Unwatch, w: resp.Writer) resp.Writer.Error!void {
        try w.command(&.{"UNWATCH"});
    }

    pub fn read(_: Unwatch, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!void {
        return resp.decode(void, r, arena, diagnostics);
    }

    pub fn name(_: Unwatch) []const u8 {
        return "UNWATCH";
    }
};
