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
const Address = @import("engine/Address.zig");
const Connection = @import("engine/Connection.zig");
const Pool = @import("engine/Pool.zig");
const blocking = @import("engine/blocking.zig");
const connect_ = @import("engine/connect.zig");
const handshake = @import("engine/handshake.zig");
const time = @import("engine/time.zig");
const Block = @import("cmd/types.zig").Block;

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
/// from now, else none. Its blocking commands may `wait` that long on the
/// server, so `timeout` is the margin after it: no deadline when one waits
/// forever.
pub fn deadlineOf(c: *const Client, io: Io, op: OperationContext, wait: Wait) ?core.Deadline {
    if (op.ctx.deadline) |deadline| return deadline;
    const timeout = c.options.timeout orelse return null;
    const longer: Io.Duration = switch (wait) {
        .none => .zero,
        .at_most => |duration| duration,
        .forever => return null,
    };
    return .after(time.now(io), .{ .nanoseconds = timeout.nanoseconds +| longer.nanoseconds });
}

/// How long the blocking commands of a call wait on the server in all,
/// for the deadline of a call without one of its own.
pub const Wait = union(enum) {
    none,
    at_most: Io.Duration,
    forever,

    fn add(wait: Wait, block: Block) Wait {
        const more = switch (block) {
            .forever => return .forever,
            .at_most => |duration| duration,
        };
        return switch (wait) {
            .none => .{ .at_most = more },
            .at_most => |sum| .{ .at_most = .{ .nanoseconds = sum.nanoseconds +| more.nanoseconds } },
            .forever => .forever,
        };
    }
};

/// The wait of `commands`, a tuple or many of one type: one command is
/// `.{command}`.
pub fn waitOf(commands: anytype) Wait {
    var wait: Wait = .none;
    if (comptime @typeInfo(@TypeOf(commands)) == .@"struct") {
        inline for (@typeInfo(@TypeOf(commands)).@"struct".field_types, 0..) |C, i| {
            if (comptime contract.isBlocking(C)) {
                if (contract.timeoutOf(commands[i])) |block| wait = wait.add(block);
            }
        }
    } else if (comptime contract.isBlocking(contract.Element(@TypeOf(commands)))) {
        for (commands) |command| {
            if (contract.timeoutOf(command)) |block| wait = wait.add(block);
        }
    }
    return wait;
}

/// What the blocking commands of a call may wait on the server, from
/// what is left now of the deadline of its context: null when it has
/// none, or no command of `commands` blocks. Too little left is
/// `DeadlineExceeded`, about the first blocking command and what waits
/// less. Before the pool, `phase` is null; then the check before the
/// write, `.send`, gives the value it writes.
pub fn roomOf(c: *Client, io: Io, op: OperationContext, commands: anytype, phase: ?Diagnostics.Phase, d: ?*Diagnostics) Error!?u64 {
    const first = firstBlocking(commands) orelse return null;
    const deadline = op.ctx.deadline orelse return null;
    const left = deadline.remaining(time.now(io));
    return blocking.room(left, c.round_trips.min(io)) catch return fail(d, phase, error.DeadlineExceeded, "a blocking command needs more than 150 ms left of the deadline beyond the shortest round trip, for a quiet server answers its timeout up to 100 ms late, and {f} had {d} ms: for a shorter wait, use {s}", .{
        Name{ .text = first.name }, @divFloor(left.nanoseconds, std.time.ns_per_ms), first.instead,
    });
}

/// A blocking command, for the text of DeadlineExceeded.
const Blocker = struct {
    name: []const u8,
    instead: []const u8,
};

fn firstBlocking(commands: anytype) ?Blocker {
    if (comptime @typeInfo(@TypeOf(commands)) == .@"struct") {
        inline for (@typeInfo(@TypeOf(commands)).@"struct".field_types, 0..) |C, i| {
            if (comptime contract.isBlocking(C)) {
                if (contract.timeoutOf(commands[i]) != null) return .{ .name = commands[i].name(), .instead = C.blocking.instead };
            }
        }
        return null;
    }
    const C = contract.Element(@TypeOf(commands));
    if (comptime !contract.isBlocking(C)) return null;
    for (commands) |command| {
        if (contract.timeoutOf(command) != null) return .{ .name = command.name(), .instead = C.blocking.instead };
    }
    return null;
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
/// `options.allocator`. A blocking command takes its timeout from the
/// deadline of `op`, if any.
pub fn one(c: *Client, conn: *Connection, io: Io, op: OperationContext, command: anytype, options: RunOptions, deadline: ?core.Deadline, d: ?*Diagnostics) Error!@TypeOf(command).Reply {
    if (comptime contract.isScript(@TypeOf(command))) return script(c, conn, io, op, command, options, deadline, d);
    try beforeSend(c, io, op, deadline, d);
    const room = try roomOf(c, io, op, .{command}, .send, d);
    conn.begin(deadline);
    try writeCommand(conn, command, room, d);
    try conn.flush(d);
    return conn.receive(command, options.allocator, d);
}

/// A script of `redis.Script` alone on `conn`: EVALSHA, its SHA1 only.
/// NOSCRIPT says that the server lacks the script and ran nothing, so its
/// text, EVAL, follows on the same connection, as a new send: no retry.
fn script(c: *Client, conn: *Connection, io: Io, op: OperationContext, command: anytype, options: RunOptions, deadline: ?core.Deadline, d: ?*Diagnostics) Error!@TypeOf(command).Reply {
    try beforeSend(c, io, op, deadline, d);
    const sha: Sha(@TypeOf(command)) = .{ .command = command };
    conn.begin(deadline);
    try conn.write(sha, d);
    try conn.flush(d);
    var own: Diagnostics = .{};
    const why = d orelse &own;
    if (conn.receive(sha, options.allocator, why)) |reply| return reply else |err| {
        if (err != error.ServerError or !why.isCode("NOSCRIPT")) return err;
    }
    why.* = .{};
    try beforeSend(c, io, op, deadline, d);
    try conn.write(command, d);
    try conn.flush(d);
    return conn.receive(command, options.allocator, d);
}

/// The script `C` as EVALSHA, its reply as the script's.
fn Sha(comptime C: type) type {
    return struct {
        command: C,

        pub const Reply = C.Reply;

        pub fn write(s: @This(), w: resp.Writer) resp.Writer.Error!void {
            return s.command.writeSha(w);
        }

        pub fn read(s: @This(), r: *resp.Reader, arena: ?Allocator, d: ?*Diagnostics) resp.DecodeError!C.Reply {
            return s.command.read(r, arena, d);
        }
    };
}

/// Writes `command` into the buffer of `conn`: a blocking one with its
/// timeout within `room`, when the call has a deadline.
fn writeCommand(conn: *Connection, command: anytype, room: ?u64, d: ?*Diagnostics) Error!void {
    if (comptime contract.isBlocking(@TypeOf(command))) if (room) |limit| {
        if (contract.timeoutOf(command)) |block| return conn.writeWith(command, blocking.timeout(block, limit), d);
    };
    return conn.write(command, d);
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
    const room = try roomOf(c, io, op, commands, .send, d);
    // The call has checked the type of the commands: a tuple, or many.
    const tuple = comptime @typeInfo(@TypeOf(commands)) == .@"struct";
    conn.begin(deadline);
    writeCommands(conn, commands, room, d) catch |err| return ended(conn, err, d, 0);
    conn.flush(d) catch |err| return ended(conn, err, d, 0);
    var cells: Cells = .{ .d = d };
    if (tuple) {
        inline for (0..@typeInfo(@TypeOf(commands)).@"struct".field_types.len) |i| {
            results.*[i] = try cells.receive(conn, commands[i], options.allocator, i);
        }
    } else for (commands, results.*, 0..) |command, *slot, i| {
        slot.* = try cells.receive(conn, command, options.allocator, i);
    }
}

/// Writes `commands`, a tuple or many of one type, into the buffer of
/// `conn`, what does not fit going out at once: the blocking ones with
/// their timeouts within `room`, or their own without it.
fn writeCommands(conn: *Connection, commands: anytype, room: ?u64, d: ?*Diagnostics) Error!void {
    if (comptime @typeInfo(@TypeOf(commands)) == .@"struct") {
        inline for (0..@typeInfo(@TypeOf(commands)).@"struct".field_types.len) |i| try writeCommand(conn, commands[i], room, d);
    } else for (commands) |command| try writeCommand(conn, command, room, d);
}

/// How many commands `commands` holds.
fn countOf(commands: anytype) usize {
    if (comptime @typeInfo(@TypeOf(commands)) == .@"struct") return @typeInfo(@TypeOf(commands)).@"struct".field_types.len;
    return commands.len;
}

/// The commands of a transaction on `conn`, which the call has checked,
/// by `deadline`, into `results`: MULTI on its own, then the commands and
/// EXEC in one write, the QUEUED of each, and the replies of EXEC, each in
/// its place as in a pipeline. False when a key under WATCH changed, and
/// the server ran none of them. `watching` turns false once EXEC has gone
/// out, since EXEC ends the WATCH of the connection whatever its outcome.
///
/// A server that drops the transaction answers EXEC with EXECABORT, the
/// ServerError of the call: when it refused a command as it queued it,
/// the diagnostics hold that command's index in `command` and its own
/// error in `refused()`. A reply out of step, a QUEUED where EXEC's array
/// was due or an array of another length, is a ProtocolViolation.
/// Anything that stops the call once MULTI is in leaves the connection
/// unusable, so that it closes rather than stay inside MULTI.
pub fn transaction(c: *Client, conn: *Connection, io: Io, op: OperationContext, commands: anytype, results: anytype, options: RunOptions, deadline: ?core.Deadline, d: ?*Diagnostics, watching: *bool) Error!bool {
    try beforeSend(c, io, op, deadline, d);
    // MULTI goes on its own: a server that refuses it, such as for a user
    // without +multi, gets none of the commands, which would run outside a
    // transaction in one write with it.
    conn.exchange(Multi{}, null, deadline, d) catch |err| return ended(conn, err, d, 0);
    var answered: usize = 1;
    beforeSend(c, io, op, deadline, d) catch |err| {
        conn.usable = false;
        return err;
    };
    // Nothing blocks inside a transaction: the timeouts go as given.
    writeCommands(conn, commands, null, d) catch |err| return ended(conn, err, d, answered);
    conn.write(Exec{}, d) catch |err| return ended(conn, err, d, answered);
    conn.flush(d) catch |err| return ended(conn, err, d, answered);
    watching.* = false;

    // QUEUED for each command, or the error of its refusal: the first
    // refusal is what EXECABORT is about.
    var queue: Diagnostics = .{};
    var refusal: ?usize = null;
    var refused: Diagnostics = .{};
    for (0..countOf(commands)) |i| {
        conn.receive(Queued{}, null, &queue) catch |err| switch (err) {
            error.ServerError => if (refusal == null) {
                refusal = i;
                refused = queue;
            },
            else => {
                if (d) |x| x.* = queue;
                return ended(conn, err, d, answered);
            },
        };
        answered += 1;
    }

    var cells: Cells = .{ .d = d };
    const exec: ExecReply(@TypeOf(commands), @TypeOf(results)) = .{ .commands = commands, .results = results, .cells = &cells };
    return conn.receive(exec, options.allocator, d) catch |err| {
        if (err == error.ServerError) {
            if (d) |x| if (x.isCode("EXECABORT")) if (refusal) |i| {
                x.command = i;
                x.setRefused(refused.message());
            };
            return err;
        }
        // Not about the command of an error inside EXEC that came before.
        if (d) |x| x.command = null;
        return ended(conn, err, d, answered);
    };
}

/// The error that ends a pipeline or a transaction after `answered`
/// replies: a reply out of step is a ProtocolViolation, which closes the
/// connection; an error of the server is the call's as it is; any other
/// error the exchange's, with the count of replies in the diagnostics.
fn ended(conn: *Connection, err: Error, d: ?*Diagnostics, answered: usize) Error {
    if (err == error.ServerError) return err;
    if (d) |x| x.answered = answered;
    if (err != error.UnexpectedReply) return err;
    conn.usable = false;
    return error.ProtocolViolation;
}

/// MULTI, whose reply is +OK.
const Multi = struct {
    pub const Reply = void;

    pub fn write(_: Multi, w: resp.Writer) resp.Writer.Error!void {
        try w.command(&.{"MULTI"});
    }

    pub fn read(_: Multi, r: *resp.Reader, _: ?Allocator, d: ?*Diagnostics) resp.DecodeError!void {
        return confirmation(r, "OK", d, "MULTI was answered with {f}, where +OK was due");
    }
};

/// The reply of a command queued in a transaction: +QUEUED, or the error
/// of its refusal.
const Queued = struct {
    pub const Reply = void;

    pub fn read(_: Queued, r: *resp.Reader, _: ?Allocator, d: ?*Diagnostics) resp.DecodeError!void {
        return confirmation(r, "QUEUED", d, "a command of the transaction was answered with {f}, where +QUEUED was due");
    }
};

/// EXEC, whose reply `ExecReply` reads.
const Exec = struct {
    pub fn write(_: Exec, w: resp.Writer) resp.Writer.Error!void {
        try w.command(&.{"EXEC"});
    }
};

/// Reads a reply that must be the simple string `expected`: an error is
/// ServerError, anything else UnexpectedReply with `text` about what came.
/// The rest of an aggregate stays unread: the stream is out of step, and
/// the connection closes.
fn confirmation(r: *resp.Reader, comptime expected: []const u8, d: ?*Diagnostics, comptime text: []const u8) resp.DecodeError!void {
    const first = try r.next();
    var len: ?usize = null;
    switch (first) {
        .simple_error, .bulk_error => {
            var decoder: resp.Decoder = .{ .reader = r, .arena = null, .diagnostics = d };
            return decoder.serverError();
        },
        .simple_string => {
            var buffer: [expected.len]u8 = undefined;
            const got = try r.payloadPrefix(&buffer);
            if (got.len == expected.len and std.mem.eql(u8, got.bytes, expected)) return;
            len = got.len;
        },
        else => {},
    }
    if (d) |x| x.set(.receive, null, text, .{resp.Kind{ .element = first, .len = len }});
    return error.UnexpectedReply;
}

/// The reply of EXEC: null when a key under WATCH changed, an error when
/// the server dropped the transaction, or an array of the replies of the
/// commands, each of which its command reads into its place of `results`,
/// as a reply of its own.
fn ExecReply(comptime Commands: type, comptime Results: type) type {
    return struct {
        commands: Commands,
        results: Results,
        cells: *Cells,

        const Self = @This();
        /// False when a key under WATCH changed.
        pub const Reply = bool;

        pub fn read(e: Self, r: *resp.Reader, arena: ?Allocator, d: ?*Diagnostics) resp.DecodeError!bool {
            const first = try r.next();
            const n = countOf(e.commands);
            var len: ?usize = null;
            switch (first) {
                .null => return false,
                .simple_error, .bulk_error => {
                    var decoder: resp.Decoder = .{ .reader = r, .arena = null, .diagnostics = d };
                    return decoder.serverError();
                },
                .array => |count| if (count == n) {
                    if (comptime @typeInfo(Commands) == .@"struct") {
                        inline for (0..@typeInfo(Commands).@"struct".field_types.len) |i| e.results.*[i] = try e.cell(r, e.commands[i], arena, i);
                    } else for (e.commands, e.results.*, 0..) |command, *slot, i| {
                        slot.* = try e.cell(r, command, arena, i);
                    }
                    return true;
                },
                .simple_string => {
                    var none: [0]u8 = undefined;
                    len = (try r.payloadPrefix(&none)).len;
                },
                else => {},
            }
            if (d) |x| x.set(.receive, null, "EXEC was answered with {f}, where an array of {d} replies was due", .{ resp.Kind{ .element = first, .len = len }, n });
            return error.UnexpectedReply;
        }

        /// The reply of command `i`, the next element of the array of EXEC.
        fn cell(e: Self, r: *resp.Reader, command: anytype, arena: ?Allocator, i: usize) resp.DecodeError!(CommandError!@TypeOf(command).Reply) {
            var element = r.nested();
            const result: CommandError!@TypeOf(command).Reply = if (command.read(&element, arena, e.cells.sink())) |value| value else |err| switch (err) {
                error.ServerError, error.UnexpectedReply => |failed| failed: {
                    e.cells.note(i);
                    break :failed failed;
                },
                else => |other| return other,
            };
            r.rejoin(&element);
            return result;
        }
    };
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
        return conn.receive(command, arena, cells.sink()) catch |err| switch (err) {
            error.ServerError, error.UnexpectedReply => |e| {
                cells.note(i);
                return @as(CommandError!@TypeOf(command).Reply, e);
            },
            else => |e| {
                if (cells.d) |x| if (cells.recorded) {
                    x.* = cells.scratch;
                };
                return ended(conn, e, cells.d, i);
            },
        };
    }

    /// Where the next error of a command goes.
    fn sink(cells: *Cells) ?*Diagnostics {
        if (cells.d == null) return null;
        return if (cells.recorded) &cells.scratch else cells.d;
    }

    /// Notes an error of the command `i`: the first stays in the caller's
    /// diagnostics, with its index.
    fn note(cells: *Cells, i: usize) void {
        if (!cells.recorded) if (cells.d) |x| {
            x.command = i;
        };
        cells.recorded = true;
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

/// Opens a connection to the client's server, the handshake included,
/// within `connect_timeout` and `deadline`, whichever ends first: for the
/// pool, and for a subscriber, whose connection is its own. `attempt` lets
/// `close` stop it.
pub fn open(c: *Client, io: Io, deadline: ?core.Deadline, attempt: *connect_.Attempt, d: ?*Diagnostics) Error!*Connection {
    const url = &c.options.url;
    // The host is in the copy of the URL, which outlives the connection.
    const address: Address = .{ .host = url.host, .port = url.port };
    const budget = connect_.budget(time.now(io), c.options.connect_timeout, deadline);
    const setup = handshake.setupOf(&c.options);
    const conn = connect_.open(io, c.gpa, address, c.options.max_reply_bytes, &setup, budget.deadline, attempt, d) catch |err| return switch (err) {
        error.Unavailable, error.Unsupported, error.AuthenticationFailed, error.InvalidArgument, error.OutOfMemory => |e| e,
        error.Timeout => switch (budget.by) {
            .deadline => fail(d, .connect, error.DeadlineExceeded, "the deadline passed while the client connected to {f}", .{address}),
            .connect_timeout => fail(d, .connect, error.Unavailable, "{f} did not answer within connect_timeout ({d} ms)", .{ address, c.options.connect_timeout.toMilliseconds() }),
        },
        error.Canceled => cancelled(io, d, "the task was canceled while the client connected"),
        error.Stopped => fail(d, .connect, error.Closed, "the client was closed while it connected", .{}),
        error.ConcurrencyUnavailable => {
            if (d) |x| x.set(.connect, err, "no task to connect to {f} in: the std.Io has no room for one", .{address});
            return error.Unavailable;
        },
    };
    if (conn.rtt) |rtt| c.round_trips.add(io, rtt);
    return conn;
}

/// `error.Cancelled` of a task that was canceled while the client
/// connected, which stays canceled.
pub fn cancelled(io: Io, d: ?*Diagnostics, comptime text: []const u8) Error {
    io.recancel();
    return fail(d, .connect, error.Cancelled, text, .{});
}

pub fn fail(d: ?*Diagnostics, phase: ?Diagnostics.Phase, err: Error, comptime fmt: []const u8, args: anytype) Error {
    if (d) |x| x.set(phase, null, fmt, args);
    return err;
}
