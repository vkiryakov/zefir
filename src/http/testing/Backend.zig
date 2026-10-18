//! A backend in memory for tests: the same server, the
//! same controllers, no sockets. `request` hands one request to the server
//! and returns its response once the request has ended.
//!
//! ```zig
//! var backend: http.testing.Backend = .init(gpa);
//! defer backend.deinit();
//! var server = try http.Server.init(gpa, .{ .backend = backend.backend(), .controllers = .{&todos_v1} });
//! defer server.deinit(io);
//! try server.start(io);
//!
//! var res = try backend.request(io, .{ .method = .GET, .target = "/v1/todos/1" });
//! defer res.deinit();
//! try std.testing.expectEqual(200, res.status);
//! ```
//!
//! `open` hands a request over and returns once the head of its response
//! has come: for an SSE stream, read a piece at a time as the server
//! writes it, while the request goes on.
//!
//! ```zig
//! var stream = try backend.open(io, .{ .method = .GET, .target = "/v1/todos/events" });
//! defer stream.deinit(io);
//! try std.testing.expectEqualStrings("text/event-stream", stream.header("content-type").?);
//! const event = (try stream.next(io, .fromSeconds(5))).?; // "event: todo.created\ndata: {...}\n\n"
//! ```
//!
//! Each request runs on a task of its own, as on the network, so a stop of
//! the server reaches it. The backend checks how the server writes: a
//! second head, a body before the head or after the end, or a body that
//! does not match its length is logged as an error, which fails the test.
const std = @import("std");
const core = @import("core");
const Interface = @import("../Backend.zig");
const Exchange = Interface.Exchange;
const h1 = @import("../h1/head.zig");
const waiting = @import("../wait.zig");

const Backend = @This();

gpa: std.mem.Allocator,
/// Serializes `start`, `stopAccepting` and the start of a request's task.
mutex: std.Io.Mutex = .init,
/// The server, from `start` on.
handler: ?Interface.Handler = null,
/// Between `start` and `stopAccepting`.
accepting: std.atomic.Value(bool) = .init(false),
/// The tasks of the requests. Only the server's stop awaits or cancels it.
tasks: std.Io.Group = .init,

/// A request, as a client would send it. Its strings are borrowed for the
/// call.
pub const Request = struct {
    method: std.http.Method,
    /// Origin form, such as "/api/v1/todos?page=2".
    target: []const u8,
    /// Header fields as name and value: `.{ "content-type", "application/json" }`.
    headers: []const [2][]const u8 = &.{},
    body: []const u8 = "",
    /// The address of the client, as `ctx.request.clientAddress()` gives
    /// it; null for none.
    client_address: ?std.Io.net.IpAddress = null,
    /// The client leaves this long after it sent the request, as one that
    /// closes its connection: the request is canceled and gets no
    /// response, unless it ended before. The server notices it once the
    /// body has been read, as on the network. Null: the client waits.
    leave_after: ?std.Io.Duration = null,
    /// The client reads nothing of the body, as one whose connection's
    /// buffers are full: each write of the body waits until the request
    /// is canceled. The head goes out. For a subscriber of a stream that
    /// falls behind: its queue overflows. There is no write timeout here, so
    /// a stream the server closes waits for its write until the stop
    /// cancels it.
    stalled: bool = false,
};

/// The response as the server wrote it: the status, the fields with
/// `content-length` (or `transfer-encoding: chunked` for a stream) as the
/// backend adds them, and the body; no `date`.
pub const Response = struct {
    status: u16,
    headers: []const [2][]const u8,
    /// Empty for HEAD, 204 and 304.
    body: []const u8,
    /// The body as the server handed it over, a piece per write: a body
    /// held whole is one, a streamed one comes a buffer at a time, and a
    /// `flush` sends what it has as a piece of its own.
    chunks: []const []const u8,
    /// The response did not end: the server aborted it, as it does when the
    /// client has gone or the server stops.
    aborted: bool,
    arena: std.heap.ArenaAllocator,

    /// The value of the first field `name`, which is case-insensitive.
    pub fn header(r: *const Response, name: []const u8) ?[]const u8 {
        for (r.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h[0], name)) return h[1];
        }
        return null;
    }

    pub fn deinit(r: *Response) void {
        r.arena.deinit();
        r.* = undefined;
    }
};

/// `NotStarted`: the server has not started or stops.
pub const RequestError = error{ NotStarted, OutOfMemory } || std.Io.Cancelable;

/// `RequestError`, and `ConcurrencyUnavailable` when the runtime gives no
/// task for the request: `open` cannot serve it on the caller's task.
pub const OpenError = RequestError || error{ConcurrencyUnavailable};

/// A response read as the server writes it, from `open`: for an SSE
/// stream. The head is here once `open` has returned; `next` gives the
/// pieces of the body one by one. The request goes on until the server
/// ends it or the client leaves (`leave`, `deinit`).
pub const Stream = struct {
    gpa: std.mem.Allocator,
    /// The memory of the request: its fields.
    request_arena: std.heap.ArenaAllocator,
    call: Call,
    /// The status and the fields of the response, as its head came; 0 and
    /// none when the request ended without a response.
    status: u16 = 0,
    headers: []const [2][]const u8 = &.{},
    /// The pieces of the body `next` has given.
    taken: usize = 0,

    /// The value of the first field `name`, which is case-insensitive.
    pub fn header(s: *const Stream, name: []const u8) ?[]const u8 {
        for (s.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h[0], name)) return h[1];
        }
        return null;
    }

    /// The next piece of the body, as the server wrote it, such as one SSE
    /// event or a heartbeat; null once the response has ended and every
    /// piece is taken. `error.Timeout` when none came within `timeout`.
    pub fn next(s: *Stream, io: std.Io, timeout: std.Io.Duration) (error{Timeout} || std.Io.Cancelable)!?[]const u8 {
        const deadline: core.Deadline = .after(std.Io.Clock.awake.now(io), timeout);
        while (true) {
            // Before the pieces are looked at: a write after it sets it again.
            s.call.changed.reset();
            {
                s.call.mutex.lockUncancelable(io);
                defer s.call.mutex.unlock(io);
                const rec = &s.call.recorder;
                if (s.taken < rec.chunks.items.len) {
                    s.taken += 1;
                    return rec.chunks.items[s.taken - 1];
                }
                if (rec.state == .finished or rec.state == .aborted or s.call.served.load(.acquire)) return null;
            }
            waiting.untilSet(&s.call.changed, io, deadline) catch |err| return switch (err) {
                error.Timeout => error.Timeout,
                error.Canceled => error.Canceled,
            };
        }
    }

    /// Whether the response ended without its end: the server cut it, as
    /// it does when the client has gone. For after `next` gave null.
    pub fn aborted(s: *const Stream) bool {
        return s.call.recorder.state != .finished;
    }

    /// The client leaves, as one that closes its connection: the server
    /// sees it go.
    pub fn leave(s: *Stream, io: std.Io) void {
        s.call.left.set(io);
    }

    /// The client leaves, unless it has; waits until the request has ended
    /// and frees the stream.
    pub fn deinit(s: *Stream, io: std.Io) void {
        s.leave(io);
        s.call.done.waitUncancelable(io);
        s.free();
    }

    fn free(s: *Stream) void {
        s.call.recorder.arena.deinit();
        s.request_arena.deinit();
        s.gpa.destroy(s);
    }
};

pub fn init(gpa: std.mem.Allocator) Backend {
    return .{ .gpa = gpa };
}

/// After the server's `deinit`.
pub fn deinit(b: *Backend) void {
    b.* = undefined;
}

/// The backend for `http.Server.init`'s `.backend`.
pub fn backend(b: *Backend) Interface {
    return .{ .ptr = b, .vtable = &vtable };
}

/// Hands `req` to the server and returns its response once the request
/// has ended. When the caller is canceled, the request still ends first,
/// then the call returns `error.Canceled`.
pub fn request(b: *Backend, io: std.Io, req: Request) RequestError!Response {
    var exchange_arena: std.heap.ArenaAllocator = .init(b.gpa);
    defer exchange_arena.deinit();
    var call: Call = try .init(b.gpa, io, exchange_arena.allocator(), req);
    call.exchange.ptr = &call;
    errdefer call.recorder.arena.deinit();

    const inline_handler: ?Interface.Handler = spawn: {
        b.mutex.lockUncancelable(io);
        defer b.mutex.unlock(io);
        if (!b.accepting.load(.acquire)) return error.NotStarted;
        const handler = b.handler.?;
        b.tasks.concurrent(io, serveTask, .{ handler, io, &call }) catch |err| switch (err) {
            // The runtime gives no task: the request runs on this one.
            error.ConcurrencyUnavailable => break :spawn handler,
        };
        break :spawn null;
    };
    var canceled = false;
    if (inline_handler) |handler| {
        serveTask(handler, io, &call);
    } else call.done.wait(io) catch {
        // The request reads `call`: it ends first.
        call.done.waitUncancelable(io);
        canceled = true;
    };
    if (canceled) return error.Canceled;
    if (call.out_of_memory) return error.OutOfMemory;

    const rec = &call.recorder;
    const ended = rec.state == .finished;
    if (!ended and rec.state != .aborted)
        log.err("the server returned from serve without finishing or aborting the response", .{});
    return .{
        .status = rec.status,
        .headers = rec.headers.items,
        .body = rec.body.items,
        .chunks = rec.chunks.items,
        .aborted = !ended,
        .arena = rec.arena,
    };
}

/// Hands `req` to the server on a task of its own and returns once the
/// head of its response has come, or the request has ended without one:
/// the body is read with `Stream.next` as the server writes it. When the
/// caller is canceled meanwhile, the client leaves, the request ends, and
/// the call returns `error.Canceled`.
pub fn open(b: *Backend, io: std.Io, req: Request) OpenError!*Stream {
    const s = try b.newStream(io, req);
    b.spawn(io, &s.call) catch |err| {
        s.free();
        return err;
    };
    // The head, or the end of the request.
    while (true) {
        s.call.changed.reset();
        {
            s.call.mutex.lockUncancelable(io);
            defer s.call.mutex.unlock(io);
            const rec = &s.call.recorder;
            if (rec.state != .head or s.call.served.load(.acquire)) {
                s.status = rec.status;
                s.headers = rec.headers.items;
                break;
            }
        }
        s.call.changed.wait(io) catch {
            s.deinit(io);
            return error.Canceled;
        };
    }
    if (s.call.out_of_memory) {
        s.deinit(io);
        return error.OutOfMemory;
    }
    return s;
}

/// A stream for `req`, its call ready and not handed over yet.
fn newStream(b: *Backend, io: std.Io, req: Request) error{OutOfMemory}!*Stream {
    const s = try b.gpa.create(Stream);
    errdefer b.gpa.destroy(s);
    s.* = .{ .gpa = b.gpa, .request_arena = .init(b.gpa), .call = undefined };
    errdefer s.request_arena.deinit();
    s.call = try .init(b.gpa, io, s.request_arena.allocator(), req);
    s.call.exchange.ptr = &s.call;
    return s;
}

/// Hands `call` to the server on a task of its own.
fn spawn(b: *Backend, io: std.Io, call: *Call) OpenError!void {
    b.mutex.lockUncancelable(io);
    defer b.mutex.unlock(io);
    if (!b.accepting.load(.acquire)) return error.NotStarted;
    try b.tasks.concurrent(io, serveTask, .{ b.handler.?, io, call });
}

const log = std.log.scoped(.http);

/// Serves `call`. Once `done` is set its caller may free it, `request` by
/// returning, `Stream.deinit` by destroying the stream: so setting `done`
/// is the last thing this does with it. A `Stream` that waits for a write
/// learns of the end from `served` and `changed` before that.
fn serveTask(handler: Interface.Handler, io: std.Io, call: *Call) void {
    handler.serve(handler.ptr, io, &call.exchange);
    call.served.store(true, .release);
    call.changed.set(io);
    call.done.set(io);
}

const vtable: Interface.VTable = .{
    .capabilities = capabilities,
    .start = start,
    .stopAccepting = stopAccepting,
    .cancelAll = cancelAll,
    .wait = wait,
    .isReady = isReady,
};

fn capabilities(_: *anyopaque) Interface.Capabilities {
    return .{ .http1 = true, .streaming_response = true, .flush = true };
}

fn start(ptr: *anyopaque, io: std.Io, handler: Interface.Handler) Interface.StartError!void {
    const b: *Backend = @ptrCast(@alignCast(ptr));
    b.mutex.lockUncancelable(io);
    defer b.mutex.unlock(io);
    b.handler = handler;
    b.accepting.store(true, .release);
}

fn stopAccepting(ptr: *anyopaque, io: std.Io) void {
    const b: *Backend = @ptrCast(@alignCast(ptr));
    b.mutex.lockUncancelable(io);
    defer b.mutex.unlock(io);
    b.accepting.store(false, .release);
}

fn cancelAll(ptr: *anyopaque, io: std.Io) void {
    const b: *Backend = @ptrCast(@alignCast(ptr));
    b.tasks.cancel(io);
}

fn wait(ptr: *anyopaque, io: std.Io) void {
    const b: *Backend = @ptrCast(@alignCast(ptr));
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    // Cancelation is blocked: the wait ends when the tasks have.
    b.tasks.await(io) catch {};
}

fn isReady(ptr: *anyopaque) bool {
    const b: *Backend = @ptrCast(@alignCast(ptr));
    return b.accepting.load(.acquire);
}

/// One request in flight.
const Call = struct {
    exchange: Exchange,
    body: []const u8,
    body_read: usize = 0,
    /// When the client leaves, on the awake clock; null: when `left` is
    /// set, if ever.
    leave_at: ?std.Io.Clock.Timestamp,
    /// Set when the client of a stream leaves: `Stream.leave`.
    left: std.Io.Event = .unset,
    /// The client reads nothing of the body: `Request.stalled`.
    stalled: bool,
    /// Guards `recorder` while the server writes and a `Stream` reads.
    mutex: std.Io.Mutex = .init,
    recorder: Recorder,
    /// Set after each write of the server and when `serve` has returned:
    /// a `Stream` waits on it.
    changed: std.Io.Event = .unset,
    /// The recorder ran out of memory: `request` returns `OutOfMemory`.
    out_of_memory: bool = false,
    /// `serve` has returned: what a `Stream` that waits on `changed` looks
    /// at. Not `done`, which comes after the last `changed`.
    served: std.atomic.Value(bool) = .init(false),
    /// Set when `serve` has returned, as the last touch of the task: from
    /// then on the caller may free the call.
    done: std.Io.Event = .unset,

    /// A call for `req`; its fields in `arena`. Its exchange points to it
    /// once it stays where it is.
    fn init(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, req: Request) error{OutOfMemory}!Call {
        const fields = try arena.alloc(h1.Field, req.headers.len);
        for (fields, req.headers) |*f, h| f.* = .{ .name = h[0], .value = h[1] };
        return .{
            .body = req.body,
            .leave_at = if (req.leave_after) |after| .fromNow(io, .{ .raw = after, .clock = .awake }) else null,
            .stalled = req.stalled,
            .recorder = .{ .arena = .init(gpa), .head_request = req.method == .HEAD },
            .exchange = .{
                .ptr = undefined,
                .vtable = &exchange_vtable,
                .method = req.method,
                .target = req.target,
                .version = .http11,
                .fields = fields,
                .client = req.client_address,
                .arena = arena,
            },
        };
    }

    fn of(ptr: *anyopaque) *Call {
        return @ptrCast(@alignCast(ptr));
    }

    /// The recorder, for one write of the server.
    fn record(call: *Call, io: std.Io) *Recorder {
        call.mutex.lockUncancelable(io);
        return &call.recorder;
    }

    /// The write is recorded: a `Stream` that waits sees it.
    fn recorded(call: *Call, io: std.Io) void {
        call.mutex.unlock(io);
        call.changed.set(io);
    }

    fn failed(call: *Call, err: Recorder.Error) Exchange.WriteError {
        switch (err) {
            error.OutOfMemory => call.out_of_memory = true,
            else => |misuse| log.err("the server misused the exchange: {t}", .{misuse}),
        }
        return error.WriteFailed;
    }
};

const exchange_vtable: Exchange.VTable = .{
    .bodyLength = bodyLength,
    .readBody = readBody,
    .bodyFailure = bodyFailure,
    .watch = watch,
    .writeHead = writeHead,
    .writeBody = writeBody,
    .flush = flush,
    .finish = finish,
    .abort = abort,
};

fn bodyLength(ptr: *anyopaque) ?u64 {
    return Call.of(ptr).body.len;
}

fn readBody(ptr: *anyopaque, io: std.Io, buffer: []u8) Exchange.ReadError!usize {
    const call = Call.of(ptr);
    // A read is a cancelation point, as on a socket.
    try io.checkCancel();
    const n = @min(buffer.len, call.body.len - call.body_read);
    @memcpy(buffer[0..n], call.body[call.body_read..][0..n]);
    call.body_read += n;
    return n;
}

fn bodyFailure(_: *anyopaque) ?Exchange.BodyFailure {
    return null;
}

/// Until the client leaves, by its clock (`leave_after`) or from its stream
/// (`Stream.leave`), or until the watch is canceled, which the server does
/// when the request ends.
fn watch(ptr: *anyopaque, io: std.Io) void {
    const call = Call.of(ptr);
    // A sleep without a limit is no sleep every `std.Io` can take: then
    // the event alone.
    const at = call.leave_at orelse {
        call.left.wait(io) catch {};
        return;
    };
    waiting.untilSet(&call.left, io, .at(at.raw)) catch {};
}

fn writeHead(ptr: *anyopaque, io: std.Io, status: u16, fields: []const h1.Field, body: Exchange.BodyKind) Exchange.WriteError!void {
    const call = Call.of(ptr);
    defer call.recorded(io);
    call.record(io).head(status, fields, body) catch |err| return call.failed(err);
}

fn writeBody(ptr: *anyopaque, io: std.Io, data: []const u8) Exchange.WriteError!void {
    const call = Call.of(ptr);
    if (call.stalled and data.len > 0) {
        // The client reads nothing: the write waits until it is canceled.
        while (true) io.sleep(.fromSeconds(60 * 60), .awake) catch return error.Canceled;
    }
    defer call.recorded(io);
    call.record(io).write(data) catch |err| return call.failed(err);
}

fn flush(ptr: *anyopaque, io: std.Io) Exchange.WriteError!void {
    const call = Call.of(ptr);
    defer call.recorded(io);
    call.record(io).flush() catch |err| return call.failed(err);
}

fn finish(ptr: *anyopaque, io: std.Io) Exchange.WriteError!void {
    const call = Call.of(ptr);
    defer call.recorded(io);
    call.record(io).finish() catch |err| return call.failed(err);
}

fn abort(ptr: *anyopaque, io: std.Io) void {
    const call = Call.of(ptr);
    defer call.recorded(io);
    call.record(io).abort();
}

/// The response as the server writes it, with the checks of the order of
/// the writes.
const Recorder = struct {
    /// The memory of the response; `Response.deinit` frees it.
    arena: std.heap.ArenaAllocator,
    /// The request was HEAD: the body is not kept.
    head_request: bool,
    state: enum { head, body, finished, aborted } = .head,
    status: u16 = 0,
    headers: std.ArrayList([2][]const u8) = .empty,
    body: std.ArrayList(u8) = .empty,
    /// Each write of the body, kept.
    chunks: std.ArrayList([]const u8) = .empty,
    kind: Exchange.BodyKind = .none,
    /// Bytes of the body written, kept or not.
    written: u64 = 0,

    const Error = error{
        HeadTwice,
        HeadAfterEnd,
        BodyBeforeHead,
        BodyAfterEnd,
        /// A body for a response without one (204, 304).
        BodyNotAllowed,
        BodyOverLength,
        BodyUnderLength,
        FlushOutsideBody,
        FinishBeforeHead,
        FinishTwice,
        OutOfMemory,
    };

    fn head(rec: *Recorder, status: u16, fields: []const h1.Field, kind: Exchange.BodyKind) Error!void {
        switch (rec.state) {
            .head => {},
            .body => return error.HeadTwice,
            .finished, .aborted => return error.HeadAfterEnd,
        }
        const a = rec.arena.allocator();
        try rec.headers.ensureTotalCapacity(a, fields.len + 1);
        for (fields) |f| rec.headers.appendAssumeCapacity(.{ try a.dupe(u8, f.name), try a.dupe(u8, f.value) });
        switch (kind) {
            .none => {},
            .length => |n| rec.headers.appendAssumeCapacity(.{ "content-length", try std.fmt.allocPrint(a, "{d}", .{n}) }),
            // A HEAD response has no body to delimit, as on the network.
            .stream => if (!rec.head_request) rec.headers.appendAssumeCapacity(.{ "transfer-encoding", "chunked" }),
        }
        rec.status = status;
        rec.kind = kind;
        rec.state = .body;
    }

    fn write(rec: *Recorder, data: []const u8) Error!void {
        switch (rec.state) {
            .head => return error.BodyBeforeHead,
            .body => {},
            .finished, .aborted => return error.BodyAfterEnd,
        }
        switch (rec.kind) {
            .none => if (data.len > 0) return error.BodyNotAllowed,
            .length => |n| if (rec.written + data.len > n) return error.BodyOverLength,
            .stream => {},
        }
        rec.written += data.len;
        if (rec.head_request or data.len == 0) return;
        const a = rec.arena.allocator();
        try rec.body.appendSlice(a, data);
        try rec.chunks.append(a, try a.dupe(u8, data));
    }

    fn flush(rec: *Recorder) Error!void {
        if (rec.state != .body) return error.FlushOutsideBody;
    }

    fn finish(rec: *Recorder) Error!void {
        switch (rec.state) {
            .head => return error.FinishBeforeHead,
            .body => {},
            .finished, .aborted => return error.FinishTwice,
        }
        switch (rec.kind) {
            .length => |n| if (!rec.head_request and rec.written < n) return error.BodyUnderLength,
            .none, .stream => {},
        }
        rec.state = .finished;
    }

    fn abort(rec: *Recorder) void {
        if (rec.state != .finished) rec.state = .aborted;
    }
};

const testing = std.testing;

test "the recorder refuses writes out of order and bodies that miss their length" {
    var rec: Recorder = .{ .arena = .init(testing.allocator), .head_request = false };
    defer rec.arena.deinit();
    try testing.expectError(error.BodyBeforeHead, rec.write("x"));
    try testing.expectError(error.FinishBeforeHead, rec.finish());
    try rec.head(200, &.{.{ .name = "content-type", .value = "text/plain" }}, .{ .length = 5 });
    try testing.expectError(error.HeadTwice, rec.head(200, &.{}, .none));
    try rec.write("hel");
    try testing.expectError(error.BodyOverLength, rec.write("lo!"));
    try testing.expectError(error.BodyUnderLength, rec.finish());
    try rec.flush();
    try rec.write("lo");
    try rec.finish();
    try testing.expectError(error.BodyAfterEnd, rec.write("x"));
    try testing.expectError(error.FinishTwice, rec.finish());
    try testing.expectError(error.HeadAfterEnd, rec.head(200, &.{}, .none));
    try testing.expectError(error.FlushOutsideBody, rec.flush());
    try testing.expectEqualStrings("hello", rec.body.items);
    try testing.expectEqualStrings("content-length", rec.headers.items[1][0]);
    try testing.expectEqualStrings("5", rec.headers.items[1][1]);

    // A 204 takes no body; an aborted response takes nothing more.
    var empty: Recorder = .{ .arena = .init(testing.allocator), .head_request = false };
    defer empty.arena.deinit();
    try empty.head(204, &.{}, .none);
    try testing.expectError(error.BodyNotAllowed, empty.write("x"));
    empty.abort();
    try testing.expectError(error.BodyAfterEnd, empty.write(""));

    // HEAD: the length of the body it would have, and no body.
    var head: Recorder = .{ .arena = .init(testing.allocator), .head_request = true };
    defer head.arena.deinit();
    try head.head(200, &.{}, .{ .length = 3 });
    try head.finish();
    try testing.expectEqualStrings("", head.body.items);
}

const Server = @import("../Server.zig");
const Context = @import("../Context.zig");
const routes = @import("../routes.zig");

/// Its server turns the strict error check off: `echo` reads the body
/// whole, and `StreamTooLong` stays unmapped.
const EchoController = struct {
    /// Set by the handler just before it returns.
    finished: bool = false,

    pub const http_routes = routes.routes(.{ .methods = .{ .echo = routes.post("/echo", .{}) } });

    pub fn echo(self: *EchoController, ctx: *Context) !void {
        const reader = try ctx.request.bodyReader();
        const body = try reader.allocRemaining(ctx.allocator(), .limited(1 << 10));
        const address = ctx.request.clientAddress() orelse return error.NoAddress;
        try ctx.response.setHeader("x-client", try std.fmt.allocPrint(ctx.allocator(), "{f}", .{address}));
        try ctx.response.text(body);
        // The response waits for the handler, and the call for the response.
        try ctx.io().sleep(.fromMilliseconds(20), .awake);
        self.finished = true;
    }
};

test "request returns once the request has ended, with the body and the client's address" {
    const io = testing.io;
    var echo: EchoController = .{};
    var b: Backend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&echo}, .strict_errors = false });
    defer server.deinit(io);
    try server.start(io);

    var res = try b.request(io, .{
        .method = .POST,
        .target = "/echo",
        .headers = &.{.{ "content-type", "text/plain" }},
        .body = "hello, server",
        .client_address = .{ .ip4 = .loopback(40000) },
    });
    defer res.deinit();
    try testing.expect(echo.finished);
    try testing.expectEqual(200, res.status);
    try testing.expectEqualStrings("hello, server", res.body);
    try testing.expectEqualStrings("text/plain; charset=utf-8", res.header("Content-Type").?);
    try testing.expectEqualStrings("13", res.header("content-length").?);
    try testing.expectEqualStrings("127.0.0.1:40000", res.header("x-client").?);
    try testing.expect(!res.aborted);
}

const PingController = struct {
    pub const http_routes = routes.routes(.{ .methods = .{ .ping = routes.get("/ping", .{}) } });

    pub fn ping(_: *PingController, ctx: *Context) !void {
        try ctx.response.text("pong");
    }
};

/// Requests and streams one after another, each one's memory written over
/// as soon as the caller has it back: the frame of `request` by the next
/// call, the stream of `open` by the allocator, which fills freed memory.
fn requestMany(b: *Backend, io: std.Io, rounds: usize) anyerror!void {
    for (0..rounds) |i| {
        if (i % 8 == 7) {
            const s = try b.open(io, .{ .method = .GET, .target = "/ping" });
            while (try s.next(io, .fromSeconds(5))) |_| {}
            s.deinit(io);
        } else {
            var res = try b.request(io, .{ .method = .GET, .target = "/ping" });
            const status = res.status;
            res.deinit();
            if (status != 200) return error.TestUnexpectedStatus;
        }
        scribble();
    }
}

/// Writes over the stack below the caller's frame, where the frame of the
/// `request` that has just returned was.
noinline fn scribble() void {
    var junk: [16 << 10]u8 = undefined;
    @memset(&junk, 0xaa);
    std.mem.doNotOptimizeAway(&junk);
}

test "the task of a request never touches it once its caller has it back: 16 clients, 800 requests and streams" {
    const io = testing.io;
    var ping: PingController = .{};
    var b: Backend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&ping} });
    defer server.deinit(io);
    try server.start(io);

    var clients: [16]std.Io.Future(anyerror!void) = undefined;
    var started: usize = 0;
    errdefer for (clients[0..started]) |*client| client.cancel(io) catch {};
    for (&clients) |*client| {
        client.* = try io.concurrent(requestMany, .{ &b, io, 50 });
        started += 1;
    }
    var first: ?anyerror = null;
    for (&clients) |*client| client.await(io) catch |err| {
        if (first == null) first = err;
    };
    started = 0;
    if (first) |err| return err;
}
