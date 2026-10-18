//! The backend of a server: it owns the connections
//! and the bytes of HTTP/1.1, hands the server parsed requests and takes
//! their responses. `http.native.Backend` serves the network and
//! `http.testing.Backend` serves tests from memory; the server sees only
//! this interface, a pointer and a table of functions, like `std.Io`.
//!
//! The server drives a backend through its life: `start` with the
//! server's handler, then, when the server stops, `stopAccepting`,
//! `cancelAll` for what outlives the grace, and `wait`. For each request
//! the backend calls `handler.serve` on a task of its own with an
//! `Exchange`: the parsed head, the body to read, and the functions that
//! send the response. A backend keeps no pointer into the memory of a
//! request after its response.
const std = @import("std");
const h1 = @import("h1/head.zig");

const Backend = @This();

ptr: *anyopaque,
vtable: *const VTable,

/// What a backend can do. `Server.start` refuses a server whose routes
/// need more: an SSE route needs `flush`, a static mount
/// `streaming_response`.
pub const Capabilities = packed struct(u8) {
    /// HTTP/1.1 requests and responses.
    http1: bool = false,
    /// A body sent while it is written: `stream`, `file`, static files.
    streaming_response: bool = false,
    /// Bytes sent at once, before the response ends: SSE.
    flush: bool = false,
    _: u5 = 0,
};

/// Why a backend did not start: its address is taken or not allowed, the
/// system is out of something, or the runtime gave it no task.
pub const StartError = error{ AddressInUse, AccessDenied, SystemResources, OutOfMemory, Unexpected } ||
    std.Io.ConcurrentError || std.Io.Cancelable;

pub const VTable = struct {
    capabilities: *const fn (ptr: *anyopaque) Capabilities,
    /// Begins to take requests and passes each to `handler`; returns once
    /// it takes them. The handler stays valid until `wait` has returned.
    start: *const fn (ptr: *anyopaque, io: std.Io, handler: Handler) StartError!void,
    /// Takes no new requests: idle connections close now, busy ones after
    /// their response. Never waits for them.
    stopAccepting: *const fn (ptr: *anyopaque, io: std.Io) void,
    /// Cancels every request still running: the tasks that run `serve` get
    /// `error.Canceled` from their next I/O.
    cancelAll: *const fn (ptr: *anyopaque, io: std.Io) void,
    /// Waits until every task of the backend has ended; after
    /// `stopAccepting`.
    wait: *const fn (ptr: *anyopaque, io: std.Io) void,
    /// The backend takes requests: for health checks.
    isReady: *const fn (ptr: *anyopaque) bool,
};

pub fn capabilities(b: Backend) Capabilities {
    return b.vtable.capabilities(b.ptr);
}

pub fn start(b: Backend, io: std.Io, handler: Handler) StartError!void {
    return b.vtable.start(b.ptr, io, handler);
}

pub fn stopAccepting(b: Backend, io: std.Io) void {
    b.vtable.stopAccepting(b.ptr, io);
}

pub fn cancelAll(b: Backend, io: std.Io) void {
    b.vtable.cancelAll(b.ptr, io);
}

pub fn wait(b: Backend, io: std.Io) void {
    b.vtable.wait(b.ptr, io);
}

pub fn isReady(b: Backend) bool {
    return b.vtable.isReady(b.ptr);
}

/// What the backend calls for each request: the server.
pub const Handler = struct {
    ptr: *anyopaque,
    /// Serves one request to its end, the response sent or aborted; on a
    /// task of the backend, which may run many at once.
    serve: *const fn (ptr: *anyopaque, io: std.Io, exchange: *Exchange) void,
};

/// One request and its response, between the backend and the server.
pub const Exchange = struct {
    ptr: *anyopaque,
    vtable: *const Exchange.VTable,
    method: std.http.Method,
    /// As it came: origin form (`/path?query`), absolute form
    /// (`http://host/path`), or `*` for OPTIONS.
    target: []const u8,
    version: h1.Version,
    /// The header fields, in order, names in the case they came in.
    fields: []const h1.Field,
    /// The address of the connection's peer; null when there is none.
    client: ?std.Io.net.IpAddress,
    /// The memory of the request, valid until the backend reads the
    /// connection's next request.
    arena: std.mem.Allocator,

    /// How the body of a response is delimited: none (204, 304), a length
    /// the backend sends as `Content-Length`, or a stream (chunked; to the
    /// end of the connection for HTTP/1.0).
    pub const BodyKind = union(enum) { none, length: u64, stream };
    /// Why `readBody` failed: 408 or 400.
    pub const BodyFailure = enum { timeout, malformed };
    pub const ReadError = error{ReadFailed} || std.Io.Cancelable;
    pub const WriteError = error{WriteFailed} || std.Io.Cancelable;

    /// For a HEAD request, and for 204 and 304, the backend sends no body:
    /// `.length` is then the length a body would have had. The backend
    /// writes the fields of framing itself (`Content-Length`,
    /// `Transfer-Encoding`) and `Date`.
    pub const VTable = struct {
        /// `Content-Length`; null when the body is chunked.
        bodyLength: *const fn (ptr: *anyopaque) ?u64,
        /// Reads the body into `buffer`, which is not empty; 0 at its end.
        /// The first call sends `100 Continue` when the client asked for it
        /// and no response has begun.
        readBody: *const fn (ptr: *anyopaque, io: std.Io, buffer: []u8) ReadError!usize,
        /// After `ReadFailed`: why; null for a broken connection.
        bodyFailure: *const fn (ptr: *anyopaque) ?BodyFailure,
        /// Returns when the client has gone, or when the watch is canceled.
        /// The request's watcher calls it on a task of its own once the
        /// body has been read to its end (or there is none), so it never
        /// reads the connection while `readBody` does, and so does the
        /// watcher of an SSE stream after it; a watcher is canceled when its
        /// request or stream ends, which the server knows, so it drops what
        /// a canceled watch tells. It has no deadline: the server keeps the
        /// request's deadline itself, so that a read of the watch never has
        /// a timer of its own (a read that a runtime completes as it is
        /// canceled must keep its bytes for the next request).
        watch: *const fn (ptr: *anyopaque, io: std.Io) void,
        writeHead: *const fn (ptr: *anyopaque, io: std.Io, status: u16, fields: []const h1.Field, body: BodyKind) WriteError!void,
        writeBody: *const fn (ptr: *anyopaque, io: std.Io, data: []const u8) WriteError!void,
        /// Sends what is buffered now.
        flush: *const fn (ptr: *anyopaque, io: std.Io) WriteError!void,
        /// Ends the response: the last chunk, or the end of its length.
        finish: *const fn (ptr: *anyopaque, io: std.Io) WriteError!void,
        /// Ends the response broken: no last chunk, or the connection
        /// closes, so the client sees it incomplete.
        abort: *const fn (ptr: *anyopaque, io: std.Io) void,
    };

    pub fn bodyLength(e: *const Exchange) ?u64 {
        return e.vtable.bodyLength(e.ptr);
    }

    pub fn readBody(e: *const Exchange, io: std.Io, buffer: []u8) ReadError!usize {
        return e.vtable.readBody(e.ptr, io, buffer);
    }

    pub fn bodyFailure(e: *const Exchange) ?BodyFailure {
        return e.vtable.bodyFailure(e.ptr);
    }

    pub fn watch(e: *const Exchange, io: std.Io) void {
        e.vtable.watch(e.ptr, io);
    }

    pub fn writeHead(e: *const Exchange, io: std.Io, status: u16, fields: []const h1.Field, body: BodyKind) WriteError!void {
        return e.vtable.writeHead(e.ptr, io, status, fields, body);
    }

    pub fn writeBody(e: *const Exchange, io: std.Io, data: []const u8) WriteError!void {
        return e.vtable.writeBody(e.ptr, io, data);
    }

    pub fn flush(e: *const Exchange, io: std.Io) WriteError!void {
        return e.vtable.flush(e.ptr, io);
    }

    pub fn finish(e: *const Exchange, io: std.Io) WriteError!void {
        return e.vtable.finish(e.ptr, io);
    }

    pub fn abort(e: *const Exchange, io: std.Io) void {
        e.vtable.abort(e.ptr, io);
    }
};
