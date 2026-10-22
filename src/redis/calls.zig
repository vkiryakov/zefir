//! How a call of `redis.Client` or `redis.Conn` runs, internal to the
//! module: the checks before anything goes out, the deadline, the
//! exchange of one command and of a pipeline on a connection, and what an
//! error leaves of the connection. `Client.zig` and `Conn.zig` hold the
//! public methods and take a connection for them.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const errors = @import("errors.zig");
const Error = errors.Error;
const CommandError = errors.CommandError;
const Diagnostics = errors.Diagnostics;
const requests = @import("requests.zig");
const OperationContext = requests.OperationContext;
const RunOptions = requests.RunOptions;
const contract = @import("cmd/contract.zig");
const resp = @import("resp.zig");
const Client = @import("Client.zig");
const Connection = @import("engine/Connection.zig");
const Pool = @import("engine/Pool.zig");
const time = @import("engine/time.zig");

/// In safe builds: a call on a moved copy of the client, or on another
/// `std.Io` than the one of `init`, panics, since the connections and the
/// waits of the client belong to the original and its `io`.
pub fn checkUse(c: *const Client, io: Io) void {
    checkHome(c);
    if (std.debug.runtime_safety and io.vtable != c.io.vtable) {
        @panic("zefir-redis: a call on another std.Io than the client's: pass the io of Client.init");
    }
}

pub inline fn checkHome(c: *const Client) void {
    if (std.debug.runtime_safety) {
        const home = c.home.load(.monotonic);
        if (home != 0 and home != @intFromPtr(c)) @panic("zefir-redis: Client moved after connect(): keep it where connect() ran (see the guide)");
    }
}

/// The deadline of a call that starts now: its context's, else `timeout`
/// from now, else none.
pub fn deadlineOf(c: *const Client, io: Io, op: OperationContext) ?core.Deadline {
    if (op.ctx.deadline) |deadline| return deadline;
    const timeout = c.options.timeout orelse return null;
    return .after(time.now(io), timeout);
}

/// The rules of the command before anything else of a call: its own, then
/// the memory its reply needs. A broken one is `error.InvalidArgument`,
/// and nothing goes out.
pub fn checkCommand(command: anytype, options: RunOptions, d: ?*Diagnostics) Error!void {
    try command.check(d);
    const Reply = @TypeOf(command).Reply;
    if (comptime resp.needsAllocator(Reply)) if (options.allocator == null) {
        return fail(d, null, error.InvalidArgument, "the reply of {f} holds {s}: pass .allocator", .{ Name{ .text = command.name() }, comptime holds(Reply) });
    };
}

/// The rules of the commands of a pipeline or a transaction, before
/// anything else of the call: one command at least, each by
/// `checkCommand`, and `.allocator` for the slice of results of many
/// commands of one type. The first command that breaks one is the error,
/// with its index in `Diagnostics.command`; nothing goes out.
pub fn checkCommands(commands: anytype, options: RunOptions, d: ?*Diagnostics, comptime call: []const u8) Error!void {
    const none = call ++ ": no commands: pass one or more";
    if (comptime contract.isTuple(@TypeOf(commands), call)) {
        const n = @typeInfo(@TypeOf(commands)).@"struct".field_types.len;
        if (n == 0) return fail(d, null, error.InvalidArgument, none, .{});
        inline for (0..n) |i| try checkAt(commands[i], options, d, i);
    } else {
        if (commands.len == 0) return fail(d, null, error.InvalidArgument, none, .{});
        if (options.allocator == null) return fail(d, null, error.InvalidArgument, call ++ ": the results of a slice of commands are a slice: pass .allocator", .{});
        for (commands, 0..) |command, i| try checkAt(command, options, d, i);
    }
}

fn checkAt(command: anytype, options: RunOptions, d: ?*Diagnostics, i: usize) Error!void {
    checkCommand(command, options, d) catch |err| {
        if (d) |x| x.command = i;
        return err;
    };
}

/// What a reply type that takes memory holds, for a text: strings, or
/// slices when it holds no string.
fn holds(comptime T: type) []const u8 {
    return if (holdsString(T)) "strings" else "slices";
}

fn holdsString(comptime T: type) bool {
    if (T == []const u8 or T == resp.Value) return true;
    return switch (@typeInfo(T)) {
        .optional => |info| holdsString(info.child),
        .array => |info| holdsString(info.child),
        .pointer => |info| holdsString(info.child),
        inline .@"struct", .@"union" => |info| for (info.field_types) |F| {
            if (holdsString(F)) break true;
        } else false,
        else => false,
    };
}

/// The name of a command in a text: its first 32 bytes, each outside
/// printable ASCII shown as '?'.
pub const Name = struct {
    text: []const u8,

    pub fn format(n: Name, w: *Io.Writer) Io.Writer.Error!void {
        const shown = n.text[0..@min(n.text.len, 32)];
        for (shown) |c| try w.writeByte(if (c >= 0x21 and c <= 0x7E) c else '?');
        if (n.text.len > shown.len) try w.writeAll("...");
    }
};

/// The caller's context before a call: `DeadlineExceeded` with less than
/// 1 ms left, else `Cancelled` when its token is canceled.
pub fn checkContext(io: Io, op: OperationContext, d: ?*Diagnostics) Error!void {
    if (op.ctx.remaining(time.now(io))) |left| if (left.nanoseconds < std.time.ns_per_ms) {
        return fail(d, null, error.DeadlineExceeded, "less than 1 ms was left of the deadline before the call", .{});
    };
    if (op.ctx.isCancelled()) return fail(d, null, error.Cancelled, "the token was canceled before the call", .{});
}

/// The checks of a command about to go out on its connection: less than
/// 1 ms of the deadline left, or less than the shortest round trip, is
/// `DeadlineExceeded`; a token or a task canceled meanwhile is
/// `Cancelled`. The connection stays as it was.
pub fn beforeSend(c: *Client, io: Io, op: OperationContext, deadline: ?core.Deadline, d: ?*Diagnostics) Error!void {
    if (deadline) |limit| {
        const left = limit.remaining(time.now(io));
        if (left.nanoseconds < std.time.ns_per_ms) {
            return fail(d, .send, error.DeadlineExceeded, "less than 1 ms was left of the deadline before the command went out", .{});
        }
        const shortest = c.round_trips.min(io);
        if (left.nanoseconds < shortest.nanoseconds) {
            return fail(d, .send, error.DeadlineExceeded, "less of the deadline was left than the shortest round trip to the server ({d} us) before the command went out", .{shortest.toMicroseconds()});
        }
    }
    if (op.ctx.isCancelled()) return fail(d, .send, error.Cancelled, "the token was canceled before the command went out", .{});
    io.checkCancel() catch {
        io.recancel();
        return fail(d, .send, error.Cancelled, "the task was canceled before the command went out", .{});
    };
}

/// One command on `conn`, which the call has checked, by `deadline`: the
/// checks before it goes out, the write, and its reply from
/// `options.allocator`.
pub fn one(c: *Client, conn: *Connection, io: Io, op: OperationContext, command: anytype, options: RunOptions, deadline: ?core.Deadline, d: ?*Diagnostics) Error!@TypeOf(command).Reply {
    try beforeSend(c, io, op, deadline, d);
    return conn.exchange(command, options.allocator, deadline, d);
}

/// Where the results of a pipeline of `R` go while its replies come: a
/// tuple, or the slice from `options.allocator`.
pub fn Slots(comptime R: type) type {
    return switch (@typeInfo(R)) {
        .pointer => |info| []info.child,
        else => R,
    };
}

/// The memory of the results of `commands`, taken before anything goes
/// out: for many commands of one type, a slice from `options.allocator`.
pub fn slots(comptime R: type, commands: anytype, options: RunOptions) error{OutOfMemory}!Slots(R) {
    return switch (@typeInfo(R)) {
        .pointer => |info| options.allocator.?.alloc(info.child, commands.len),
        else => undefined,
    };
}

/// The commands of a pipeline on `conn`, which the call has checked, by
/// `deadline`: the checks before they go out, all of them in one write,
/// cut only where the buffer of the connection fills up, then their
/// replies in order, into `results`. An error of one command,
/// `ServerError` or `UnexpectedReply`, is the value in its place, and the
/// diagnostics hold the first of them with its index in `command`. Any
/// other error ends the exchange: the diagnostics say how many replies
/// came in `answered`, and the connection is no longer usable.
pub fn many(c: *Client, conn: *Connection, io: Io, op: OperationContext, commands: anytype, results: anytype, options: RunOptions, deadline: ?core.Deadline, d: ?*Diagnostics) Error!void {
    try beforeSend(c, io, op, deadline, d);
    // The call has checked the type of the commands: a tuple, or many.
    const tuple = comptime @typeInfo(@TypeOf(commands)) == .@"struct";
    conn.begin(deadline);
    writeAll(conn, commands, tuple, d) catch |err| {
        if (d) |x| x.answered = 0;
        return err;
    };
    var cells: Cells = .{ .d = d };
    if (tuple) {
        inline for (0..@typeInfo(@TypeOf(commands)).@"struct".field_types.len) |i| {
            results.*[i] = try cells.receive(conn, commands[i], options.allocator, i);
        }
    } else for (commands, results.*, 0..) |command, *slot, i| {
        slot.* = try cells.receive(conn, command, options.allocator, i);
    }
}

fn writeAll(conn: *Connection, commands: anytype, comptime tuple: bool, d: ?*Diagnostics) Error!void {
    if (tuple) {
        inline for (0..@typeInfo(@TypeOf(commands)).@"struct".field_types.len) |i| try conn.write(commands[i], d);
    } else for (commands) |command| try conn.write(command, d);
    try conn.flush(d);
}

/// The replies of a pipeline as they come: the caller's diagnostics take
/// the first error of a command, a scratch the later ones, and an error
/// that ends the exchange goes to the caller's, with the count of replies
/// that came.
const Cells = struct {
    d: ?*Diagnostics,
    /// The errors of commands after the first.
    scratch: Diagnostics = .{},
    /// Whether the caller's diagnostics hold the first error of a command.
    recorded: bool = false,

    fn receive(cells: *Cells, conn: *Connection, command: anytype, arena: ?Allocator, i: usize) Error!(CommandError!@TypeOf(command).Reply) {
        const sink: ?*Diagnostics = if (cells.d == null) null else if (cells.recorded) &cells.scratch else cells.d;
        return conn.receive(command, arena, sink) catch |err| switch (err) {
            error.ServerError, error.UnexpectedReply => |e| {
                if (!cells.recorded) if (cells.d) |x| {
                    x.command = i;
                };
                cells.recorded = true;
                return @as(CommandError!@TypeOf(command).Reply, e);
            },
            else => |e| {
                if (cells.d) |x| {
                    if (cells.recorded) x.* = cells.scratch;
                    x.answered = i;
                }
                return e;
            },
        };
    }
};

/// What an exchange that failed leaves of its connection: a network error
/// on it clears the pool, since the other connections are likely gone
/// too; a cut is `close`'s; a timeout, a cancelation, a broken or too
/// large reply and memory that ran out close it only; an error of the
/// server, a reply that did not fit and a check before sending leave it
/// as it was.
pub fn afterExchange(conn: *Connection, err: Error, d: ?*Diagnostics) Pool.After {
    if (err != error.ConnectionLost) return if (conn.usable) .ok else .broken;
    const cause = conn.stream.err orelse return .{ .clear = "a connection to it broke" };
    if (cause != error.Stopped) return .{ .clear = "a connection to it broke" };
    // The phase stays: the cut may come while the command goes out.
    if (d) |x| x.set(x.phase, null, "close() of the client cut the exchange", .{});
    return .broken;
}

pub fn fail(d: ?*Diagnostics, phase: ?Diagnostics.Phase, err: Error, comptime fmt: []const u8, args: anytype) Error {
    if (d) |x| x.set(phase, null, fmt, args);
    return err;
}
