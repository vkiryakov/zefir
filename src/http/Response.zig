//! The response of a context (design section 8), as `ctx.response`: its
//! status, its header fields and its body.
//!
//! ```zig
//! try ctx.response.setHeader("cache-control", "no-store");
//! try ctx.response.status(404).html(not_found_page);
//! ```
//!
//! A response goes through three states, in order: `uncommitted` (its
//! status, fields and body can change, and an error replaces it),
//! `committed` (its head has gone to the client: a change is
//! `error.ResponseCommitted`, and an error cuts the response, so the
//! client sees it broken) and `finished`, once.
//!
//! A body given whole (`text`, `html`, `json`) waits for the end of the
//! handler and goes with `Content-Length`. A body written as it goes (a
//! `stream`, a `file`, the value an `http.Json(T)` handler returns) passes
//! through a buffer of `buffer_size`, 16 KiB, and is never held whole: one
//! that ends within the buffer still goes with `Content-Length`, a larger
//! one leaves as it is written, chunked (to an HTTP/1.0 client, until the
//! connection closes). Its head goes out when the buffer first fills, at a
//! `flush`, or at its end.
const std = @import("std");
const v = @import("validator");
const h1 = @import("h1/head.zig");
const Exchange = @import("Backend.zig").Exchange;
const json_out = @import("output/json_out.zig");
const mime = @import("mime.zig");

const Response = @This();
const Writer = std.Io.Writer;
const log = std.log.scoped(.http);

/// Internal to the server.
internal: Internal,

/// The buffer a body written as it goes passes through: a body that fits
/// goes with `Content-Length`, a larger one chunked.
pub const buffer_size = 16 << 10;

pub const Internal = struct {
    arena: std.mem.Allocator,
    /// The status `status` set.
    code: ?u16 = null,
    /// The header fields, copied into the arena; `Content-Type` is kept
    /// in `content_type`.
    headers: std.ArrayList(h1.Field) = .empty,
    content_type: ?[]const u8 = null,
    body: Body = .none,
    state: State = .uncommitted,
    /// Where the response goes; the server sets it for each request.
    sink: ?Sink = null,
    /// The buffer of a body written as it goes.
    out: Out = .{},
    /// Runs once, right before the head goes out: the `onResponse` phases
    /// of the middleware. The server sets it for each request.
    before_head: ?BeforeHead = null,
    /// The status the head went out with; null before.
    status_sent: ?u16 = null,
    /// The server cut the response, or ended the request without one.
    aborted: bool = false,

    /// Whether the handler wrote a response: a status or a body. A `!void`
    /// handler that wrote none answers 204.
    pub fn written(i: *const Internal) bool {
        return i.code != null or i.body != .none;
    }

    /// The value of an `http.Json(T)` as the body. Its transforms run now,
    /// so that an error of one of its own goes to the error handler as an
    /// error of the handler does; it is written as JSON, through the
    /// buffer, when the response goes out.
    pub fn setValue(i: *Internal, value: anytype) (error{ResponseCommitted} || v.TransformError(@TypeOf(value)))!void {
        const T = @TypeOf(value);
        try i.takeBody();
        const copy = try i.arena.create(T);
        copy.* = value;
        try v.transform(i.arena, copy);
        i.body = .{ .value = .{ .ptr = @ptrCast(copy), .write = ValueOf(T).write } };
        i.content_type = "application/json";
    }

    /// The server's answer in place of what the handler wrote: `bytes`
    /// of `content_type`.
    pub fn replaceBody(i: *Internal, content_type: []const u8, bytes: []const u8) void {
        i.body = .{ .bytes = bytes };
        i.content_type = content_type;
        i.out.writer.end = 0;
    }

    /// Sends the response the handler left uncommitted and ends it: a body
    /// held whole with its length, the value of an `http.Json(T)` through
    /// the buffer, or what a stream left in the buffer.
    pub fn send(i: *Internal) Exchange.WriteError!void {
        // First, as the head is not taken apart yet: its status and fields
        // may still change.
        i.runBeforeHead();
        const sink = i.sink.?;
        switch (i.body) {
            .none, .bytes => {
                const bytes = if (i.body == .bytes) i.body.bytes else "";
                try i.commit(bytes.len);
                if (bytes.len > 0 and i.sendsBody()) sink.exchange.writeBody(sink.io, bytes) catch |err| return i.fail(err);
                sink.exchange.finish(sink.io) catch |err| return i.fail(err);
                i.state = .finished;
                return;
            },
            .value => |value| {
                if (!sink.streaming) {
                    // Without a backend that streams: whole, with its length.
                    var whole: Writer.Allocating = .init(i.arena);
                    value.write(value.ptr, &whole.writer) catch return outOfMemory();
                    i.body = .{ .bytes = whole.written() };
                    return i.send();
                }
                i.useBuffer() catch return outOfMemory();
                value.write(value.ptr, &i.out.writer) catch return i.out.failure orelse error.WriteFailed;
            },
            .stream => {},
        }
        return i.finishBody();
    }

    /// Ends a body written through the buffer: whole, with its length,
    /// when it never left the buffer; else what is left of it, then the
    /// end. The response is finished.
    pub fn finishBody(i: *Internal) Exchange.WriteError!void {
        if (i.out.failure) |err| return err;
        if (i.state == .uncommitted) try i.commit(i.out.writer.end);
        try i.push();
        const sink = i.sink.?;
        sink.exchange.finish(sink.io) catch |err| return i.fail(err);
        i.state = .finished;
    }

    /// Sends `length` bytes of the open file `f`, from `offset` on, as the
    /// body of `content_type`, read from the disk as they go out: the head
    /// with that length, the bytes a buffer at a time, then the end; HEAD
    /// gets the head alone. `file` and the server's static files send
    /// through it; `what` names the caller in the log. `content_type` lives
    /// as long as the response.
    pub fn sendFile(i: *Internal, f: std.Io.File, content_type: []const u8, offset: u64, length: u64, comptime what: []const u8) FileError!void {
        const sink = i.sink orelse return error.WriteFailed;
        i.content_type = content_type;
        try i.useBuffer();
        i.body = .stream;
        try i.commit(length);
        if (i.sendsBody()) {
            var reader: std.Io.File.Reader = .init(f, sink.io, &.{});
            // Positional reads only: zio does them on every system.
            reader.mode = .positional_simple;
            reader.pos = offset;
            reader.interface.streamExact64(&i.out.writer, length) catch |err| switch (err) {
                error.WriteFailed => return i.out.failure orelse error.WriteFailed,
                error.ReadFailed => {
                    const cause: anyerror = reader.err orelse error.Unexpected;
                    if (cause == error.Canceled) {
                        i.out.failure = error.Canceled;
                        return error.Canceled;
                    }
                    // The head has gone out: the server cuts the response.
                    i.out.failure = error.WriteFailed;
                    log.warn(what ++ " could not read the file: error.{t}; the response is cut", .{cause});
                    return error.ReadFailed;
                },
                error.EndOfStream => {
                    i.out.failure = error.WriteFailed;
                    log.warn(what ++ ": the file ended before its length; the response is cut", .{});
                    return error.ReadFailed;
                },
            };
        }
        return i.finishBody();
    }

    /// Sends the head: the status, the fields with `Content-Type` first,
    /// and the body's `length`, or chunked for null. From here on the
    /// response is committed. Every head of a response goes out here.
    fn commit(i: *Internal, length: ?u64) Exchange.WriteError!void {
        i.runBeforeHead();
        const sink = i.sink.?;
        const code = i.statusCode();
        if (code < 200 or code > 599) {
            // Only a stream or a file gets here: the server checks the
            // status of every other response first.
            log.warn("a stream or a file with the status {d}, which is not a final status; the response is 500", .{code});
            return error.WriteFailed;
        }
        const head_fields = i.fields() catch return outOfMemory();
        i.state = .committed;
        i.status_sent = code;
        sink.exchange.writeHead(sink.io, code, head_fields, kindOf(code, length)) catch |err| return i.fail(err);
    }

    /// The hook before the head, once.
    fn runBeforeHead(i: *Internal) void {
        const hook = i.before_head orelse return;
        i.before_head = null;
        hook.call(hook.ptr);
    }

    /// Sends what the buffer holds, the head first if it has not gone:
    /// the body is then chunked.
    fn push(i: *Internal) Exchange.WriteError!void {
        if (i.out.failure) |err| return err;
        if (i.state == .finished) return error.WriteFailed;
        if (i.state == .uncommitted) try i.commit(null);
        const w = &i.out.writer;
        defer w.end = 0;
        if (w.end == 0 or !i.sendsBody()) return;
        const sink = i.sink.?;
        sink.exchange.writeBody(sink.io, w.buffer[0..w.end]) catch |err| return i.fail(err);
    }

    /// A write failed: the body is broken, every write after it fails, and
    /// the server cuts the response.
    fn fail(i: *Internal, err: Exchange.WriteError) Exchange.WriteError {
        i.out.failure = err;
        return err;
    }

    /// The status the response goes with: the one set, else 200 with a
    /// body and 204 without.
    fn statusCode(i: *const Internal) u16 {
        return i.code orelse if (i.body == .none) 204 else 200;
    }

    /// Whether the body goes on the wire: not for HEAD, 204 and 304.
    fn sendsBody(i: *const Internal) bool {
        const code = i.statusCode();
        return i.sink.?.exchange.method != .HEAD and code != 204 and code != 304;
    }

    /// The fields of the head, `Content-Type` first when there is one.
    fn fields(i: *const Internal) error{OutOfMemory}![]const h1.Field {
        const content_type = i.content_type orelse return i.headers.items;
        const all = try i.arena.alloc(h1.Field, i.headers.items.len + 1);
        all[0] = .{ .name = "content-type", .value = content_type };
        @memcpy(all[1..], i.headers.items);
        return all;
    }

    /// The body can still be set: nothing has gone out, and no stream or
    /// file has taken the body.
    fn takeBody(i: *const Internal) error{ResponseCommitted}!void {
        if (i.state != .uncommitted or i.body == .stream) return error.ResponseCommitted;
    }

    /// The buffer, empty, for a body written as it goes.
    fn useBuffer(i: *Internal) error{OutOfMemory}!void {
        const w = &i.out.writer;
        if (w.buffer.len == 0) w.buffer = try i.arena.alloc(u8, buffer_size);
        w.end = 0;
    }
};

fn outOfMemory() error{WriteFailed} {
    log.warn("out of memory for the head or the body of a response; it is cut", .{});
    return error.WriteFailed;
}

/// How the body of a response with `code` is delimited: its `length`, or
/// a stream when it is not known; 204 and 304 have none.
fn kindOf(code: u16, length: ?u64) Exchange.BodyKind {
    if (code == 204 or code == 304) return .none;
    return if (length) |n| .{ .length = n } else .stream;
}

/// Where a response is: `uncommitted` until its head goes to the client,
/// then `committed`, then `finished`, once, whether it ended whole or cut.
pub const State = enum { uncommitted, committed, finished };

/// The body of a response.
pub const Body = union(enum) {
    none,
    /// Held whole in the arena: `text`, `html`, `json`, the answer to an
    /// error.
    bytes: []const u8,
    /// The value of an `http.Json(T)`, transformed: written as JSON when
    /// the response goes out.
    value: Value,
    /// A `stream` or a `file`: what is written and not sent is in
    /// `Internal.out`.
    stream,
};

/// A value written as JSON when its response goes out.
pub const Value = struct {
    ptr: *const anyopaque,
    write: *const fn (ptr: *const anyopaque, w: *Writer) Writer.Error!void,
};

fn ValueOf(comptime T: type) type {
    return struct {
        fn write(ptr: *const anyopaque, w: *Writer) Writer.Error!void {
            const value: *const T = @ptrCast(@alignCast(ptr));
            return json_out.write(w, value.*, .{});
        }
    };
}

/// What runs right before the head of a response goes out.
pub const BeforeHead = struct {
    ptr: *anyopaque,
    call: *const fn (ptr: *anyopaque) void,
};

/// The request's exchange, for the bodies that go out as they are written.
pub const Sink = struct {
    exchange: *Exchange,
    io: std.Io,
    /// The backend sends a body as it is written:
    /// `Capabilities.streaming_response`.
    streaming: bool,
};

/// The buffer of a body written as it goes, as a `std.Io.Writer`: when it
/// is full, it sends what it holds.
pub const Out = struct {
    writer: Writer = .{ .vtable = &out_vtable, .buffer = &.{} },
    /// The error that broke the body; every write after it fails with it.
    failure: ?Exchange.WriteError = null,
};

const out_vtable: Writer.VTable = .{ .drain = drain };

/// The buffer is full: what it holds goes out, then as much of `data` as
/// fits takes its place.
fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    const out: *Out = @alignCast(@fieldParentPtr("writer", w));
    const internal: *Internal = @alignCast(@fieldParentPtr("out", out));
    internal.push() catch return error.WriteFailed;
    var n: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        n += keep(w, bytes);
        if (w.end == w.buffer.len) return n;
    }
    const last = data[data.len - 1];
    if (last.len == 0) return n;
    for (0..splat) |_| {
        n += keep(w, last);
        if (w.end == w.buffer.len) return n;
    }
    return n;
}

/// Copies what fits of `bytes` into the buffer; returns how much.
fn keep(w: *Writer, bytes: []const u8) usize {
    const n = @min(bytes.len, w.buffer.len - w.end);
    @memcpy(w.buffer[w.end..][0..n], bytes[0..n]);
    w.end += n;
    return n;
}

/// `InvalidHeaderValue`: a name that is not a token (RFC 9110), or a value
/// with CR, LF, NUL or another control character but HTAB.
/// `ReservedHeader`: a field the backend writes itself, from the body and
/// the connection: `Content-Length`, `Transfer-Encoding`, `Connection`,
/// `Keep-Alive`, `TE`, `Trailer`, `Upgrade` and `Date`; and `Set-Cookie`,
/// a field per cookie, which `setCookie` adds.
/// `ResponseCommitted`: the head of the response has gone to the client,
/// or, for a body, a stream or a file has taken it.
pub const SetError = error{ InvalidHeaderValue, ReservedHeader, ResponseCommitted, OutOfMemory };

/// The errors of `json`: those of setting the body, of the transforms of
/// `T` (`v.TransformError(T)`), and of writing it.
fn JsonError(comptime T: type) type {
    return SetError || Exchange.WriteError || v.TransformError(T);
}

/// The errors of `file` (decision 22). `FileNotFound`: no file at the
/// path, or a part of the path is not a directory; an error of the
/// application, for its error handler to map (to 404, say). `ReadFailed`
/// (500): every other error of the system that opens, checks or reads the
/// file, and a path that is not a regular file, such as a directory; the
/// server logs the error's name, so that a `PermissionDenied` of the
/// system never becomes the framework's 403. `WriteFailed`: the backend
/// cannot send a body as it is written (`streaming_response`; logged), or
/// the client did not take the file; `Canceled`: the request was canceled.
pub const FileError = error{ FileNotFound, ReadFailed } || SetError || Exchange.WriteError;

/// The errors of `stream`. `WriteFailed`: the backend cannot send a body
/// as it is written (`streaming_response`), which the server logs.
pub const StreamError = SetError || Exchange.WriteError;

/// The fields of framing, of the connection and `Date`: the backend writes
/// them, so that what the head says always matches the body it sends.
const reserved_names = [_][]const u8{ "content-length", "transfer-encoding", "connection", "keep-alive", "te", "trailer", "upgrade", "date" };

/// Sets the status; chainable: `try ctx.response.status(404).html(page)`.
/// Without it a body goes out as 200, and no body at all as 204. Once the
/// response is committed, its status has gone out and this changes nothing.
pub fn status(r: *Response, code: u16) *Response {
    if (r.internal.state == .uncommitted) r.internal.code = code;
    return r;
}

/// Where the response is: `uncommitted`, `committed` or `finished`.
pub fn state(r: *const Response) State {
    return r.internal.state;
}

/// Sets the header field `name` to `value`, in place of a field of that
/// name set before (names are case-insensitive). Both are copied. A cookie
/// goes with `setCookie`: `Set-Cookie` here is `error.ReservedHeader`.
pub fn setHeader(r: *Response, name: []const u8, value: []const u8) SetError!void {
    try r.checkField(name, value);
    return r.putField(name, try r.internal.arena.dupe(u8, value));
}

/// Sets the header field `name` to `fmt` formatted with `args`, as
/// `setHeader` does:
/// `try ctx.response.setHeaderFmt("server-timing", "app;dur={d}", .{ms});`
pub fn setHeaderFmt(r: *Response, name: []const u8, comptime fmt: []const u8, args: anytype) SetError!void {
    if (r.internal.state != .uncommitted) return error.ResponseCommitted;
    const value = try std.fmt.allocPrint(r.internal.arena, fmt, args);
    try r.checkField(name, value);
    return r.putField(name, value);
}

/// A cookie for `setCookie` (RFC 6265).
pub const Cookie = struct {
    /// A token: letters, digits and ``!#$%&'*+-.^_`|~``.
    name: []const u8,
    /// Visible ASCII but `"`, `,`, `;` and `\`; empty to clear a cookie.
    value: []const u8,
    /// `Path`: "/" by default, so that the cookie goes with every request
    /// to the site; null leaves it out, and the client takes the directory
    /// of the request's path.
    path: ?[]const u8 = "/",
    /// `Domain`: the cookie goes to its subdomains too. Null: to this host
    /// only.
    domain: ?[]const u8 = null,
    /// `Max-Age`, in whole seconds: how long the client keeps the cookie;
    /// `.zero` deletes it. Null: until the browser closes.
    max_age: ?std.Io.Duration = null,
    /// `Secure`: only over HTTPS.
    secure: bool = false,
    /// `HttpOnly`: out of reach of the page's scripts.
    http_only: bool = false,
    /// `SameSite`: `.lax` and `.strict` keep the cookie from requests that
    /// other sites start (CSRF); browsers take `.none` only with `secure`.
    same_site: ?SameSite = null,

    pub const SameSite = enum { strict, lax, none };
};

/// Adds a `Set-Cookie` field for `cookie`; each call adds one:
///
/// ```zig
/// try ctx.response.setCookie(.{ .name = "session", .value = token, .http_only = true, .same_site = .lax, .secure = true });
/// ```
///
/// `InvalidHeaderValue`: a name that is not a token; a value with a
/// control character, a space, `"`, `,`, `;`, `\` or a byte past ASCII; a
/// path or a domain with a control character or `;`.
pub fn setCookie(r: *Response, cookie: Cookie) SetError!void {
    const i = &r.internal;
    if (i.state != .uncommitted) return error.ResponseCommitted;
    if (!validName(cookie.name) or !validCookieValue(cookie.value)) return error.InvalidHeaderValue;
    if (cookie.path) |p| if (!validAttribute(p)) return error.InvalidHeaderValue;
    if (cookie.domain) |d| if (!validAttribute(d)) return error.InvalidHeaderValue;
    var line: std.ArrayList(u8) = .empty;
    try line.print(i.arena, "{s}={s}", .{ cookie.name, cookie.value });
    if (cookie.path) |p| try line.print(i.arena, "; Path={s}", .{p});
    if (cookie.domain) |d| try line.print(i.arena, "; Domain={s}", .{d});
    // A negative age deletes the cookie, as 0 does.
    if (cookie.max_age) |age| try line.print(i.arena, "; Max-Age={d}", .{@max(0, age.toSeconds())});
    if (cookie.secure) try line.appendSlice(i.arena, "; Secure");
    if (cookie.http_only) try line.appendSlice(i.arena, "; HttpOnly");
    if (cookie.same_site) |same_site| try line.appendSlice(i.arena, switch (same_site) {
        .strict => "; SameSite=Strict",
        .lax => "; SameSite=Lax",
        .none => "; SameSite=None",
    });
    try i.headers.append(i.arena, .{ .name = "set-cookie", .value = line.items });
}

/// Sends the client to `location` with the 3xx status set before, else
/// 302 Found:
///
/// ```zig
/// try ctx.response.status(303).redirect("/login");
/// ```
///
/// `location` goes as it is given, a path or a URL; one with CR, LF or
/// another control character is `InvalidHeaderValue`.
pub fn redirect(r: *Response, location: []const u8) SetError!void {
    try r.setHeader("location", location);
    const code = r.internal.code orelse 0;
    if (code < 300 or code > 399) r.internal.code = 302;
}

/// The body `bytes` as `text/plain; charset=utf-8`; copied.
pub fn text(r: *Response, bytes: []const u8) error{ ResponseCommitted, OutOfMemory }!void {
    return r.setBody("text/plain; charset=utf-8", bytes);
}

/// The body `bytes` as `text/html; charset=utf-8`; copied.
pub fn html(r: *Response, bytes: []const u8) error{ ResponseCommitted, OutOfMemory }!void {
    return r.setBody("text/html; charset=utf-8", bytes);
}

/// `value` as the JSON body (`application/json`): the transforms of its
/// `field_rules` run first, on a copy (`v.transform`), then it is written
/// with the outside names of its fields (`v.rename`), the Zig names where
/// it has none. An error of a transform of its own comes back as it is,
/// for the error handler.
///
/// The body is written now, whole, into the request's arena, so the value
/// may go once this returns; it goes out with `Content-Length`. A handler
/// that returns `http.Json(T)` answers through a buffer instead: its value
/// is written as the response goes out.
///
/// ```zig
/// try ctx.response.status(201).json(dto.TodoResponse.from(todo));
/// ```
pub fn json(r: *Response, value: anytype) JsonError(@TypeOf(value))!void {
    try r.internal.takeBody();
    r.internal.body = .{ .bytes = try json_out.encode(r.internal.arena, value, .{}) };
    r.internal.content_type = "application/json";
}

pub const FileOptions = struct {
    /// Asks the client to save the file under this name:
    /// `Content-Disposition: attachment`.
    download_as: ?[]const u8 = null,
    /// The `Content-Type`, instead of the one of the file's extension.
    content_type: ?[]const u8 = null,
};

/// Sends the file at `path`, read from the disk as it goes out: the type
/// of its extension (`application/octet-stream` for one unknown), its
/// length, and with `download_as` a name to save it under.
///
/// ```zig
/// try ctx.response.file("reports/2026-10.pdf", .{ .download_as = "report.pdf" });
/// ```
///
/// `path` is relative to the working directory of the process, or
/// absolute: a path of the application, never one taken from the request,
/// which would let a client read any file. The response is finished when
/// this returns. An error before the head goes out (`FileNotFound`,
/// `ReadFailed` of a file that does not open) replaces the response; once
/// the file goes out, an error cuts it. See `FileError`.
pub fn file(r: *Response, path: []const u8, options: FileOptions) FileError!void {
    const i = &r.internal;
    try i.takeBody();
    const content_type = options.content_type orelse mime.of(path);
    if (!validValue(content_type)) return error.InvalidHeaderValue;
    const sink = try r.sinkFor("file");
    const io = sink.io;
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.FileNotFound,
        error.Canceled => return error.Canceled,
        else => return notOpened(err),
    };
    defer f.close(io);
    const info = f.stat(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return notOpened(err),
    };
    if (info.kind != .file) {
        log.warn("ctx.response.file: the path is a {t}, not a file; the response is 500", .{info.kind});
        return error.ReadFailed;
    }
    if (options.download_as) |name| try r.putField("content-disposition", try disposition(i.arena, name));
    return i.sendFile(f, try i.arena.dupe(u8, content_type), 0, info.size, "ctx.response.file");
}

fn notOpened(err: anyerror) error{ReadFailed} {
    log.warn("ctx.response.file could not open the file: error.{t}; the response is 500", .{err});
    return error.ReadFailed;
}

pub const StreamOptions = struct {
    /// The `Content-Type` of the body, such as "text/csv".
    content_type: []const u8,
    /// Asks the client to save the body as a file of this name:
    /// `Content-Disposition: attachment`.
    download_as: ?[]const u8 = null,
};

/// Begins a body written as it goes: for one too large to hold, or one
/// that comes over time.
///
/// ```zig
/// var out = try ctx.response.stream(.{ .content_type = "text/csv", .download_as = "todos.csv" });
/// try out.writeAll("id,title\n");
/// while (try rows.next()) |todo| try out.print("{d},{s}\n", .{ todo.id, todo.title });
/// try out.finish();
/// ```
///
/// The writes pass through the buffer of `buffer_size`. The head goes out
/// when the buffer first fills, at `flush`, or at `finish`; until then the
/// status and the fields can still change, and an error replaces the
/// response. From then on the response is committed: an error cuts it, so
/// the client sees it broken, never as a whole body. A body that ends
/// within the buffer goes with `Content-Length`, a larger one chunked (to
/// an HTTP/1.0 client, until the connection closes). A handler that
/// returns without `finish` has its stream ended for it. A HEAD request
/// gets the head alone.
pub fn stream(r: *Response, options: StreamOptions) StreamError!Stream {
    const i = &r.internal;
    try i.takeBody();
    if (!validValue(options.content_type)) return error.InvalidHeaderValue;
    _ = try r.sinkFor("stream");
    try i.useBuffer();
    if (options.download_as) |name| try r.putField("content-disposition", try disposition(i.arena, name));
    i.content_type = try i.arena.dupe(u8, options.content_type);
    i.body = .stream;
    return .{ .internal = i };
}

/// A body written as it goes, from `ctx.response.stream`. A write that
/// fails breaks it: every write after fails too, and the server cuts the
/// response.
pub const Stream = struct {
    /// Internal to the server.
    internal: *Internal,

    /// Writes `bytes`; they go out when the buffer fills, at `flush` or at
    /// `finish`.
    pub fn writeAll(s: *Stream, bytes: []const u8) Exchange.WriteError!void {
        const out = try s.open();
        out.writer.writeAll(bytes) catch return out.failure orelse error.WriteFailed;
    }

    /// Writes `fmt` formatted with `args`, as `std.Io.Writer.print` does.
    pub fn print(s: *Stream, comptime fmt: []const u8, args: anytype) Exchange.WriteError!void {
        const out = try s.open();
        out.writer.print(fmt, args) catch return out.failure orelse error.WriteFailed;
    }

    /// Sends what is written now, and the head if it has not gone: for a
    /// client that waits for each part. The body goes chunked from then on.
    pub fn flush(s: *Stream) Exchange.WriteError!void {
        _ = try s.open();
        const i = s.internal;
        try i.push();
        const sink = i.sink.?;
        sink.exchange.flush(sink.io) catch |err| return i.fail(err);
    }

    /// Ends the body: what is left of it, then the end. The response is
    /// finished; a write after it is `WriteFailed`.
    pub fn finish(s: *Stream) Exchange.WriteError!void {
        _ = try s.open();
        return s.internal.finishBody();
    }

    fn open(s: *Stream) Exchange.WriteError!*Out {
        const i = s.internal;
        // Ended, or replaced by the server's answer to an error.
        if (i.state == .finished or i.body != .stream) return error.WriteFailed;
        if (i.out.failure) |err| return err;
        return &i.out;
    }
};

/// The sink of a body written as it goes, if the backend can send one.
fn sinkFor(r: *const Response, what: []const u8) error{WriteFailed}!Sink {
    const sink = r.internal.sink orelse return error.WriteFailed;
    if (!sink.streaming) {
        log.warn("ctx.response.{s} needs a backend with streaming_response, and this backend has none", .{what});
        return error.WriteFailed;
    }
    return sink;
}

/// `attachment; filename="…"; filename*=UTF-8''…` for a file saved as
/// `name` (RFC 6266): the name in ASCII, `_` for each character ASCII
/// lacks and for `"` and `\`, then the name itself, percent-encoded, for
/// the clients that read it.
fn disposition(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "attachment; filename=\"");
    for (name) |c| {
        // The rest of a character past ASCII: its first byte became '_'.
        if (c >= 0x80 and c < 0xc0) continue;
        try out.append(arena, if (c < 0x20 or c >= 0x7f or c == '"' or c == '\\') '_' else c);
    }
    try out.appendSlice(arena, "\"; filename*=UTF-8''");
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.findScalar(u8, "!#$&+-.^_`|~", c) != null) {
            try out.append(arena, c);
        } else try out.print(arena, "%{X:0>2}", .{c});
    }
    return out.items;
}

fn setBody(r: *Response, content_type: []const u8, bytes: []const u8) error{ ResponseCommitted, OutOfMemory }!void {
    try r.internal.takeBody();
    r.internal.body = .{ .bytes = try r.internal.arena.dupe(u8, bytes) };
    r.internal.content_type = content_type;
}

/// Whether `name` and `value` may be set now.
fn checkField(r: *const Response, name: []const u8, value: []const u8) SetError!void {
    if (r.internal.state != .uncommitted) return error.ResponseCommitted;
    if (!validName(name) or !validValue(value)) return error.InvalidHeaderValue;
    for (reserved_names) |reserved| {
        if (std.ascii.eqlIgnoreCase(name, reserved)) return error.ReservedHeader;
    }
    // A field per cookie: setting it would replace one of setCookie's.
    if (std.ascii.eqlIgnoreCase(name, "set-cookie")) return error.ReservedHeader;
}

/// Sets the field `name` to `value`, which lives in the arena already.
fn putField(r: *Response, name: []const u8, value: []const u8) error{OutOfMemory}!void {
    const arena = r.internal.arena;
    if (std.ascii.eqlIgnoreCase(name, "content-type")) {
        r.internal.content_type = value;
        return;
    }
    for (r.internal.headers.items) |*f| {
        if (std.ascii.eqlIgnoreCase(f.name, name)) {
            f.value = value;
            return;
        }
    }
    try r.internal.headers.append(arena, .{ .name = try arena.dupe(u8, name), .value = value });
}

fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!h1.isToken(c)) return false;
    }
    return true;
}

fn validValue(value: []const u8) bool {
    for (value) |c| {
        if (!h1.isValueChar(c)) return false;
    }
    return true;
}

/// cookie-octet (RFC 6265 §4.1.1): visible ASCII but `"`, `,`, `;`, `\`.
fn validCookieValue(value: []const u8) bool {
    for (value) |c| {
        if (c < 0x21 or c > 0x7e or c == '"' or c == ',' or c == ';' or c == '\\') return false;
    }
    return true;
}

/// The value of `Path` or `Domain`: ASCII without controls and `;`.
fn validAttribute(value: []const u8) bool {
    for (value) |c| {
        if (c < 0x20 or c > 0x7e or c == ';') return false;
    }
    return true;
}

const testing = std.testing;

/// A response without a backend, as the unit tests of this file use it.
fn bare(arena: std.mem.Allocator) Response {
    return .{ .internal = .{ .arena = arena } };
}

test "setHeader rejects CR, LF and NUL" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var r = bare(arena_state.allocator());

    for ([_][2][]const u8{
        .{ "x-a", "one\r\nset-cookie: evil=1" },
        .{ "x-a", "one\ntwo" },
        .{ "x-a", "one\rtwo" },
        .{ "x-a", "one\x00two" },
        .{ "x-a", "bell\x07" },
        .{ "x-a\r\nx-b", "1" },
        .{ "x-a\x00", "1" },
        .{ "x a", "1" },
        .{ "x-a:", "1" },
        .{ "", "1" },
    }) |h| {
        try testing.expectError(error.InvalidHeaderValue, r.setHeader(h[0], h[1]));
    }
    try testing.expectEqual(0, r.internal.headers.items.len);

    // A tab and bytes past ASCII are fine; a second set replaces the first.
    try r.setHeader("X-Note", "a\tb caf\xc3\xa9");
    try r.setHeader("x-note", "second");
    try r.setHeader("Retry-After", "5");
    try testing.expectEqual(2, r.internal.headers.items.len);
    try testing.expectEqualStrings("X-Note", r.internal.headers.items[0].name);
    try testing.expectEqualStrings("second", r.internal.headers.items[0].value);

    // The value is copied: the caller's buffer may go.
    var buffer = "text/csv".*;
    try r.setHeader("content-type", &buffer);
    buffer[0] = 'X';
    try testing.expectEqualStrings("text/csv", r.internal.content_type.?);
    try testing.expectEqual(2, r.internal.headers.items.len);
}

test "setHeader refuses the fields the backend writes itself, in any case" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var r = bare(arena_state.allocator());

    for ([_][]const u8{
        "content-length", "Content-Length", "transfer-encoding", "TRANSFER-ENCODING",
        "connection",     "Keep-Alive",     "te",                "Trailer",
        "upgrade",        "date",           "DATE",
    }) |name| {
        try testing.expectError(error.ReservedHeader, r.setHeader(name, "1"));
    }
    try testing.expectEqual(0, r.internal.headers.items.len);
    // Names that only begin or end like one are the application's.
    try r.setHeader("content-length-hint", "1");
    try r.setHeader("x-date", "1");
    try r.setHeader("tea", "1");
    try testing.expectEqual(3, r.internal.headers.items.len);

    // Set-Cookie is setCookie's, a field per cookie: setHeader would
    // replace the first of them.
    try r.setCookie(.{ .name = "session", .value = "s1" });
    try testing.expectError(error.ReservedHeader, r.setHeader("set-cookie", "theme=dark"));
    try testing.expectError(error.ReservedHeader, r.setHeaderFmt("Set-Cookie", "theme={s}", .{"dark"}));
    try testing.expectEqualStrings("session=s1; Path=/", r.internal.headers.items[3].value);
}

test "text, html and json set the body and its type; status is chainable" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var r = bare(arena_state.allocator());
    try testing.expect(!r.internal.written());

    try r.status(404).html("<h1>Not here</h1>");
    try testing.expectEqual(404, r.internal.code.?);
    try testing.expectEqualStrings("text/html; charset=utf-8", r.internal.content_type.?);
    try testing.expectEqualStrings("<h1>Not here</h1>", r.internal.body.bytes);
    try testing.expect(r.internal.written());

    try r.text("plain");
    try testing.expectEqualStrings("text/plain; charset=utf-8", r.internal.content_type.?);
    try r.json(.{ .id = 7, .title = "Buy milk" });
    try testing.expectEqualStrings("application/json", r.internal.content_type.?);
    try testing.expectEqualStrings("{\"id\":7,\"title\":\"Buy milk\"}", r.internal.body.bytes);
}

test "setHeader after commit is ResponseCommitted; finish happens once" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var r = bare(arena_state.allocator());
    try testing.expectEqual(.uncommitted, r.state());
    try r.status(201).setHeader("x-a", "1");

    // The server commits the response when its head goes out: from then
    // on nothing of it changes.
    r.internal.state = .committed;
    try testing.expectEqual(.committed, r.state());
    try testing.expectError(error.ResponseCommitted, r.setHeader("x-a", "2"));
    try testing.expectError(error.ResponseCommitted, r.setHeader("x-b", "2"));
    try testing.expectError(error.ResponseCommitted, r.setHeaderFmt("x-b", "{d}", .{2}));
    try testing.expectError(error.ResponseCommitted, r.setCookie(.{ .name = "a", .value = "b" }));
    try testing.expectError(error.ResponseCommitted, r.redirect("/"));
    try testing.expectError(error.ResponseCommitted, r.text("late"));
    try testing.expectError(error.ResponseCommitted, r.html("late"));
    try testing.expectError(error.ResponseCommitted, r.json(.{ .late = true }));
    try testing.expectError(error.ResponseCommitted, r.status(500).text("late"));
    try testing.expectError(error.ResponseCommitted, r.stream(.{ .content_type = "text/plain" }));
    try testing.expectError(error.ResponseCommitted, r.file("late.txt", .{}));
    try testing.expectEqual(201, r.internal.code.?);
    try testing.expectEqual(1, r.internal.headers.items.len);
    try testing.expectEqualStrings("1", r.internal.headers.items[0].value);
    try testing.expect(r.internal.body == .none);
    // The server's own path, through http.testing, is in flow.zig: a
    // response is written once, and an error after commit cuts it.
}

test "setHeaderFmt formats the value" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var r = bare(arena_state.allocator());
    try r.setHeaderFmt("Server-Timing", "app;dur={d}", .{12});
    try r.setHeaderFmt("server-timing", "app;dur={d}, db;dur={d}", .{ 12, 3 });
    try testing.expectEqual(1, r.internal.headers.items.len);
    try testing.expectEqualStrings("Server-Timing", r.internal.headers.items[0].name);
    try testing.expectEqualStrings("app;dur=12, db;dur=3", r.internal.headers.items[0].value);
    try r.setHeaderFmt("content-type", "text/{s}; charset=utf-8", .{"csv"});
    try testing.expectEqualStrings("text/csv; charset=utf-8", r.internal.content_type.?);
    // What it formats is checked as setHeader checks a value.
    try testing.expectError(error.InvalidHeaderValue, r.setHeaderFmt("x-name", "{s}", .{"a\r\nset-cookie: evil=1"}));
    try testing.expectError(error.ReservedHeader, r.setHeaderFmt("content-length", "{d}", .{5}));
    try testing.expectEqual(1, r.internal.headers.items.len);
}

test "setCookie writes every attribute and rejects a bad value" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var r = bare(arena_state.allocator());

    try r.setCookie(.{ .name = "session", .value = "abc.123", .domain = "example.com", .max_age = .fromSeconds(3600), .secure = true, .http_only = true, .same_site = .lax });
    try r.setCookie(.{ .name = "theme", .value = "dark", .path = null });
    try r.setCookie(.{ .name = "old", .value = "", .max_age = .zero, .same_site = .strict });
    // A negative age deletes the cookie too.
    try r.setCookie(.{ .name = "cross", .value = "1", .path = "/api", .max_age = .fromSeconds(-5), .secure = true, .same_site = .none });
    // Each cookie is a field of its own, even with a name used before.
    try r.setCookie(.{ .name = "theme", .value = "light" });
    const expected = [_][]const u8{
        "session=abc.123; Path=/; Domain=example.com; Max-Age=3600; Secure; HttpOnly; SameSite=Lax",
        "theme=dark",
        "old=; Path=/; Max-Age=0; SameSite=Strict",
        "cross=1; Path=/api; Max-Age=0; Secure; SameSite=None",
        "theme=light; Path=/",
    };
    try testing.expectEqual(expected.len, r.internal.headers.items.len);
    for (expected, r.internal.headers.items) |line, field| {
        try testing.expectEqualStrings("set-cookie", field.name);
        try testing.expectEqualStrings(line, field.value);
    }

    // What a cookie may not hold, in its name, its value, its path or its
    // domain: a field of its own could follow.
    for ([_]Cookie{
        .{ .name = "", .value = "1" },
        .{ .name = "a b", .value = "1" },
        .{ .name = "a=b", .value = "1" },
        .{ .name = "a;b", .value = "1" },
        .{ .name = "a", .value = "two words" },
        .{ .name = "a", .value = "x;y" },
        .{ .name = "a", .value = "x,y" },
        .{ .name = "a", .value = "\"quoted\"" },
        .{ .name = "a", .value = "back\\slash" },
        .{ .name = "a", .value = "x\r\nset-cookie: evil=1" },
        .{ .name = "a", .value = "caf\xc3\xa9" },
        .{ .name = "a", .value = "tab\t" },
        .{ .name = "a", .value = "1", .path = "/a;Domain=evil.example" },
        .{ .name = "a", .value = "1", .path = "/a\nb" },
        .{ .name = "a", .value = "1", .domain = "example.com; Secure" },
    }) |bad| {
        testing.expectError(error.InvalidHeaderValue, r.setCookie(bad)) catch |err| {
            std.debug.print("accepted: {s}={s}\n", .{ bad.name, bad.value });
            return err;
        };
    }
    try testing.expectEqual(expected.len, r.internal.headers.items.len);
}

test "redirect keeps a 3xx status, else 302" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var found = bare(arena);
    try found.redirect("/login");
    try testing.expectEqual(302, found.internal.code.?);
    try testing.expectEqualStrings("location", found.internal.headers.items[0].name);
    try testing.expectEqualStrings("/login", found.internal.headers.items[0].value);

    for ([_]u16{ 301, 303, 307, 308 }) |code| {
        var kept = bare(arena);
        try kept.status(code).redirect("https://example.com/next?page=2");
        try testing.expectEqual(code, kept.internal.code.?);
    }
    // A status that is not a redirect gives way to 302.
    for ([_]u16{ 200, 201, 404, 299, 400 }) |code| {
        var replaced = bare(arena);
        try replaced.status(code).redirect("/");
        try testing.expectEqual(302, replaced.internal.code.?);
    }
    // A location that would split the response: nothing changes.
    var split = bare(arena);
    try testing.expectError(error.InvalidHeaderValue, split.status(303).redirect("/\r\nset-cookie: evil=1"));
    try testing.expectEqual(0, split.internal.headers.items.len);
    try testing.expectEqual(303, split.internal.code.?);
}

test "download_as: the name in ASCII, and percent-encoded" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings(
        "attachment; filename=\"report 2026.pdf\"; filename*=UTF-8''report%202026.pdf",
        try disposition(arena, "report 2026.pdf"),
    );
    // Each character past ASCII is one '_'; quotes and backslashes too,
    // and CR and LF never reach the field.
    try testing.expectEqualStrings(
        "attachment; filename=\"_____ _q_.pdf\"; filename*=UTF-8''%D0%BE%D1%82%D1%87%D1%91%D1%82%20%22q%22.pdf",
        try disposition(arena, "отчёт \"q\".pdf"),
    );
    try testing.expectEqualStrings(
        "attachment; filename=\"a__b_c\"; filename*=UTF-8''a%0D%0Ab%5Cc",
        try disposition(arena, "a\r\nb\\c"),
    );
}

test "stream and file on a backend without streaming_response: WriteFailed" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var r = bare(arena_state.allocator());
    // The exchange is not reached: the capability is checked first.
    r.internal.sink = .{ .exchange = undefined, .io = testing.io, .streaming = false };
    const level = testing.log_level;
    testing.log_level = .err; // the refusal is logged as a warning
    defer testing.log_level = level;

    try testing.expectError(error.WriteFailed, r.stream(.{ .content_type = "text/csv" }));
    try testing.expectError(error.WriteFailed, r.file("report.pdf", .{}));
    try testing.expect(!r.internal.written());
    try testing.expectEqual(.uncommitted, r.state());
    // What the backend never sees is still checked first.
    try testing.expectError(error.InvalidHeaderValue, r.stream(.{ .content_type = "text/csv\r\nx-a: 1" }));
    try testing.expectError(error.InvalidHeaderValue, r.file("report.pdf", .{ .content_type = "a\nb" }));
}

const Server = @import("Server.zig");
const Context = @import("Context.zig");
const TestingBackend = @import("testing/Backend.zig");
const routes = @import("routes.zig");
const Json = @import("dto.zig").Json;

const Todo = struct { id: u64, title: []const u8 };

/// 20 KiB: more than the buffer.
const filler: [20 << 10]u8 = @splat('x');

/// Handlers of files, streams and `http.Json` values larger than the
/// buffer; what they see goes into the controller for the test. Its server
/// turns the strict error check off: `FileNotFound` stays unmapped, a 500.
const ExportsV1Controller = struct {
    /// Relative to the working directory: a file of 40 000 bytes, a small
    /// one, and the directory that holds them.
    report_path: []const u8 = "",
    notes_path: []const u8 = "",
    dir_path: []const u8 = "",
    file_error: ?FileError = null,
    /// What a handler got after the head went out.
    state_after: ?State = null,
    late_header: ?(SetError!void) = null,
    late_write: ?(Exchange.WriteError!void) = null,

    pub const http_routes = routes.routes(.{
        .prefix = "/v1",
        .methods = .{
            .report = routes.get("/report", .{}),
            .notes = routes.get("/notes", .{}),
            .missing = routes.get("/missing", .{}),
            .not_dir = routes.get("/not-dir", .{}),
            .folder = routes.get("/folder", .{}),
            .csv = routes.get("/export.csv", .{}),
            .small = routes.get("/small.csv", .{}),
            .unfinished = routes.get("/unfinished", .{}),
            .broken = routes.get("/broken", .{}),
            .early = routes.get("/early", .{}),
            .late = routes.get("/late", .{ .timeout = std.Io.Duration.fromMilliseconds(50) }),
            .many = routes.get("/todos", .{}),
            .one = routes.get("/todos/one", .{}),
            .login = routes.post("/login", .{}),
        },
    });

    pub fn report(self: *ExportsV1Controller, ctx: *Context) FileError!void {
        try ctx.response.file(self.report_path, .{ .download_as = "report 2026.pdf" });
        self.state_after = ctx.response.state();
        self.late_header = ctx.response.setHeader("x-late", "1");
    }
    pub fn notes(self: *ExportsV1Controller, ctx: *Context) FileError!void {
        try ctx.response.setHeader("cache-control", "no-store");
        try ctx.response.file(self.notes_path, .{ .content_type = "text/markdown; charset=utf-8" });
    }
    pub fn missing(self: *ExportsV1Controller, ctx: *Context) FileError!void {
        return self.fileOf(ctx, "no/such/report.pdf");
    }
    pub fn not_dir(self: *ExportsV1Controller, ctx: *Context) FileError!void {
        // A part of the path is a file, not a directory.
        return self.fileOf(ctx, try std.fmt.allocPrint(ctx.allocator(), "{s}/inner.txt", .{self.notes_path}));
    }
    pub fn folder(self: *ExportsV1Controller, ctx: *Context) FileError!void {
        return self.fileOf(ctx, self.dir_path);
    }
    fn fileOf(self: *ExportsV1Controller, ctx: *Context, path: []const u8) FileError!void {
        ctx.response.file(path, .{}) catch |err| {
            self.file_error = err;
            return err;
        };
    }
    pub fn csv(self: *ExportsV1Controller, ctx: *Context) !void {
        var out = try ctx.response.stream(.{ .content_type = "text/csv", .download_as = "todos.csv" });
        try out.writeAll("id,title\n");
        try out.flush();
        self.state_after = ctx.response.state();
        self.late_header = ctx.response.setHeader("x-late", "1");
        for (0..1000) |i| try out.print("{d},todo number {d}\n", .{ i, i });
        try out.finish();
        self.late_write = out.writeAll("late");
    }
    pub fn small(_: *ExportsV1Controller, ctx: *Context) !void {
        var out = try ctx.response.stream(.{ .content_type = "text/csv" });
        try out.writeAll("a,b\n");
        try out.finish();
    }
    pub fn unfinished(_: *ExportsV1Controller, ctx: *Context) !void {
        var out = try ctx.response.stream(.{ .content_type = "text/plain" });
        try out.writeAll(&filler);
        try out.writeAll("left for the server to end");
    }
    pub fn broken(self: *ExportsV1Controller, ctx: *Context) !void {
        var out = try ctx.response.stream(.{ .content_type = "text/csv" });
        // The first 16 KiB go out: the response is committed.
        try out.writeAll(&filler);
        self.late_header = ctx.response.setHeader("x-late", "1");
        return error.ExportFailed;
    }
    pub fn early(_: *ExportsV1Controller, ctx: *Context) !void {
        var out = try ctx.response.stream(.{ .content_type = "text/csv", .download_as = "todos.csv" });
        // Within the buffer: nothing has gone out.
        try out.writeAll("id,title\n");
        return error.ExportFailed;
    }
    pub fn late(_: *ExportsV1Controller, ctx: *Context) !void {
        var out = try ctx.response.stream(.{ .content_type = "text/plain" });
        try out.writeAll("first part\n");
        try out.flush();
        // Past the route's deadline of 50 ms.
        try ctx.io().sleep(.fromSeconds(1), .awake);
        try out.finish();
    }
    pub fn many(_: *ExportsV1Controller, ctx: *Context) !Json([]const Todo) {
        const list = try ctx.allocator().alloc(Todo, 1000);
        for (list, 0..) |*t, i| t.* = .{ .id = i, .title = "a todo of the list" };
        return .{ .value = list };
    }
    pub fn one(_: *ExportsV1Controller, _: *Context) !Json(Todo) {
        return .{ .value = .{ .id = 7, .title = "Buy milk" } };
    }
    pub fn login(_: *ExportsV1Controller, ctx: *Context) !void {
        try ctx.response.setCookie(.{ .name = "session", .value = "abc", .http_only = true, .same_site = .lax, .secure = true, .max_age = .fromSeconds(8 * 3600) });
        try ctx.response.setCookie(.{ .name = "theme", .value = "dark" });
        try ctx.response.status(303).redirect("/");
    }
};

const Fixture = struct {
    exports: ExportsV1Controller = .{},
    backend: TestingBackend = undefined,
    server: Server = undefined,

    fn start(f: *Fixture, io: std.Io) !void {
        f.backend = .init(testing.allocator);
        f.server = try .init(testing.allocator, .{ .backend = f.backend.backend(), .controllers = .{&f.exports}, .strict_errors = false });
        f.server.start(io) catch |err| {
            f.server.deinit(io);
            return err;
        };
    }

    fn stop(f: *Fixture, io: std.Io) void {
        f.server.deinit(io);
        f.backend.deinit();
    }

    fn request(f: *Fixture, method: std.http.Method, target: []const u8) !TestingBackend.Response {
        return f.backend.request(testing.io, .{ .method = method, .target = target });
    }
};

test "setCookie and redirect through the server: every cookie a field, 303 to its location" {
    var f: Fixture = .{};
    try f.start(testing.io);
    defer f.stop(testing.io);

    var res = try f.request(.POST, "/v1/login");
    defer res.deinit();
    try testing.expectEqual(303, res.status);
    try testing.expectEqualStrings("/", res.header("location").?);
    try testing.expectEqualStrings("0", res.header("content-length").?);
    var cookies: std.ArrayList([]const u8) = .empty;
    defer cookies.deinit(testing.allocator);
    for (res.headers) |h| if (std.ascii.eqlIgnoreCase(h[0], "set-cookie")) try cookies.append(testing.allocator, h[1]);
    try testing.expectEqual(2, cookies.items.len);
    try testing.expectEqualStrings("session=abc; Path=/; Max-Age=28800; Secure; HttpOnly; SameSite=Lax", cookies.items[0]);
    try testing.expectEqualStrings("theme=dark; Path=/", cookies.items[1]);
}

/// The test files: a report of 40 000 bytes, more than two buffers, and a
/// small note, in a directory of their own under the working directory.
const Files = struct {
    tmp: testing.TmpDir,
    report: [40_000]u8,

    fn create(files: *Files, arena: std.mem.Allocator, exports: *ExportsV1Controller) !void {
        files.tmp = testing.tmpDir(.{});
        for (&files.report, 0..) |*b, i| b.* = @truncate(i *% 31 +% i / 256);
        try files.tmp.dir.writeFile(testing.io, .{ .sub_path = "report.pdf", .data = &files.report });
        try files.tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.md", .data = "# Notes\n" });
        exports.dir_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{files.tmp.sub_path});
        exports.report_path = try std.fmt.allocPrint(arena, "{s}/report.pdf", .{exports.dir_path});
        exports.notes_path = try std.fmt.allocPrint(arena, "{s}/notes.md", .{exports.dir_path});
    }
};

test "file streams with its type, length and Content-Disposition" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var f: Fixture = .{};
    var files: Files = undefined;
    try files.create(arena_state.allocator(), &f.exports);
    defer files.tmp.cleanup();
    try f.start(testing.io);
    defer f.stop(testing.io);

    var res = try f.request(.GET, "/v1/report");
    defer res.deinit();
    try testing.expectEqual(200, res.status);
    try testing.expect(!res.aborted);
    try testing.expectEqualStrings("application/pdf", res.header("content-type").?);
    try testing.expectEqualStrings("40000", res.header("content-length").?);
    try testing.expectEqual(null, res.header("transfer-encoding"));
    try testing.expectEqualStrings("attachment; filename=\"report 2026.pdf\"; filename*=UTF-8''report%202026.pdf", res.header("content-disposition").?);
    try testing.expectEqualSlices(u8, &files.report, res.body);
    // Read and sent a buffer at a time: never held whole.
    try testing.expectEqual(3, res.chunks.len);
    for (res.chunks) |chunk| try testing.expect(chunk.len <= buffer_size);
    // The file went out whole before file returned.
    try testing.expectEqual(.finished, f.exports.state_after.?);
    try testing.expectError(error.ResponseCommitted, f.exports.late_header.?);
    try testing.expectEqual(null, res.header("x-late"));

    // A type of its own; the fields set before stay.
    var notes = try f.request(.GET, "/v1/notes");
    defer notes.deinit();
    try testing.expectEqualStrings("text/markdown; charset=utf-8", notes.header("content-type").?);
    try testing.expectEqualStrings("no-store", notes.header("cache-control").?);
    try testing.expectEqualStrings("# Notes\n", notes.body);
    try testing.expectEqual(null, notes.header("content-disposition"));

    // HEAD: the head with the file's length, no body.
    var head = try f.request(.HEAD, "/v1/report");
    defer head.deinit();
    try testing.expectEqual(200, head.status);
    try testing.expectEqualStrings("40000", head.header("content-length").?);
    try testing.expectEqualStrings("", head.body);
    try testing.expect(!head.aborted);
}

test "file: a missing file is FileNotFound; a directory is ReadFailed and logged" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var f: Fixture = .{};
    var files: Files = undefined;
    try files.create(arena_state.allocator(), &f.exports);
    defer files.tmp.cleanup();
    try f.start(testing.io);
    defer f.stop(testing.io);
    const level = testing.log_level;
    testing.log_level = .err; // each 500 and the directory are logged as warnings
    defer testing.log_level = level;

    // No file, or a file where a directory should be: FileNotFound, for
    // the application to map; without a mapping it is 500.
    for ([_][]const u8{ "/v1/missing", "/v1/not-dir" }) |target| {
        f.exports.file_error = null;
        var res = try f.request(.GET, target);
        defer res.deinit();
        try testing.expectEqual(error.FileNotFound, f.exports.file_error.?);
        try testing.expectEqual(500, res.status);
        try testing.expectEqualStrings("application/problem+json", res.header("content-type").?);
        try testing.expect(!res.aborted);
    }
    // A directory: ReadFailed, logged with what the path is; nothing went
    // out before the error, so it is a whole 500.
    var dir = try f.request(.GET, "/v1/folder");
    defer dir.deinit();
    try testing.expectEqual(error.ReadFailed, f.exports.file_error.?);
    try testing.expectEqual(500, dir.status);
    try testing.expectEqualStrings("application/problem+json", dir.header("content-type").?);
    try testing.expect(!dir.aborted);
}

test "stream: chunks arrive as written; flush sends at once; finish ends the stream" {
    var f: Fixture = .{};
    try f.start(testing.io);
    defer f.stop(testing.io);

    var res = try f.request(.GET, "/v1/export.csv");
    defer res.deinit();
    try testing.expectEqual(200, res.status);
    try testing.expect(!res.aborted);
    try testing.expectEqualStrings("text/csv", res.header("content-type").?);
    try testing.expectEqualStrings("attachment; filename=\"todos.csv\"; filename*=UTF-8''todos.csv", res.header("content-disposition").?);
    try testing.expectEqualStrings("chunked", res.header("transfer-encoding").?);
    try testing.expectEqual(null, res.header("content-length"));
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, "id,title\n");
    for (0..1000) |i| try expected.print(testing.allocator, "{d},todo number {d}\n", .{ i, i });
    try testing.expectEqualStrings(expected.items, res.body);
    // The flush sent the first line alone, the full buffer the next part,
    // and finish the rest.
    try testing.expectEqual(3, res.chunks.len);
    try testing.expectEqualStrings("id,title\n", res.chunks[0]);
    try testing.expect(res.chunks[1].len <= buffer_size and res.chunks[1].len > buffer_size - 32);
    // The flush committed the response; finish ended it.
    try testing.expectEqual(.committed, f.exports.state_after.?);
    try testing.expectError(error.ResponseCommitted, f.exports.late_header.?);
    try testing.expectError(error.WriteFailed, f.exports.late_write.?);

    // A stream that ends within the buffer goes with its length.
    var small = try f.request(.GET, "/v1/small.csv");
    defer small.deinit();
    try testing.expectEqualStrings("4", small.header("content-length").?);
    try testing.expectEqual(null, small.header("transfer-encoding"));
    try testing.expectEqualStrings("a,b\n", small.body);

    // A handler that returns without finish: the server ends the stream.
    var unfinished = try f.request(.GET, "/v1/unfinished");
    defer unfinished.deinit();
    try testing.expect(!unfinished.aborted);
    try testing.expectEqualStrings("chunked", unfinished.header("transfer-encoding").?);
    try testing.expectEqual(filler.len + "left for the server to end".len, unfinished.body.len);
    try testing.expect(std.mem.endsWith(u8, unfinished.body, "left for the server to end"));
}

test "an error after commit cuts the stream" {
    var f: Fixture = .{};
    try f.start(testing.io);
    defer f.stop(testing.io);
    const level = testing.log_level;
    testing.log_level = .err; // the cut and the 500 are logged as warnings
    defer testing.log_level = level;

    // The first 16 KiB went out: the error cuts the response.
    var broken = try f.request(.GET, "/v1/broken");
    defer broken.deinit();
    try testing.expect(broken.aborted);
    try testing.expectEqual(200, broken.status);
    try testing.expectEqual(buffer_size, broken.body.len);
    try testing.expectError(error.ResponseCommitted, f.exports.late_header.?);

    // Nothing went out yet: the error replaces the response, and the
    // fields of the stream's content go with it.
    var early = try f.request(.GET, "/v1/early");
    defer early.deinit();
    try testing.expect(!early.aborted);
    try testing.expectEqual(500, early.status);
    try testing.expectEqualStrings("application/problem+json", early.header("content-type").?);
    try testing.expectEqual(null, early.header("content-disposition"));

    // The deadline of a committed response cuts it too: no 504 after its
    // head.
    const start = std.Io.Clock.awake.now(testing.io);
    var late = try f.request(.GET, "/v1/late");
    defer late.deinit();
    try testing.expect(start.durationTo(std.Io.Clock.awake.now(testing.io)).toMilliseconds() < 900);
    try testing.expect(late.aborted);
    try testing.expectEqual(200, late.status);
    try testing.expectEqualStrings("first part\n", late.body);
}

test "HEAD on a GET that streams: headers, no body" {
    var f: Fixture = .{};
    try f.start(testing.io);
    defer f.stop(testing.io);

    // Past the buffer: the head without a length, as for a chunked GET.
    var big = try f.request(.HEAD, "/v1/export.csv");
    defer big.deinit();
    try testing.expectEqual(200, big.status);
    try testing.expect(!big.aborted);
    try testing.expectEqualStrings("text/csv", big.header("content-type").?);
    try testing.expectEqualStrings("attachment; filename=\"todos.csv\"; filename*=UTF-8''todos.csv", big.header("content-disposition").?);
    try testing.expectEqual(null, big.header("content-length"));
    try testing.expectEqualStrings("", big.body);
    try testing.expectEqual(0, big.chunks.len);
    // Within the buffer: the length the GET would have.
    var small = try f.request(.HEAD, "/v1/small.csv");
    defer small.deinit();
    try testing.expectEqualStrings("4", small.header("content-length").?);
    try testing.expectEqualStrings("", small.body);
}

test "http.Json: a value past the buffer goes chunked, one within it with its length" {
    var f: Fixture = .{};
    try f.start(testing.io);
    defer f.stop(testing.io);

    var many = try f.request(.GET, "/v1/todos");
    defer many.deinit();
    try testing.expectEqual(200, many.status);
    try testing.expectEqualStrings("application/json", many.header("content-type").?);
    try testing.expectEqualStrings("chunked", many.header("transfer-encoding").?);
    try testing.expect(many.chunks.len >= 3);
    for (many.chunks) |chunk| try testing.expect(chunk.len <= buffer_size);
    const list = try std.json.parseFromSliceLeaky([]const Todo, many.arena.allocator(), many.body, .{});
    try testing.expectEqual(1000, list.len);
    try testing.expectEqual(999, list[999].id);
    try testing.expectEqualStrings("a todo of the list", list[999].title);

    var one = try f.request(.GET, "/v1/todos/one");
    defer one.deinit();
    try testing.expectEqualStrings("27", one.header("content-length").?);
    try testing.expectEqualStrings("{\"id\":7,\"title\":\"Buy milk\"}", one.body);
    try testing.expectEqual(1, one.chunks.len);

    var head = try f.request(.HEAD, "/v1/todos");
    defer head.deinit();
    try testing.expectEqual(200, head.status);
    try testing.expectEqual(null, head.header("content-length"));
    try testing.expectEqualStrings("", head.body);
}
