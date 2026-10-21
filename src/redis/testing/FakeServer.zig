//! `redis.testing.FakeServer`: a Redis server for tests, on loopback. A
//! test starts it with a script, points a real `redis.Client` at its
//! `url()` and checks the code under test without Redis: deadlines,
//! cancelation and errors in such a test are real, and the delays of the
//! script are real sleeps.
//!
//! ```zig
//! var server: redis.testing.FakeServer = try .start(gpa, io, &.{
//!     .expect(.{ "HGETALL", "user:42" }, .map(&.{ .{ "name", "Ann" }, .{ "plan", "pro" } })),
//! });
//! defer server.stop(io);
//! // ... a redis.Client on server.url() runs the code under test ...
//! try server.finish(io); // the script ran to its end, and nothing else came
//! ```
//!
//! What the server does with a command:
//!
//! - It answers the handshake itself and keeps it out of the journal:
//!   `HELLO` by `Options.hello` (with a password, `WRONGPASS` for a wrong
//!   one and `NOAUTH` without one), `CLIENT SETINFO` with `+OK`, `SELECT`
//!   with `+OK` for the databases 0 to 15. It answers `PING` with `+PONG`
//!   too, so that the client's checks of idle connections stay out of the
//!   script's way; a `PING` does go to the journal.
//! - Every other command goes to the journal, and to the script. When it
//!   is the command the next step expects, its name in any case and its
//!   arguments byte for byte, that step answers it, and the `send` steps
//!   right after it follow on the same connection. The steps run in the
//!   order the commands arrive, on all connections together.
//! - A command that the next step does not expect gets
//!   `-ERR zefir FakeServer: unexpected command …`, and `finish` names it.
//! - Bytes that are not a command, an array of bulk strings, get a
//!   protocol error, as from Redis, and the connection closes.
//!
//! The server speaks RESP3 only: `HELLO 2` gets `NOPROTO`. It serves each
//! connection in a task of its own on the `io` of `start`, until the
//! client closes it or `stop` ends it; the steps, and what they point to,
//! must live until `stop`. The arguments of `Step.expect` and of the
//! helpers of `Reply` are comptime literals, so their memory is static.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const replies = @import("reply.zig");
const command = @import("command.zig");
const sleepAtLeast = @import("sleep.zig").sleepAtLeast;
const isString = @import("../resp/args.zig").isString;

const FakeServer = @This();

/// What the server's tasks share, in the heap: they point into it. Null
/// once the server is stopped.
state: ?*State,

pub const Reply = replies.Reply;
pub const Delayed = replies.Delayed;
pub const Malformed = replies.Malformed;

pub const Options = struct {
    /// The script, in the order its steps run.
    steps: []const Step = &.{},
    /// What the server says about itself in HELLO, and the password it
    /// takes.
    hello: Hello = .{},
};

/// The fields of the map that HELLO answers with, as a standalone Redis
/// 8.10.2 without a password has them unless the test says otherwise.
pub const Hello = struct {
    /// "redis", or "valkey".
    server: []const u8 = "redis",
    version: []const u8 = "8.10.2",
    /// "standalone", "cluster" or "sentinel".
    mode: []const u8 = "standalone",
    /// "master" or "replica".
    role: []const u8 = "master",
    /// The password of every user, which HELLO must carry in AUTH; the
    /// user's name is not checked. Null: HELLO needs none, and takes any.
    password: ?[]const u8 = null,
};

/// A step of the script.
pub const Step = struct {
    /// `expect` waits for a command; `send` sends without one.
    kind: enum { expect, send },
    /// The command that the step expects, the name first; empty for a
    /// `send`.
    args: []const []const u8,
    reply: Reply,

    /// Expects the command `args`, a tuple of strings such as
    /// `.{ "GET", "session:42" }`, and answers it with `reply`.
    pub fn expect(comptime args: anytype, reply: Reply) Step {
        const list = comptime strings(args);
        return .{ .kind = .expect, .args = &list, .reply = reply };
    }

    /// Sends `reply` without a request, on the connection of the step
    /// before it, right after that step's reply: a message to a
    /// subscriber. A script does not start with one.
    pub fn send(reply: Reply) Step {
        return .{ .kind = .send, .args = &.{}, .reply = reply };
    }
};

fn strings(comptime args: anytype) [args.len][]const u8 {
    const call = "redis.testing.FakeServer.Step.expect";
    const info = @typeInfo(@TypeOf(args));
    if (info != .@"struct" or !info.@"struct".is_tuple) @compileError(call ++ ": the command is a tuple of strings, such as .{ \"GET\", \"k\" }; got " ++ @typeName(@TypeOf(args)));
    if (args.len == 0) @compileError(call ++ ": no arguments: the first is the name of the command");
    var list: [args.len][]const u8 = undefined;
    for (info.@"struct".field_types, 0..) |T, i| {
        if (!isString(T)) @compileError(std.fmt.comptimePrint(call ++ ": args[{d}] is {s}: the arguments are strings, such as \"10\" for a number", .{ i, @typeName(T) }));
        list[i] = args[i];
    }
    return list;
}

/// A command in the journal.
pub const Entry = struct {
    /// The command, the name first, as the client wrote it: copies that
    /// live until `stop`.
    args: []const []const u8,
    /// The number of the connection it came on: 1 for the first connection
    /// to the server, 2 for the next, and so on.
    connection: u32,
};

/// Listens on 127.0.0.1, on a port the system picks, and plays `steps`.
pub fn start(gpa: Allocator, io: Io, steps: []const Step) !FakeServer {
    return startWith(gpa, io, .{ .steps = steps });
}

/// Listens on 127.0.0.1, on a port the system picks, and serves by
/// `options`. `gpa` must be thread-safe, such as `std.testing.allocator`:
/// the tasks of the connections keep their buffers and the journal in it.
pub fn startWith(gpa: Allocator, io: Io, options: Options) !FakeServer {
    const loopback: net.IpAddress = try .parseIp4("127.0.0.1", 0);
    const state = try gpa.create(State);
    errdefer gpa.destroy(state);
    state.* = .{
        .gpa = gpa,
        .io = io,
        .listener = try loopback.listen(io, .{ .reuse_address = true }),
        .steps = options.steps,
        .hello = options.hello,
    };
    errdefer state.listener.deinit(io);
    const port = state.listener.socket.address.getPort();
    state.url_len = (std.fmt.bufPrint(&state.url_buffer, "redis://127.0.0.1:{d}", .{port}) catch unreachable).len;
    state.serving = try io.concurrent(serve, .{state});
    return .{ .state = state };
}

/// "redis://127.0.0.1:<port>", for `redis.Client.Options.url`; empty once
/// the server is stopped.
pub fn url(server: *const FakeServer) []const u8 {
    const state = server.state orelse return "";
    return state.url_buffer[0..state.url_len];
}

/// Fails when a command came that the script did not expect, or a step
/// has not run, and prints which, as `std.testing.expectEqual` prints what
/// it found. Call it before `stop`, which forgets the script.
pub fn finish(server: *FakeServer, io: Io) error{ ScriptNotFinished, UnexpectedCommand }!void {
    var why: Description = .{};
    server.verdict(io, &why) catch |err| {
        std.debug.print("zefir FakeServer: {s}\n", .{why.text()});
        return err;
    };
}

/// What `finish` fails with, with the reason in `why`, without printing
/// it.
fn verdict(server: *FakeServer, io: Io, why: *Description) error{ ScriptNotFinished, UnexpectedCommand }!void {
    const state = server.state orelse {
        why.* = .of("finish after stop, which forgot the script; call finish first", .{});
        return error.ScriptNotFinished;
    };
    state.mutex.lockUncancelable(io);
    defer state.mutex.unlock(io);
    if (state.unexpected) |*first| {
        why.* = .of("{s}, on connection {d}", .{ first.why.text(), first.connection });
        return error.UnexpectedCommand;
    }
    if (state.next < state.steps.len) {
        why.* = .notRun(state.steps, state.next);
        return error.ScriptNotFinished;
    }
}

/// Stops the server: ends its connections, which their clients see as the
/// end of the stream, closes its port and frees the journal. Idempotent;
/// call it from one task at a time.
pub fn stop(server: *FakeServer, io: Io) void {
    const state = server.state orelse return;
    server.state = null;
    state.serving.cancel(io);
    state.listener.deinit(io);
    for (state.journal.items) |recorded| recorded.free(state.gpa);
    state.journal.deinit(state.gpa);
    state.gpa.destroy(state);
}

/// How many commands the journal holds.
pub fn received(server: *FakeServer, io: Io) usize {
    const state = server.state orelse return 0;
    state.mutex.lockUncancelable(io);
    defer state.mutex.unlock(io);
    return state.journal.items.len;
}

/// The command number `i` of the journal, from 0, or `error.NotReceived`
/// while the journal holds no more than `i` commands.
pub fn entry(server: *FakeServer, io: Io, i: usize) error{NotReceived}!Entry {
    const state = server.state orelse return error.NotReceived;
    state.mutex.lockUncancelable(io);
    defer state.mutex.unlock(io);
    if (i >= state.journal.items.len) return error.NotReceived;
    return state.journal.items[i].entry();
}

/// How many commands of the journal are named `name`, in any case.
pub fn count(server: *FakeServer, io: Io, name: []const u8) usize {
    const state = server.state orelse return 0;
    state.mutex.lockUncancelable(io);
    defer state.mutex.unlock(io);
    var n: usize = 0;
    for (state.journal.items) |recorded| {
        if (std.ascii.eqlIgnoreCase(recorded.args[0], name)) n += 1;
    }
    return n;
}

/// Accepts connections again after a `refuse_connections` reply: the
/// server is back.
pub fn acceptConnections(server: *FakeServer, io: Io) void {
    _ = io;
    const state = server.state orelse return;
    state.refusing.store(false, .release);
}

const State = struct {
    gpa: Allocator,
    io: Io,
    listener: net.Server,
    url_buffer: [32]u8 = undefined,
    url_len: usize = 0,
    steps: []const Step,
    hello: Hello,
    /// The task that accepts connections.
    serving: Io.Future(void) = undefined,
    /// Guards the script's place, the journal and `unexpected`.
    mutex: Io.Mutex = .init,
    /// The step that runs next.
    next: usize = 0,
    journal: std.ArrayList(Recorded) = .empty,
    /// The first command that the script did not expect.
    unexpected: ?Unexpected = null,
    /// How many connections were served: the number of the last one.
    connections: std.atomic.Value(u32) = .init(0),
    refusing: std.atomic.Value(bool) = .init(false),
    served: Served = .{},

    /// Adds a copy of `args`, a command that came on the connection
    /// `number`, to the journal.
    fn record(state: *State, number: u32, args: []const []const u8) Allocator.Error!void {
        const copy: Recorded = try .of(state.gpa, number, args);
        errdefer copy.free(state.gpa);
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        try state.journal.append(state.gpa, copy);
    }

    /// Adds `args`, a command that came on the connection `number`, to the
    /// journal and finds what answers it, in one step, so that the journal
    /// and the script see the commands in the same order.
    fn take(state: *State, number: u32, args: []const []const u8) Allocator.Error!Plan {
        const copy: Recorded = try .of(state.gpa, number, args);
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        state.journal.append(state.gpa, copy) catch |err| {
            copy.free(state.gpa);
            return err;
        };
        const steps = state.steps;
        if (state.next < steps.len and expects(steps[state.next], args)) {
            const first = state.next;
            var end = first + 1;
            while (end < steps.len and steps[end].kind == .send) end += 1;
            state.next = end;
            return .{ .steps = steps[first..end] };
        }
        const why: Description = .unexpectedCommand(args, if (state.next < steps.len) steps[state.next] else null);
        if (state.unexpected == null) state.unexpected = .{ .why = why, .connection = number };
        return .{ .unexpected = why };
    }

    /// Notes bytes that are not a command, which came on the connection
    /// `number`, for `finish`.
    fn notCommand(state: *State, number: u32) void {
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        if (state.unexpected == null) state.unexpected = .{
            .why = .of("bytes that are not a command, an array of bulk strings", .{}),
            .connection = number,
        };
    }

    /// Ends every connection and refuses new ones: the server went away.
    fn refuse(state: *State) void {
        state.refusing.store(true, .release);
        state.served.shutAll(state.io);
    }
};

/// Whether `step` expects `args`: the name in any case, the rest byte for
/// byte.
fn expects(step: Step, args: []const []const u8) bool {
    if (step.kind != .expect or step.args.len != args.len) return false;
    if (!std.ascii.eqlIgnoreCase(step.args[0], args[0])) return false;
    for (step.args[1..], args[1..]) |want, got| {
        if (!std.mem.eql(u8, want, got)) return false;
    }
    return true;
}

/// What answers a command.
const Plan = union(enum) {
    /// The step that expects it, and the `send` steps after it.
    steps: []const Step,
    /// Nothing: the error says why.
    unexpected: Description,
};

/// The first command that the script did not expect, for `finish`.
const Unexpected = struct {
    why: Description,
    /// The number of the connection it came on.
    connection: u32,
};

/// What went wrong, as the error of the server and `finish` say it: a
/// line of at most 256 bytes, cut there if longer.
const Description = struct {
    buffer: [256]u8 = undefined,
    len: usize = 0,

    fn of(comptime fmt: []const u8, args: anytype) Description {
        var why: Description = .{};
        var w: Io.Writer = .fixed(&why.buffer);
        w.print(fmt, args) catch {};
        why.len = w.end;
        return why;
    }

    /// Why the script does not take `args`, when `next` is the step that
    /// runs next.
    fn unexpectedCommand(args: []const []const u8, next: ?Step) Description {
        var why: Description = .{};
        var w: Io.Writer = .fixed(&why.buffer);
        writeUnexpected(&w, args, next) catch {};
        why.len = w.end;
        return why;
    }

    fn writeUnexpected(w: *Io.Writer, args: []const []const u8, next: ?Step) Io.Writer.Error!void {
        try w.writeAll("unexpected command '");
        try command.writePrintable(w, args[0]);
        try w.writeAll("': ");
        const step = next orelse return w.writeAll("no step is left");
        switch (step.kind) {
            .send => try w.writeAll("the next step is a send, which runs after the step before it"),
            .expect => {
                try w.writeAll("the next step expects '");
                try command.writePrintable(w, step.args[0]);
                try w.writeAll("'");
                if (std.ascii.eqlIgnoreCase(step.args[0], args[0])) try w.writeAll(" with other arguments");
            },
        }
    }

    /// Which step of `steps` has not run: the one at `next`.
    fn notRun(steps: []const Step, next: usize) Description {
        var why: Description = .{};
        var w: Io.Writer = .fixed(&why.buffer);
        writeNotRun(&w, steps, next) catch {};
        why.len = w.end;
        return why;
    }

    fn writeNotRun(w: *Io.Writer, steps: []const Step, next: usize) Io.Writer.Error!void {
        try w.print("{d} of the {d} steps ran; step {d} ", .{ next, steps.len, next });
        const step = steps[next];
        switch (step.kind) {
            .send => try w.writeAll("is a send, which runs after the step before it"),
            .expect => {
                try w.writeAll("expects '");
                try command.writePrintable(w, step.args[0]);
                try w.writeAll("'");
            },
        }
    }

    fn text(why: *const Description) []const u8 {
        return why.buffer[0..why.len];
    }
};

/// A command of the journal and the memory of its copy.
const Recorded = struct {
    args: [][]const u8,
    bytes: []u8,
    connection: u32,

    fn of(gpa: Allocator, number: u32, args: []const []const u8) Allocator.Error!Recorded {
        var len: usize = 0;
        for (args) |arg| len += arg.len;
        const bytes = try gpa.alloc(u8, len);
        errdefer gpa.free(bytes);
        const copies = try gpa.alloc([]const u8, args.len);
        var at: usize = 0;
        for (args, copies) |arg, *slot| {
            @memcpy(bytes[at..][0..arg.len], arg);
            slot.* = bytes[at..][0..arg.len];
            at += arg.len;
        }
        return .{ .args = copies, .bytes = bytes, .connection = number };
    }

    fn free(recorded: Recorded, gpa: Allocator) void {
        gpa.free(recorded.args);
        gpa.free(recorded.bytes);
    }

    fn entry(recorded: Recorded) Entry {
        return .{ .args = recorded.args, .connection = recorded.connection };
    }
};

/// Accepts connections until canceled, which ends them too, and serves
/// each in a task of its own. While the server refuses connections, a
/// new one is closed at once. An error of `accept` that costs one
/// connection, such as a client that dropped it, is skipped; after any
/// other, such as running out of file descriptors, the server pauses for
/// 10 ms and goes on.
fn serve(state: *State) void {
    const io = state.io;
    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = state.listener.accept(io) catch |err| switch (err) {
            error.Canceled => return,
            error.ConnectionAborted, error.WouldBlock, error.ProtocolFailure, error.BlockedByFirewall => continue,
            else => {
                sleepAtLeast(io, .fromMilliseconds(10)) catch return;
                continue;
            },
        };
        if (state.refusing.load(.acquire)) {
            stream.close(io);
            continue;
        }
        const number = state.connections.fetchAdd(1, .monotonic) + 1;
        group.concurrent(io, serveConnection, .{ state, stream, number }) catch stream.close(io);
    }
}

/// One connection, in the heap: its reader and writer point into it.
const Connection = struct {
    stream: net.Stream,
    /// 1 for the first connection to the server, 2 for the next.
    number: u32,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    read_buffer: [16 * 1024]u8,
    write_buffer: [16 * 1024]u8,
    /// In `Served.connections`.
    node: std.DoublyLinkedList.Node = .{},
};

/// The connections being served, so that a server that goes away ends all
/// of them.
const Served = struct {
    mutex: Io.Mutex = .init,
    connections: std.DoublyLinkedList = .{},

    fn add(s: *Served, io: Io, conn: *Connection) void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        s.connections.append(&conn.node);
    }

    fn remove(s: *Served, io: Io, conn: *Connection) void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        s.connections.remove(&conn.node);
    }

    /// Shuts every connection down both ways, from the task of any of
    /// them: its client sees the end of the stream. Each task closes its
    /// own socket.
    fn shutAll(s: *Served, io: Io) void {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        var it = s.connections.first;
        while (it) |node| : (it = node.next) {
            const conn: *Connection = @fieldParentPtr("node", node);
            conn.stream.shutdown(io, .both) catch {};
        }
    }
};

fn serveConnection(state: *State, stream: net.Stream, number: u32) void {
    const io = state.io;
    defer stream.close(io);
    const conn = state.gpa.create(Connection) catch return;
    defer state.gpa.destroy(conn);
    conn.* = .{ .stream = stream, .number = number, .reader = undefined, .writer = undefined, .read_buffer = undefined, .write_buffer = undefined };
    conn.reader = stream.reader(io, &conn.read_buffer);
    conn.writer = stream.writer(io, &conn.write_buffer);
    state.served.add(io, conn);
    defer state.served.remove(io, conn);
    // Accepted just as the server went away, after `shutAll`: it ends too.
    if (state.refusing.load(.acquire)) return;
    var arena: std.heap.ArenaAllocator = .init(state.gpa);
    defer arena.deinit();
    while (true) {
        _ = arena.reset(.retain_capacity);
        // The end of the stream, a canceled server, a failed write or a
        // command that ends the connection.
        const next = serveCommand(state, conn, arena.allocator()) catch return;
        if (next == .end) return;
    }
}

/// Whether the connection goes on after a command.
const Next = enum { go_on, end };

/// Reads one command from `conn` and answers it.
fn serveCommand(state: *State, conn: *Connection, arena: Allocator) !Next {
    const w = &conn.writer.interface;
    const read = command.read(&conn.reader.interface, arena) catch |err| switch (err) {
        error.ProtocolViolation, error.ReplyTooLarge => {
            state.notCommand(conn.number);
            try w.writeAll("-ERR Protocol error: zefir FakeServer reads a command as an array of bulk strings\r\n");
            try w.flush();
            return .end;
        },
        else => |e| return e,
    };
    const args = read orelse return .end;
    if (ownCommand(args)) |own| {
        if (own == .ping) try state.record(conn.number, args);
        try answerOwn(state, conn, own, args);
        try w.flush();
        return .go_on;
    }
    switch (try state.take(conn.number, args)) {
        .steps => |steps| for (steps) |step| {
            if (try perform(state, conn, step.reply) == .end) return .end;
        },
        .unexpected => |why| {
            try w.writeAll("-ERR zefir FakeServer: ");
            try w.writeAll(why.text());
            try w.writeAll("\r\n");
            try w.flush();
        },
    }
    return .go_on;
}

/// Does what `reply` says on `conn`: writes it, after its delay if it has
/// one, or closes the connection, or every connection.
fn perform(state: *State, conn: *Connection, reply: Reply) !Next {
    const w = &conn.writer.interface;
    var current = reply;
    while (current == .delayed) {
        try sleepAtLeast(state.io, current.delayed.after);
        current = current.delayed.reply.*;
    }
    switch (current) {
        .close_connection => return .end,
        .refuse_connections => {
            state.refuse();
            return .end;
        },
        .malformed => |defect| {
            try w.writeAll(defect.bytes());
            try w.flush();
            return if (defect == .truncated) .end else .go_on;
        },
        else => {
            try replies.write(w, current);
            try w.flush();
            return .go_on;
        },
    }
}

/// The commands that the server answers itself.
const Own = enum { hello, client_setinfo, select, ping };

fn ownCommand(args: []const []const u8) ?Own {
    const name = args[0];
    if (std.ascii.eqlIgnoreCase(name, "HELLO")) return .hello;
    if (std.ascii.eqlIgnoreCase(name, "SELECT")) return .select;
    if (std.ascii.eqlIgnoreCase(name, "PING")) return .ping;
    if (std.ascii.eqlIgnoreCase(name, "CLIENT") and args.len > 1 and std.ascii.eqlIgnoreCase(args[1], "SETINFO")) return .client_setinfo;
    return null;
}

fn answerOwn(state: *State, conn: *Connection, own: Own, args: []const []const u8) Io.Writer.Error!void {
    const w = &conn.writer.interface;
    switch (own) {
        .hello => try answerHello(w, state.hello, args, conn.number),
        .client_setinfo => try w.writeAll("+OK\r\n"),
        .select => try answerSelect(w, args),
        .ping => if (args.len > 1) try replies.write(w, .{ .string = args[1] }) else try w.writeAll("+PONG\r\n"),
    }
}

/// `HELLO [protover [AUTH username password] [SETNAME clientname]]`, as
/// Redis answers it, by `hello`.
fn answerHello(w: *Io.Writer, hello: Hello, args: []const []const u8, number: u32) Io.Writer.Error!void {
    var i: usize = 1;
    if (args.len > 1) {
        const version = std.fmt.parseInt(i64, args[1], 10) catch
            return w.writeAll("-ERR Protocol version is not an integer or out of range\r\n");
        if (version != 3) return w.writeAll("-NOPROTO unsupported protocol version\r\n");
        i = 2;
    }
    var password: ?[]const u8 = null;
    while (i < args.len) {
        if (std.ascii.eqlIgnoreCase(args[i], "AUTH") and i + 2 < args.len) {
            password = args[i + 2];
            i += 3;
        } else if (std.ascii.eqlIgnoreCase(args[i], "SETNAME") and i + 1 < args.len) {
            i += 2;
        } else {
            try w.writeAll("-ERR Syntax error in HELLO option '");
            try command.writePrintable(w, args[i]);
            return w.writeAll("'\r\n");
        }
    }
    if (hello.password) |expected| {
        const given = password orelse return w.writeAll("-NOAUTH HELLO must be called with the client already authenticated, " ++
            "otherwise the HELLO <proto> AUTH <user> <pass> option can be used to authenticate the client and select the RESP protocol version at the same time\r\n");
        if (!std.mem.eql(u8, given, expected)) return w.writeAll("-WRONGPASS invalid username-password pair or user is disabled.\r\n");
    }
    const fields = [_][2]Reply{
        .{ .{ .string = "server" }, .{ .string = hello.server } },
        .{ .{ .string = "version" }, .{ .string = hello.version } },
        .{ .{ .string = "proto" }, .{ .integer = 3 } },
        .{ .{ .string = "id" }, .{ .integer = number } },
        .{ .{ .string = "mode" }, .{ .string = hello.mode } },
        .{ .{ .string = "role" }, .{ .string = hello.role } },
        .{ .{ .string = "modules" }, .{ .array = &.{} } },
    };
    try replies.write(w, .{ .pairs = &fields });
}

/// `SELECT index`: the databases 0 to 15 of a default Redis.
fn answerSelect(w: *Io.Writer, args: []const []const u8) Io.Writer.Error!void {
    if (args.len != 2) return w.writeAll("-ERR wrong number of arguments for 'select' command\r\n");
    const index = std.fmt.parseInt(i64, args[1], 10) catch
        return w.writeAll("-ERR value is not an integer or out of range\r\n");
    if (index < 0 or index > 15) return w.writeAll("-ERR DB index is out of range\r\n");
    try w.writeAll("+OK\r\n");
}

// What `finish` fails with is checked here, through `verdict`, so that a
// passing run prints nothing; `fake_server_tests.zig` checks the rest over
// the network.

fn stepsOf(plan: Plan) ![]const Step {
    return switch (plan) {
        .steps => |steps| steps,
        .unexpected => error.TestUnexpectedCommand,
    };
}

fn whyOf(plan: Plan) !Description {
    return switch (plan) {
        .unexpected => |why| why,
        .steps => error.TestExpectedCommand,
    };
}

test "finish names the first command that the script did not expect, or else the first step that has not run" {
    const io = std.testing.io;
    var server: FakeServer = try .start(std.testing.allocator, io, &.{
        .expect(.{ "GET", "a" }, .nil),
        .expect(.{ "GET", "b" }, .nil),
        .send(.ok),
    });
    defer server.stop(io);
    const state = server.state.?;
    var why: Description = .{};
    try std.testing.expectError(error.ScriptNotFinished, server.verdict(io, &why));
    try std.testing.expectEqualStrings("0 of the 3 steps ran; step 0 expects 'GET'", why.text());
    try std.testing.expectEqual(@as(usize, 1), (try stepsOf(try state.take(1, &.{ "GET", "a" }))).len);
    try std.testing.expectError(error.ScriptNotFinished, server.verdict(io, &why));
    try std.testing.expectEqualStrings("1 of the 3 steps ran; step 1 expects 'GET'", why.text());

    // A byte outside printable ASCII in the name shows as '?'.
    const refused = try whyOf(try state.take(2, &.{ "d\x00l", "a" }));
    try std.testing.expectEqualStrings("unexpected command 'd?l': the next step expects 'GET'", refused.text());
    try std.testing.expectError(error.UnexpectedCommand, server.verdict(io, &why));
    try std.testing.expectEqualStrings("unexpected command 'd?l': the next step expects 'GET', on connection 2", why.text());

    // The step takes the send after it; the first unexpected command
    // stays what finish names.
    try std.testing.expectEqual(@as(usize, 2), (try stepsOf(try state.take(1, &.{ "get", "b" }))).len);
    _ = try state.take(1, &.{ "GET", "c" });
    try std.testing.expectError(error.UnexpectedCommand, server.verdict(io, &why));
    try std.testing.expectEqualStrings("unexpected command 'd?l': the next step expects 'GET', on connection 2", why.text());
}

test "finish names bytes that are not a command, and a name too long for its line is cut" {
    const io = std.testing.io;
    var server: FakeServer = try .start(std.testing.allocator, io, &.{});
    defer server.stop(io);
    const state = server.state.?;
    const long = try whyOf(try state.take(1, &.{&@as([100]u8, @splat('x'))}));
    try std.testing.expectEqualStrings("unexpected command '" ++ @as([64]u8, @splat('x')) ++ "...': no step is left", long.text());
    state.notCommand(3);
    // The first one stays.
    var why: Description = .{};
    try std.testing.expectError(error.UnexpectedCommand, server.verdict(io, &why));
    try std.testing.expectStringStartsWith(why.text(), "unexpected command 'xxx");

    var other: FakeServer = try .start(std.testing.allocator, io, &.{});
    defer other.stop(io);
    other.state.?.notCommand(3);
    try std.testing.expectError(error.UnexpectedCommand, other.verdict(io, &why));
    try std.testing.expectEqualStrings("bytes that are not a command, an array of bulk strings, on connection 3", why.text());
}

test "finish passes once every step ran and nothing else came; after stop it fails" {
    const io = std.testing.io;
    var server: FakeServer = try .start(std.testing.allocator, io, &.{
        .expect(.{ "GET", "a" }, .nil),
        .send(.ok),
    });
    defer server.stop(io);
    var why: Description = .{};
    try std.testing.expectEqual(@as(usize, 2), (try stepsOf(try server.state.?.take(1, &.{ "GET", "a" }))).len);
    try server.verdict(io, &why);
    try server.finish(io);
    server.stop(io);
    try std.testing.expectError(error.ScriptNotFinished, server.verdict(io, &why));
    try std.testing.expectEqualStrings("finish after stop, which forgot the script; call finish first", why.text());
}

test "a script whose first step is a send never runs it" {
    const io = std.testing.io;
    var server: FakeServer = try .start(std.testing.allocator, io, &.{.send(.ok)});
    defer server.stop(io);
    const why_not = try whyOf(try server.state.?.take(1, &.{ "GET", "k" }));
    try std.testing.expectEqualStrings("unexpected command 'GET': the next step is a send, which runs after the step before it", why_not.text());
    var why: Description = .{};
    try std.testing.expectError(error.UnexpectedCommand, server.verdict(io, &why));
}
