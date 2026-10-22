//! The contract of a command type: what the value that a function of
//! `redis.cmd` returns declares, so that the client can run it. It is
//! internal to the module and may change; a command that the catalog lacks
//! is made with `cmd.raw`, not with a type of one's own.
//!
//! A command type `C` is a struct. Its value holds what the command
//! borrows, slices of keys and values and numbers, and no state: it may be
//! built ahead and run many times while its slices live. `C` declares:
//!
//! - `pub const Reply: type` — what running it returns. The decoder reads
//!   the reply into it, so `C` checks it with `resp.checkReply`, whose
//!   message names the function of `cmd`.
//! - `pub fn check(c: C, diagnostics: ?*Diagnostics) error{InvalidArgument}!void`
//!   — the rules that only run time sees: an empty list, a duration under
//!   1 ms, NaN. The client checks every command of a call before it sends
//!   anything; the reason goes to the diagnostics.
//! - `pub fn write(c: C, w: resp.Writer) resp.Writer.Error!void` — the
//!   command as an array of bulk strings, into the buffer of the
//!   connection: the same bytes each time.
//! - `pub fn read(c: C, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!Reply`
//!   — its reply, by the rules of `resp.decode`: after ServerError and
//!   UnexpectedReply the reply is read to its end.
//! - `pub fn name(c: C) []const u8` — the name of the command, such as
//!   "GET", for the client's texts about it; never a value.
//!
//! Declarations that tell the client more about a command come with the
//! commands that need them:
//!
//! - `pub const scope: contract.Scope = .{ .connection = … }` — a command
//!   that keeps state on its connection: WATCH and UNWATCH. Only a
//!   `redis.Conn` runs it, with `run` or in a pipeline, and the Conn
//!   notes whether keys are under WATCH after it succeeded; on the client
//!   and inside a transaction it stops the build (`ReplyOn`).
//! - `pub const blocking: contract.Blocking` — a blocking command: the
//!   units of its timeout on the wire and what waits less. It also
//!   declares `pub fn timeout(c: C) redis.Block`, how long the caller lets
//!   it wait, and `pub fn writeWith(c: C, w: resp.Writer, timeout_ms: u64)`,
//!   the command with `timeout_ms` in place of its timeout, 0 for forever,
//!   written by `writeTimeout`. Under a deadline the client takes the
//!   timeout from what is left of it (`engine/blocking.zig`) and writes the
//!   command with `writeWith`; without one, and in a transaction, where
//!   nothing blocks, `write` sends the command's own, `given`. Its `check`
//!   calls `checkBlock`.
//! - `pub const Item: type` and `pub fn page(c: C) contract.Page` — a
//!   page of a scan, SCAN, HSCAN, SSCAN or ZSCAN: the type of its items,
//!   and the command as `client.iterate` sends it again for each page,
//!   with the cursor that the page before returned (`command.Paged`).
//! - `pub fn writeSha(c: C, w: resp.Writer) resp.Writer.Error!void` — a
//!   script of `redis.Script`: alone in `run` it goes out as `writeSha`
//!   writes it, EVALSHA, and after NOSCRIPT, which says that the script
//!   did not run, as `write` writes it, EVAL with its text, on the same
//!   connection; in a pipeline and a transaction as `write` writes it.
//!
//! A pipeline and a transaction take their commands as a tuple of command
//! values, each of its own type, or as many commands of one type: a slice
//! of them, or a pointer to their array. `Results` is what they return.

const std = @import("std");
const errors = @import("../errors.zig");
const CommandError = errors.CommandError;
const Diagnostics = errors.Diagnostics;
const resp = @import("../resp.zig");
const Block = @import("types.zig").Block;
const KeyType = @import("types.zig").KeyType;

/// The type of the reply of the command type `C`; a compile error that
/// starts with `call` when `C` is not one.
pub fn ReplyOf(comptime C: type, comptime call: []const u8) type {
    comptime {
        const is_command = @typeInfo(C) == .@"struct" and @hasDecl(C, "Reply") and
            @hasDecl(C, "check") and @hasDecl(C, "write") and @hasDecl(C, "read") and @hasDecl(C, "name");
        if (!is_command) @compileError(call ++ ": " ++ @typeName(C) ++ " is not a command: make one with redis.cmd, such as redis.cmd.get([]const u8, key)");
        return C.Reply;
    }
}

/// Where a command keeps what it does: `.any` for most, which leave
/// nothing behind on their connection; `.connection` for one whose type
/// declares `pub const scope`, with what it does there.
pub const Scope = union(enum) {
    any,
    connection: OnConnection,
};

/// What a command of `scope = .connection` does to its connection, and why
/// the client and a transaction cannot run it, for their compile errors.
pub const OnConnection = struct {
    /// Whether keys are under WATCH on the connection once the command
    /// succeeded: true after WATCH, false after UNWATCH.
    watching: bool,
    /// Why the client cannot run it: "WATCH holds its keys on the
    /// connection it goes on".
    on_client: []const u8,
    /// Why a transaction cannot hold it, and the fix.
    in_transaction: []const u8,
};

pub fn scopeOf(comptime C: type) Scope {
    return if (@hasDecl(C, "scope")) C.scope else .any;
}

/// Where a call runs its commands.
pub const Place = enum {
    /// `client.run` and `client.pipeline`: a connection of the pool, for
    /// that call alone.
    client,
    /// `conn.run` and `conn.pipeline`: the connection of a task.
    conn,
    /// `conn.transaction`, between MULTI and EXEC.
    transaction,
};

/// `ReplyOf`, and a compile error that starts with `call` for a command of
/// `scope = .connection` where `place` cannot run it: on the client, or
/// inside a transaction.
pub fn ReplyOn(comptime C: type, comptime call: []const u8, comptime place: Place) type {
    comptime {
        const Reply = ReplyOf(C, call);
        switch (scopeOf(C)) {
            .any => {},
            .connection => |rule| switch (place) {
                .client => @compileError(call ++ ": " ++ rule.on_client ++ ": run it on a connection of client.acquire"),
                .transaction => @compileError(call ++ ": " ++ rule.in_transaction),
                .conn => {},
            },
        }
        return Reply;
    }
}

/// Whether the commands of type `Commands` are a tuple; false for many of
/// one type, a slice of them or a pointer to their array. Any other type
/// stops the build with a message that starts with `call`.
pub fn isTuple(comptime Commands: type, comptime call: []const u8) bool {
    comptime {
        switch (@typeInfo(Commands)) {
            .@"struct" => |info| if (info.is_tuple) return true,
            .pointer => |info| switch (info.size) {
                .slice => return false,
                .one => if (@typeInfo(info.child) == .array) return false,
                else => {},
            },
            else => {},
        }
        @compileError(call ++ ": the commands are a tuple of commands, such as .{ redis.cmd.raw(i64, .{ \"INCR\", key }), redis.cmd.raw(bool, .{ \"PEXPIRE\", key, ms }) }, or many of one type, in a slice or behind a pointer to their array, such as &commands; got " ++ @typeName(Commands));
    }
}

/// The type of each of many commands of one type, `Commands` a slice of
/// them or a pointer to their array.
pub fn Element(comptime Commands: type) type {
    const info = @typeInfo(Commands).pointer;
    return if (info.size == .slice) info.child else @typeInfo(info.child).array.child;
}

/// What a pipeline or a transaction of `Commands` returns: for a tuple, a
/// tuple of `CommandError!R`, one for each command in its order, `R` the
/// type of its reply; for many commands of one type, a slice of them.
pub fn Results(comptime Commands: type, comptime call: []const u8, comptime place: Place) type {
    comptime {
        if (!isTuple(Commands, call)) return []const (CommandError!ReplyOn(Element(Commands), call, place));
        const commands = @typeInfo(Commands).@"struct".field_types;
        var types: [commands.len]type = undefined;
        for (commands, &types) |C, *slot| slot.* = CommandError!ReplyOn(C, call, place);
        return @Tuple(&types);
    }
}

/// A page of a scan as `client.iterate` sends it: `word [key] cursor
/// [MATCH p] [COUNT n] [TYPE t]`, the cursor that of the page.
pub const Page = struct {
    /// The function of `cmd`, such as "redis.cmd.scan", for the texts.
    call: []const u8,
    /// SCAN, HSCAN, SSCAN or ZSCAN.
    word: []const u8,
    /// The key of HSCAN, SSCAN and ZSCAN; null for SCAN.
    key: ?[]const u8,
    cursor: u64,
    match: ?[]const u8,
    count: ?u32,
    /// The TYPE of SCAN.
    type: ?KeyType,
};

/// The type of the items of the scan `C`; a compile error that starts with
/// `call` when `C` is no scan.
pub fn ItemOf(comptime C: type, comptime call: []const u8) type {
    comptime {
        const scan = @typeInfo(C) == .@"struct" and @hasDecl(C, "Item") and @hasDecl(C, "page");
        if (!scan) @compileError(call ++ ": the command is not a scan: iterate walks the pages of redis.cmd.scan, redis.cmd.hscan, redis.cmd.sscan or redis.cmd.zscan");
        return C.Item;
    }
}

/// The units of the timeout of a blocking command on the wire.
pub const Unit = enum {
    /// Seconds with a fraction: BLPOP, BRPOP, BLMOVE.
    seconds,
    /// Milliseconds: XREAD and XREADGROUP with BLOCK.
    milliseconds,
};

/// The mark of a blocking command, `pub const blocking`.
pub const Blocking = struct {
    unit: Unit,
    /// What waits less, for the text of DeadlineExceeded when the deadline
    /// leaves too little: "redis.cmd.lpop".
    instead: []const u8,
};

pub fn isBlocking(comptime C: type) bool {
    return @hasDecl(C, "blocking");
}

pub fn isScript(comptime C: type) bool {
    return @hasDecl(C, "writeSha");
}

/// The timeout of `block` in milliseconds, rounded down, 0 for forever:
/// what a blocking command sends of its own. `checkBlock` has kept it
/// between 1 ms and `maxInt(i64)` ms.
pub fn given(block: Block) u64 {
    return switch (block) {
        .forever => 0,
        .at_most => |duration| @intCast(std.math.clamp(@divFloor(duration.nanoseconds, std.time.ns_per_ms), 1, std.math.maxInt(i64))),
    };
}

/// Writes a timeout of `timeout_ms` milliseconds, 0 for forever, as one
/// argument in `unit`: seconds with as many decimals as it needs (`0.85`,
/// `30`), or milliseconds (`850`).
pub fn writeTimeout(w: resp.Writer, unit: Unit, timeout_ms: u64) resp.Writer.Error!void {
    var buffer: [32]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    switch (unit) {
        .milliseconds => out.print("{d}", .{timeout_ms}) catch unreachable,
        .seconds => {
            out.print("{d}", .{timeout_ms / 1000}) catch unreachable;
            const ms = timeout_ms % 1000;
            if (ms > 0) {
                var digits: [3]u8 = .{ '0' + @as(u8, @intCast(ms / 100)), '0' + @as(u8, @intCast(ms / 10 % 10)), '0' + @as(u8, @intCast(ms % 10)) };
                var len: usize = digits.len;
                while (digits[len - 1] == '0') len -= 1;
                out.print(".{s}", .{digits[0..len]}) catch unreachable;
            }
        },
    }
    try w.bulk(out.buffered());
}

/// The rule of the timeout of a blocking command: `.at_most` of 1 ms to
/// `maxInt(i64)` ms. Under 1 ms is InvalidArgument, since 0 is forever to
/// a server, and so is a duration that does not fit the milliseconds of
/// the client. `call` names the function of `cmd`.
pub fn checkBlock(block: Block, comptime call: []const u8, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
    const duration = switch (block) {
        .forever => return,
        .at_most => |duration| duration,
    };
    if (duration.nanoseconds < std.time.ns_per_ms) {
        if (diagnostics) |d| d.set(null, null, call ++ ": the timeout .at_most is under 1 ms, which a server takes as forever: give 1 ms or more, or .forever", .{});
        return error.InvalidArgument;
    }
    if (@divFloor(duration.nanoseconds, std.time.ns_per_ms) > std.math.maxInt(i64)) {
        if (diagnostics) |d| d.set(null, null, call ++ ": the timeout .at_most is longer than {d} ms, the most the client counts", .{std.math.maxInt(i64)});
        return error.InvalidArgument;
    }
}
