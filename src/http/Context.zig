//! The context of one request (design section 6), as `*http.Context`:
//! what a handler, a middleware and the error handler see. The request is
//! `ctx.request`, the response `ctx.response`. Strings it gives live in
//! the request's arena until the request has ended; to keep one longer,
//! copy it.
//!
//! ```zig
//! pub fn get(self: *TodosV1Controller, ctx: *http.Context) !http.Json(dto.TodoResponse) {
//!     const todo = try self.repo.find(ctx.operation(), ctx.io(), ctx.allocator(), id);
//!     return .{ .value = .from(todo) };
//! }
//! ```
const std = @import("std");
const core = @import("core");
const routes = @import("routes.zig");
const h1 = @import("h1/head.zig");

const Context = @This();

/// The route a request matched.
pub const RouteInfo = routes.RouteInfo;
pub const Request = @import("Request.zig");
pub const Response = @import("Response.zig");

request: Request,
response: Response,
/// Internal to the server.
internal: Internal,

pub const Internal = struct {
    io: std.Io,
    operation: core.Context,
    arena: std.mem.Allocator,
    request_id: [32]u8,
    trace_id: [32]u8,
    route: ?RouteInfo = null,
    /// The values of the route's parameters, in the order of its pattern.
    params: []const []const u8 = &.{},
    /// The limit of `body`: the route's `.max_body_bytes`, else the
    /// server's.
    max_body_bytes: usize,
    /// What `body` returned, for the next calls.
    body: ?(BodyError![]const u8) = null,
};

/// The errors of `body`. `PayloadTooLarge` (413): over the limit.
/// `UnsupportedMediaType` (415): a `Content-Encoding` other than
/// `identity`; bodies are not decompressed. `BodyConsumed` (500): the body
/// was taken as a stream, by `ctx.request.bodyReader()`. `ReadFailed`: the
/// body did not arrive whole; a body that stalled or broke its chunked
/// framing gets the backend's 408 or 400, a broken connection 500.
pub const BodyError = error{ PayloadTooLarge, UnsupportedMediaType, BodyConsumed, ReadFailed } ||
    std.Io.Cancelable || std.mem.Allocator.Error;

/// The `std.Io` of the request, for every wait and every I/O: a database,
/// an HTTP client, the clock.
pub fn io(ctx: *const Context) std.Io {
    return ctx.internal.io;
}

/// The request as a `core.Context`, by value: its trace, its deadline (the
/// route's `.timeout` or the server's `.request_timeout`) and its token,
/// which the server cancels when the client has gone or a stop's grace is
/// over. Pass it to the services the handler calls; `check(ctx.now())`
/// gives `error.DeadlineExceeded` or `error.Cancelled`.
pub fn operation(ctx: *const Context) core.Context {
    return ctx.internal.operation;
}

/// The request's arena: what it gives is freed when the request has
/// ended, without a `free`.
pub fn allocator(ctx: *const Context) std.mem.Allocator {
    return ctx.internal.arena;
}

/// Now on the clock of core's deadlines (`std.Io.Clock.awake`), for
/// `ctx.operation().check(ctx.now())` and for measuring.
pub fn now(ctx: *const Context) std.Io.Timestamp {
    return std.Io.Clock.awake.now(ctx.internal.io);
}

/// The id of the request: 32 lowercase hex digits.
pub fn requestId(ctx: *const Context) []const u8 {
    return &ctx.internal.request_id;
}

/// The id of the request's trace: 32 lowercase hex digits, the client's
/// from `traceparent` or a new one.
pub fn traceId(ctx: *const Context) []const u8 {
    return &ctx.internal.trace_id;
}

/// The route the request matched: its method, pattern, controller and
/// handler; null before the route is chosen.
pub fn route(ctx: *const Context) ?RouteInfo {
    return ctx.internal.route;
}

/// The raw bytes of the request's body, such as for the signature of a
/// webhook: read once into the request's arena, within the route's
/// `.max_body_bytes` or else the server's. A second call returns the same
/// bytes, or the same error, without reading again.
///
/// A `Content-Length` over the limit is refused before a byte is read, so
/// a client that waits for `100 Continue` gets 413 instead; a chunked body
/// is refused once it crosses the limit. The body is read one way only:
/// after `ctx.request.bodyReader()` this is `error.BodyConsumed`, and
/// `bodyReader()` after it is too.
///
/// ```zig
/// const payload = try ctx.body();
/// if (!signatureMatches(payload, ctx.request.header("x-signature") orelse "")) return error.Unauthenticated;
/// ```
pub fn body(ctx: *Context) BodyError![]const u8 {
    if (ctx.internal.body) |result| return result;
    if (ctx.request.internal.body != null) return error.BodyConsumed;
    ctx.request.internal.bytes_taken = true;
    const result = readWhole(ctx);
    ctx.internal.body = result;
    return result;
}

fn readWhole(ctx: *Context) BodyError![]const u8 {
    const exchange = ctx.request.internal.exchange;
    if (!identityOnly(exchange.fields)) return error.UnsupportedMediaType;
    const limit = ctx.internal.max_body_bytes;
    const length = exchange.bodyLength();
    if (length) |n| if (n > limit) return error.PayloadTooLarge;
    const arena = ctx.internal.arena;
    var bytes: std.ArrayList(u8) = .empty;
    if (length) |n| {
        try bytes.ensureTotalCapacityPrecise(arena, @intCast(n));
        while (bytes.items.len < n) {
            const got = try exchange.readBody(ctx.internal.io, bytes.unusedCapacitySlice());
            // The backend ended the body before its length.
            if (got == 0) return error.ReadFailed;
            bytes.items.len += got;
        }
    } else {
        // Chunked: no more than a byte past the limit is read, so that a
        // body over it shows.
        const most = limit +| 1;
        while (true) {
            if (bytes.items.len == bytes.capacity) {
                const grown = @min(most, @max(4 << 10, bytes.capacity *| 2));
                try bytes.ensureTotalCapacityPrecise(arena, grown);
            }
            const room = bytes.unusedCapacitySlice();
            const got = try exchange.readBody(ctx.internal.io, room[0..@min(room.len, most - bytes.items.len)]);
            if (got == 0) break;
            bytes.items.len += got;
            if (bytes.items.len > limit) return error.PayloadTooLarge;
        }
    }
    // The body has been read to its end: the guard watches the connection.
    if (ctx.request.internal.body_done) |done| done.set(ctx.internal.io);
    return bytes.items;
}

/// Whether the body comes as it is: no `Content-Encoding`, or `identity`
/// alone, in any of its fields.
fn identityOnly(fields: []const h1.Field) bool {
    for (fields) |f| {
        if (!std.ascii.eqlIgnoreCase(f.name, "content-encoding")) continue;
        var codings = std.mem.splitScalar(u8, f.value, ',');
        while (codings.next()) |item| {
            const coding = std.mem.trim(u8, item, " \t");
            if (coding.len > 0 and !std.ascii.eqlIgnoreCase(coding, "identity")) return false;
        }
    }
    return true;
}

const testing = std.testing;
const Exchange = @import("Backend.zig").Exchange;
const Server = @import("Server.zig");
const TestingBackend = @import("testing/Backend.zig");

/// A request over `body` without a backend: `length` is the length it
/// declares (null: chunked); each read gives three bytes at most, and the
/// reads are counted.
const FakeBody = struct {
    exchange: Exchange,
    length: ?u64,
    body: []const u8,
    /// Bytes the reads have given.
    taken: usize = 0,
    reads: usize = 0,

    fn init(fields: []const h1.Field, length: ?u64, bytes: []const u8) FakeBody {
        return .{ .exchange = .{
            .ptr = undefined,
            .vtable = &.{
                .bodyLength = bodyLength,
                .readBody = readBody,
                .bodyFailure = undefined,
                .watch = undefined,
                .writeHead = undefined,
                .writeBody = undefined,
                .flush = undefined,
                .finish = undefined,
                .abort = undefined,
            },
            .method = .POST,
            .target = "/",
            .version = .http11,
            .fields = fields,
            .client = null,
            .arena = undefined,
        }, .length = length, .body = bytes };
    }

    /// A context over the fake, as the server makes one, with `limit` for
    /// the body; `done` is its event of the end of the body.
    fn context(f: *FakeBody, arena: std.mem.Allocator, limit: usize, done: *std.Io.Event) Context {
        f.exchange.ptr = f;
        f.exchange.arena = arena;
        return .{
            .request = .{ .method = .POST, .path = "/", .internal = .{ .exchange = &f.exchange, .io = testing.io, .body_done = done } },
            .response = .{ .internal = .{ .arena = arena } },
            .internal = .{
                .io = testing.io,
                .operation = core.Context.root,
                .arena = arena,
                .request_id = @splat('0'),
                .trace_id = @splat('0'),
                .max_body_bytes = limit,
            },
        };
    }

    fn of(ptr: *anyopaque) *FakeBody {
        return @ptrCast(@alignCast(ptr));
    }

    fn bodyLength(ptr: *anyopaque) ?u64 {
        return of(ptr).length;
    }

    fn readBody(ptr: *anyopaque, _: std.Io, buffer: []u8) Exchange.ReadError!usize {
        const f = of(ptr);
        f.reads += 1;
        const n = @min(buffer.len, 3, f.body.len - f.taken);
        @memcpy(buffer[0..n], f.body[f.taken..][0..n]);
        f.taken += n;
        return n;
    }
};

test "body: over the limit by Content-Length is 413 before reading; chunked over the limit is 413" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // By its length: refused before a read, so no 100 Continue goes out;
    // a second call gives the same answer and reads nothing either.
    var long: FakeBody = .init(&.{}, 9, "123456789");
    var long_done: std.Io.Event = .unset;
    var long_ctx = long.context(arena, 8, &long_done);
    try testing.expectError(error.PayloadTooLarge, long_ctx.body());
    try testing.expectError(error.PayloadTooLarge, long_ctx.body());
    try testing.expectEqual(0, long.reads);
    try testing.expect(!long_done.isSet());
    // At the limit: the body, and its end marked.
    var exact: FakeBody = .init(&.{}, 8, "12345678");
    var exact_done: std.Io.Event = .unset;
    var exact_ctx = exact.context(arena, 8, &exact_done);
    try testing.expectEqualStrings("12345678", try exact_ctx.body());
    try testing.expect(exact_done.isSet());

    // Chunked, the length unknown: refused once it crosses the limit, with
    // no more than a byte past it read.
    var chunked: FakeBody = .init(&.{}, null, "123456789abcdef");
    var chunked_done: std.Io.Event = .unset;
    var chunked_ctx = chunked.context(arena, 8, &chunked_done);
    try testing.expectError(error.PayloadTooLarge, chunked_ctx.body());
    try testing.expectEqual(9, chunked.taken);
    try testing.expect(!chunked_done.isSet());
    var within: FakeBody = .init(&.{}, null, "12345678");
    var within_done: std.Io.Event = .unset;
    var within_ctx = within.context(arena, 8, &within_done);
    try testing.expectEqualStrings("12345678", try within_ctx.body());
    try testing.expect(within_done.isSet());
    // Without a body: empty, and nothing read.
    var none: FakeBody = .init(&.{}, 0, "");
    var none_done: std.Io.Event = .unset;
    var none_ctx = none.context(arena, 8, &none_done);
    try testing.expectEqualStrings("", try none_ctx.body());
    try testing.expectEqual(0, none.reads);

    // Through the server: the route's .max_body_bytes, else the server's.
    const test_io = testing.io;
    var bodies: BodyController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&bodies}, .max_body_bytes = 4 });
    defer server.deinit(test_io);
    try server.start(test_io);
    for ([_]struct { []const u8, []const u8, u16 }{
        .{ "/small", "123456789", 413 },
        .{ "/small", "12345678", 200 },
        .{ "/echo", "12345", 413 },
        .{ "/echo", "1234", 200 },
    }) |case| {
        var res = try b.request(test_io, .{ .method = .POST, .target = case[0], .body = case[1] });
        defer res.deinit();
        testing.expectEqual(case[2], res.status) catch |err| {
            std.debug.print("POST {s} with {d} bytes\n", .{ case[0], case[1].len });
            return err;
        };
        if (case[2] == 200) try testing.expectEqualStrings(case[1], res.body);
        if (case[2] == 413) try expectCode(&res, "payload_too_large");
    }
}

test "body: gzip is 415" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var fake: FakeBody = .init(&.{.{ .name = "Content-Encoding", .value = "gzip" }}, 3, "abc");
    var done: std.Io.Event = .unset;
    var ctx = fake.context(arena_state.allocator(), 1 << 20, &done);
    try testing.expectError(error.UnsupportedMediaType, ctx.body());
    try testing.expectEqual(0, fake.reads);

    const test_io = testing.io;
    var bodies: BodyController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&bodies} });
    defer server.deinit(test_io);
    try server.start(test_io);
    for ([_]struct { []const u8, u16 }{
        .{ "gzip", 415 },
        .{ "br", 415 },
        .{ "identity, gzip", 415 },
        .{ "identity", 200 },
        .{ "Identity", 200 },
    }) |case| {
        var res = try b.request(test_io, .{ .method = .POST, .target = "/echo", .headers = &.{.{ "content-encoding", case[0] }}, .body = "abc" });
        defer res.deinit();
        testing.expectEqual(case[1], res.status) catch |err| {
            std.debug.print("Content-Encoding: {s}\n", .{case[0]});
            return err;
        };
        if (case[1] == 415) try expectCode(&res, "unsupported_media_type");
    }
}

test "body: a second call returns the same bytes; bodyReader after body is BodyConsumed and back" {
    const test_io = testing.io;
    var bodies: BodyController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&bodies} });
    defer server.deinit(test_io);
    try server.start(test_io);
    const level = testing.log_level;
    testing.log_level = .err; // the 500 is logged as a warning
    defer testing.log_level = level;

    var twice = try b.request(test_io, .{ .method = .POST, .target = "/twice", .body = "{\"title\":\"Buy milk\"}" });
    defer twice.deinit();
    try testing.expectEqual(200, twice.status);
    try testing.expectEqualStrings("{\"title\":\"Buy milk\"}", twice.body);
    try testing.expectEqualStrings("BodyConsumed", twice.header("x-reader").?);

    // The other way round: a program error, 500.
    var reader_first = try b.request(test_io, .{ .method = .POST, .target = "/reader-first", .body = "abc" });
    defer reader_first.deinit();
    try testing.expectEqual(500, reader_first.status);
    try testing.expectEqual(error.BodyConsumed, bodies.seen.?);
}

const BodyController = struct {
    /// What `reader_first` got from `ctx.body()`.
    seen: ?anyerror = null,

    pub const http_routes = routes.routes(.{ .methods = .{
        .echo = routes.post("/echo", .{}),
        .small = routes.post("/small", .{ .max_body_bytes = 8 }),
        .twice = routes.post("/twice", .{}),
        .reader_first = routes.post("/reader-first", .{}),
    } });

    pub fn echo(_: *BodyController, ctx: *Context) !void {
        try ctx.response.text(try ctx.body());
    }
    pub fn small(self: *BodyController, ctx: *Context) !void {
        return self.echo(ctx);
    }
    /// The same bytes twice, then a reader, which is BodyConsumed.
    pub fn twice(_: *BodyController, ctx: *Context) !void {
        const first = try ctx.body();
        const second = try ctx.body();
        if (first.ptr != second.ptr or first.len != second.len) return error.TestNotTheSameBytes;
        if (ctx.request.bodyReader()) |_| {
            return error.TestReaderAfterBody;
        } else |err| try ctx.response.setHeader("x-reader", @errorName(err));
        try ctx.response.text(second);
    }
    /// A reader, then the bytes.
    pub fn reader_first(self: *BodyController, ctx: *Context) !void {
        _ = try ctx.request.bodyReader();
        _ = ctx.body() catch |err| {
            self.seen = err;
            return err;
        };
    }
};

fn expectCode(res: *TestingBackend.Response, code: []const u8) !void {
    try testing.expectEqualStrings("application/problem+json", res.header("content-type").?);
    const problem = try std.json.parseFromSliceLeaky(struct { code: []const u8 }, res.arena.allocator(), res.body, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings(code, problem.code);
}
