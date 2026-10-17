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
const v = @import("validator");
const routes = @import("routes.zig");
const h1 = @import("h1/head.zig");
const dto = @import("dto.zig");
const Server = @import("Server.zig");
const flow = @import("flow.zig");
const strings = @import("input/strings.zig");
const urlencoded = @import("input/urlencoded.zig");
const cookie_input = @import("input/cookies.zig");
const json_in = @import("input/json_in.zig");
const collect = @import("input/violations.zig");
const plan = @import("plan.zig");
const mw = @import("middleware.zig");
const Subscription = @import("sse/Subscription.zig");

const Context = @This();
const Violation = v.Violation;
const log = std.log.scoped(.http);

/// The route a request matched.
pub const RouteInfo = routes.RouteInfo;
pub const Request = @import("Request.zig");
pub const Response = @import("Response.zig");
pub const Locals = @import("Locals.zig");

request: Request,
response: Response,
/// Values that a middleware puts for the middleware after it and for the
/// handler, one per type: `ctx.locals.put(T, value)`, `ctx.locals.get(T)`.
locals: Locals,
/// Internal to the server.
internal: Internal,

pub const Internal = struct {
    io: std.Io,
    operation: core.Context,
    arena: std.mem.Allocator,
    /// The server's allocator: the reports of `v.checkAll` come from it and
    /// are freed at once.
    gpa: std.mem.Allocator,
    /// The server's own id of the request.
    request_id: [32]u8,
    /// The `X-Request-Id` of a trusted peer: `requestId` gives it instead.
    given_request_id: ?[]const u8 = null,
    trace_id: [32]u8,
    route: ?RouteInfo = null,
    /// The names of the route's parameters and their values, in the order
    /// of its pattern.
    param_names: []const []const u8 = &.{},
    params: []const []const u8 = &.{},
    /// The limit of `body`: the route's `.max_body_bytes`, else the
    /// server's.
    max_body_bytes: usize,
    /// The server's `.max_query_params`, `.unknown_fields` and `.json`.
    max_query_params: u32 = 100,
    unknown_fields: Server.UnknownFieldsOptions = .{},
    json: Server.JsonOptions = .{},
    /// The violations of the input call that last failed with them.
    violations: []const Violation = &.{},
    /// What `body` returned, for the next calls.
    body: ?(BodyError![]const u8) = null,
    /// The server's error handler.
    error_handler: flow.ErrorHandler = .default,
    /// The middleware of the request: the server's, the route's once it
    /// is applied, and those the request reached.
    middleware: mw.Reached = .{},
    /// The server that serves the request; null in unit tests of a context.
    server: ?*Server = null,
    /// The route the request matched, as an index into `server.routes`.
    route_index: ?usize = null,
    /// The request holds a place of `.max_in_flight`: from its start to its
    /// end, or until `subscribe` moves it among the streams.
    in_flight: bool = false,
    /// The stream that `subscribe` opened for the request.
    subscription: ?*Subscription = null,
};

/// The errors of `body`. `PayloadTooLarge` (413): over the limit.
/// `UnsupportedMediaType` (415): a `Content-Encoding` other than
/// `identity`; bodies are not decompressed. `BodyConsumed` (500): the body
/// was taken as a stream, by `ctx.request.bodyReader()`. `ReadFailed`: the
/// body did not arrive whole; a body that stalled or broke its chunked
/// framing gets the backend's 408 or 400, a broken connection 500.
pub const BodyError = error{ PayloadTooLarge, UnsupportedMediaType, BodyConsumed, ReadFailed } ||
    std.Io.Cancelable || std.mem.Allocator.Error;

/// The errors of every input call (`path`, `query`, `json`, `form`,
/// `headers`, `cookies`). `InvalidRequest` (400): bad percent-encoding, a
/// string that is not valid UTF-8, more query parameters than
/// `.max_query_params`; a body that is not JSON, a key given twice in an
/// object, JSON nested deeper than `.json.max_depth`. `ValidationFailed`
/// (422): the input does not fit the DTO, or the DTO's rules refuse it;
/// `ctx.violations()` names the fields. A call's error set adds the errors
/// of the DTO's transforms, `v.TransformError(T)`.
pub const ExtractError = error{ InvalidRequest, ValidationFailed } || std.mem.Allocator.Error;

/// The error set of an input call for a `T` from `source`. Checks `T` at
/// compile time first.
fn InputError(comptime T: type, comptime source: strings.Source) type {
    comptime strings.check(T, source);
    return ExtractError || v.TransformError(T);
}

/// The error set of `json` for a `T`, checked at compile time first.
fn JsonError(comptime T: type) type {
    comptime json_in.check(T);
    return ExtractError || BodyError || v.TransformError(T);
}

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

/// The id of the request: the `X-Request-Id` that a trusted proxy sent
/// (`.trusted_proxies`; 1 to 128 visible ASCII characters), else a new one
/// of 32 lowercase hex digits.
pub fn requestId(ctx: *const Context) []const u8 {
    return ctx.internal.given_request_id orelse &ctx.internal.request_id;
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

/// The value of type `T` that a middleware put into `ctx.locals`.
/// `error.LocalMissing` (500, logged) when none did: a handler that needs
/// the plan of `PlanLookup` sits behind it. For a value that may be
/// missing, such as the user of an anonymous request, `ctx.locals.get(T)`
/// gives null instead.
///
/// ```zig
/// const plan = try ctx.local(mw.Plan); // put there by PlanLookup
/// ```
pub fn local(ctx: *const Context, comptime T: type) error{LocalMissing}!T {
    return ctx.locals.get(T) orelse {
        log.warn("ctx.local({s}): no middleware put a value of this type; the response is 500 (request {s})", .{ comptime plan.shortName(@typeName(T)), ctx.requestId() });
        return error.LocalMissing;
    };
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

/// What `body` reserves first of a body by its length.
const first_body_part = 64 << 10;

fn readWhole(ctx: *Context) BodyError![]const u8 {
    const exchange = ctx.request.internal.exchange;
    if (!identityOnly(exchange.fields)) return error.UnsupportedMediaType;
    const limit = ctx.internal.max_body_bytes;
    const length = exchange.bodyLength();
    if (length) |n| if (n > limit) return error.PayloadTooLarge;
    const arena = ctx.internal.arena;
    var bytes: std.ArrayList(u8) = .empty;
    if (length) |n| {
        // Reserved as it comes, doubling up to its length: a head that
        // announces a body and sends none of it costs no more than the
        // first part.
        const total: usize = @intCast(n);
        while (bytes.items.len < total) {
            if (bytes.items.len == bytes.capacity) {
                const grown = @min(total, @max(first_body_part, bytes.capacity *| 2));
                try bytes.ensureTotalCapacityPrecise(arena, grown);
            }
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
    // The body has been read to its end: the watcher watches the connection.
    if (ctx.request.internal.body_done) |done| done.set(ctx.internal.io);
    return bytes.items;
}

/// The parameters of the route as a `T`, each field the parameter of its
/// outside name: `{id}` fills the field `id`, `{userId}` a field with
/// `v.rename("userId")`. A field that the route's pattern does not name is
/// absent: null when it is optional, its default if it has one, else
/// `http.missing_field`.
///
/// ```zig
/// const TodoIdPath = struct { id: u64, pub const field_rules = .{ .id = v.positive } };
/// const params = try ctx.path(TodoIdPath);
/// ```
///
/// Every input call works in three steps. The strings fill the fields by
/// their outside names, as the table of design section 7 converts them;
/// what does not fit is `error.ValidationFailed`, with all its violations
/// in `ctx.violations()` (`http.invalid_type`, `http.missing_field`,
/// `http.unknown_field`). Then the transforms of `field_rules` run
/// (`v.transform`), and an error of a transform of your own comes back as
/// it is. Then the rules: `ValidationFailed` again, with the validator's
/// violations. The strings of the result live in the request's arena.
pub fn path(ctx: *Context, comptime T: type) InputError(T, .path)!T {
    const names = ctx.internal.param_names;
    const values = ctx.internal.params;
    const pairs = try ctx.internal.arena.alloc(strings.Pair, @min(names.len, values.len));
    for (pairs, names[0..pairs.len], values[0..pairs.len]) |*pair, name, value| pair.* = .{ .name = name, .value = value };
    return ctx.extract(T, .path, pairs, .ignore);
}

/// The query string as a `T`, by outside names: `?page=2&perPage=50`. A
/// name given again fills a `[]const T` field item by item; for another
/// field it is `http.invalid_type`, "must be given once". Unknown names are
/// ignored unless the server's `.unknown_fields.query` or the DTO's
/// `pub const unknown_fields = .reject;` says otherwise. '+' is a space and
/// `%HH` a byte; bad percent-encoding, invalid UTF-8 and more than
/// `.max_query_params` parameters are `error.InvalidRequest` (400).
pub fn query(ctx: *Context, comptime T: type) InputError(T, .query)!T {
    const pairs = try urlencoded.parse(ctx.internal.arena, ctx.request.internal.query, ctx.internal.max_query_params);
    return ctx.extract(T, .query, pairs, strings.unknownPolicy(T, ctx.internal.unknown_fields.query));
}

/// The JSON body as a `T`, by outside names: the key `userName` fills the
/// field renamed `v.rename("userName")`, a nested object a struct field, an
/// array a `[]const T`. Unknown keys are refused (`http.unknown_field`)
/// unless the server's `.unknown_fields.body` or the struct's own
/// `pub const unknown_fields = .ignore;` says otherwise.
///
/// The body is read with `ctx.body()`, so `ctx.json` again parses the same
/// bytes. It needs `Content-Type: application/json` or a `+json` type such
/// as `application/merge-patch+json`, else `error.UnsupportedMediaType`
/// (415) before the body is read. JSON that is broken, a key given twice in
/// one object and nesting deeper than `.json.max_depth` are
/// `error.InvalidRequest` (400). Then come the steps of every input call:
/// what does not fit is `ValidationFailed` with every violation at once, in
/// the order of the body (`http.invalid_type`, `http.missing_field`,
/// `http.unknown_field`, at paths such as `items[2].displayName`), then the
/// transforms, then the rules.
///
/// ```zig
/// const body = try ctx.json(dto.CreateTodoRequest);
/// ```
pub fn json(ctx: *Context, comptime T: type) JsonError(T)!T {
    if (!isJson(ctx.request.header("content-type"))) return error.UnsupportedMediaType;
    const bytes = try ctx.body();
    const arena = ctx.internal.arena;
    var sink: collect.Collector = .init(arena);
    const value = (try json_in.parse(T, arena, bytes, .{ .max_depth = ctx.internal.json.max_depth, .unknown = ctx.internal.unknown_fields.body }, &sink)) orelse {
        ctx.internal.violations = sink.items();
        return error.ValidationFailed;
    };
    return ctx.refine(T, value, .outside);
}

/// A form body, `application/x-www-form-urlencoded`, as a `T`: read with
/// `ctx.body()` and taken apart as the query is. Unknown fields are
/// refused (`http.unknown_field`) unless the server's `.unknown_fields.body`
/// or the DTO's `pub const unknown_fields = .ignore;` says otherwise.
/// Another `Content-Type` is `error.UnsupportedMediaType` (415), before
/// the body is read.
pub fn form(ctx: *Context, comptime T: type) (BodyError || InputError(T, .form))!T {
    if (!isForm(ctx.request.header("content-type"))) return error.UnsupportedMediaType;
    const bytes = try ctx.body();
    const pairs = try urlencoded.parse(ctx.internal.arena, bytes, ctx.internal.max_query_params);
    return ctx.extract(T, .form, pairs, strings.unknownPolicy(T, ctx.internal.unknown_fields.body));
}

/// The request's headers as a `T`: the field `idempotency_key` reads the
/// header `Idempotency-Key`, in any case. A header that comes in several
/// fields fills a `[]const []const u8` field, an item per field; for
/// another field it is "must be given once". Other headers are ignored.
/// Headers have names of their own, so `v.rename` in a DTO of headers is a
/// compile error; its transforms and rules work, and its violations name
/// the headers.
pub fn headers(ctx: *Context, comptime T: type) InputError(T, .headers)!T {
    const fields = ctx.request.internal.exchange.fields;
    const pairs = try ctx.internal.arena.alloc(strings.Pair, fields.len);
    for (pairs, fields) |*pair, f| pair.* = .{ .name = f.name, .value = f.value };
    return ctx.extract(T, .headers, pairs, .ignore);
}

/// The request's cookies as a `T`, by outside names, each value as it was
/// sent, without the quotes around it. Of two cookies with one name the
/// first wins; unknown cookies are ignored.
pub fn cookies(ctx: *Context, comptime T: type) InputError(T, .cookies)!T {
    const pairs = try cookie_input.parse(ctx.internal.arena, ctx.request.internal.exchange.fields);
    return ctx.extract(T, .cookies, pairs, .ignore);
}

/// The violations of the input call that last failed with
/// `error.ValidationFailed`, fields by their outside names: for the error
/// handler. At most `v.max_report_violations`.
pub fn violations(ctx: *const Context) []const Violation {
    return ctx.internal.violations;
}

/// Maps `pairs` into a `T`, transforms it and checks its rules.
fn extract(ctx: *Context, comptime T: type, comptime source: strings.Source, pairs: []const strings.Pair, unknown: dto.UnknownFields) InputError(T, source)!T {
    const arena = ctx.internal.arena;
    var sink: collect.Collector = .init(arena);
    const value = (try strings.map(T, source, arena, pairs, unknown, &sink)) orelse {
        ctx.internal.violations = sink.items();
        return error.ValidationFailed;
    };
    return ctx.refine(T, value, if (source == .headers) .headers else .outside);
}

/// How the violations of the rules name fields: by outside names, or, in a
/// DTO of headers, by the headers' names.
const Names = enum { outside, headers };

/// The steps of every input call after the mapping: the transforms of
/// `T`, then its rules; their violations go to `ctx.violations()`.
fn refine(ctx: *Context, comptime T: type, mapped: T, comptime names: Names) (ExtractError || v.TransformError(T))!T {
    const arena = ctx.internal.arena;
    var value = mapped;
    try v.transform(arena, &value);
    // The rules once without allocating; the report only when one fails.
    var path_buf: [256]u8 = undefined;
    if (v.check(&value, &path_buf) == null) return value;
    const report = try v.checkAll(ctx.internal.gpa, &value);
    defer report.deinit();
    const copied = try arena.alloc(Violation, report.violations.len);
    for (copied, report.violations) |*slot, item| {
        slot.* = item;
        const field = item.field orelse continue;
        const owned = try arena.dupe(u8, field);
        slot.field = if (names == .headers) try strings.headerPath(T, arena, owned) else owned;
    }
    ctx.internal.violations = copied;
    return error.ValidationFailed;
}

/// Whether `content_type` is `application/json` or a `+json` type, such as
/// `application/problem+json`, its parameters aside.
fn isJson(content_type: ?[]const u8) bool {
    const value = content_type orelse return false;
    const mime = std.mem.trim(u8, value[0 .. std.mem.findScalar(u8, value, ';') orelse value.len], " \t");
    if (std.ascii.eqlIgnoreCase(mime, "application/json")) return true;
    const slash = std.mem.findScalar(u8, mime, '/') orelse return false;
    const subtype = mime[slash + 1 ..];
    if (!isToken(mime[0..slash]) or !isToken(subtype)) return false;
    return subtype.len > "+json".len and std.ascii.endsWithIgnoreCase(subtype, "+json");
}

fn isToken(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (!h1.isToken(c)) return false;
    }
    return true;
}

/// Whether `content_type` is `application/x-www-form-urlencoded`, its
/// parameters aside.
fn isForm(content_type: ?[]const u8) bool {
    const value = content_type orelse return false;
    const mime = std.mem.trim(u8, value[0 .. std.mem.findScalar(u8, value, ';') orelse value.len], " \t");
    return std.ascii.eqlIgnoreCase(mime, "application/x-www-form-urlencoded");
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
            .locals = .init(arena),
            .internal = .{
                .io = testing.io,
                .operation = core.Context.root,
                .arena = arena,
                .gpa = testing.allocator,
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
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&bodies}, .strict_errors = false, .max_body_bytes = 4 });
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

test "body: a Content-Length is reserved as the body comes, not before its first byte" {
    // A head that announces a body of the limit and sends three bytes of
    // it: the request holds no more than the first part of the body.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var short: FakeBody = .init(&.{}, 1 << 20, "abc");
    var short_done: std.Io.Event = .unset;
    var short_ctx = short.context(arena_state.allocator(), 1 << 20, &short_done);
    try testing.expectError(error.ReadFailed, short_ctx.body());
    try testing.expect(arena_state.queryCapacity() < 256 << 10);
    try testing.expect(!short_done.isSet());

    // A whole body past the first part grows to its length.
    var whole_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer whole_arena.deinit();
    const payload = try whole_arena.allocator().alloc(u8, 200 << 10);
    for (payload, 0..) |*b, i| b.* = @truncate(i *% 7);
    var whole: FakeBody = .init(&.{}, payload.len, payload);
    var whole_done: std.Io.Event = .unset;
    var whole_ctx = whole.context(whole_arena.allocator(), 1 << 20, &whole_done);
    try testing.expectEqualSlices(u8, payload, try whole_ctx.body());
    try testing.expect(whole_done.isSet());
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
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&bodies}, .strict_errors = false });
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
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&bodies}, .strict_errors = false });
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

/// Its servers turn the strict error check off: `twice` fails the test
/// with an error of its own, which no error handler maps.
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

/// The body of a problem, with its violations.
const ProblemBody = struct {
    code: []const u8,
    errors: []const struct { code: []const u8, message: []const u8, field: ?[]const u8 = null } = &.{},
};

fn problemOf(res: *TestingBackend.Response) !ProblemBody {
    try testing.expectEqualStrings("application/problem+json", res.header("content-type") orelse "");
    return std.json.parseFromSliceLeaky(ProblemBody, res.arena.allocator(), res.body, .{ .ignore_unknown_fields = true });
}

/// A 422 whose violations are `expected`, as code and field.
fn expectViolations(res: *TestingBackend.Response, expected: []const [2][]const u8) !void {
    errdefer std.debug.print("status {d}, body {s}\n", .{ res.status, res.body });
    try testing.expectEqual(422, res.status);
    const problem = try problemOf(res);
    try testing.expectEqualStrings("validation_failed", problem.code);
    try testing.expectEqual(expected.len, problem.errors.len);
    for (expected, problem.errors) |want, got| {
        try testing.expectEqualStrings(want[0], got.code);
        try testing.expectEqualStrings(want[1], got.field orelse "(root)");
    }
}

fn get(b: *TestingBackend, target: []const u8, fields: []const [2][]const u8) !TestingBackend.Response {
    return b.request(testing.io, .{ .method = .GET, .target = target, .headers = fields });
}

fn post(b: *TestingBackend, target: []const u8, content_type: ?[]const u8, payload: []const u8) !TestingBackend.Response {
    const with_type: []const [2][]const u8 = &.{.{ "content-type", content_type orelse "" }};
    return b.request(testing.io, .{ .method = .POST, .target = target, .headers = if (content_type != null) with_type else &.{}, .body = payload });
}

const SearchQuery = struct {
    q: []const u8,
    per_page: u32 = 20,
    tags: []const []const u8 = &.{},

    pub const field_rules = .{
        .q = .{ v.trim, v.toLower, v.notBlank },
        .per_page = .{ v.rename("perPage"), v.range(1, 100) },
        .tags = v.transformWith(splitComma),
    };
};

/// "a,b" is "a" and "b"; more than three tags is the transform's own error.
fn splitComma(arena: std.mem.Allocator, value: []const []const u8) error{ TooManyTags, OutOfMemory }![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (value) |item| {
        var it = std.mem.tokenizeScalar(u8, item, ',');
        while (it.next()) |part| try parts.append(arena, part);
    }
    if (parts.items.len > 3) return error.TooManyTags;
    return parts.items;
}

const TodoPath = struct {
    user_id: u64,
    id: u32,

    pub const field_rules = .{ .user_id = .{ v.rename("userId"), v.positive } };
};

const SignUp = struct {
    email: []const u8,
    display_name: []const u8,

    pub const field_rules = .{
        .email = .{ v.trim, v.toLower, v.email },
        .display_name = .{ v.rename("displayName"), v.trim, v.notBlank },
    };
};

/// Unknown fields ignored, written as the design writes it.
const LooseSignUp = struct {
    email: []const u8,
    pub const unknown_fields = .ignore;
};

/// The same, typed.
const TypedSignUp = struct {
    email: []const u8,
    pub const unknown_fields: dto.UnknownFields = .ignore;
};

/// A query that refuses unknown parameters.
const StrictQuery = struct {
    page: u32 = 1,
    pub const unknown_fields = .reject;
};

const KeyHeaders = struct {
    idempotency_key: ?[]const u8 = null,
    x_tag: []const []const u8 = &.{},

    pub const field_rules = .{ .idempotency_key = .{ v.trim, v.maxLength(8) } };
};

const Prefs = struct {
    session: []const u8,
    theme: ?[]const u8 = null,

    pub const field_rules = .{ .session = v.rename("sid") };
};

const DayRange = struct {
    from_day: u32,
    to_day: u32,

    pub const field_rules = .{ .from_day = v.rename("from"), .to_day = v.rename("to") };

    pub fn validateSelf(self: *const DayRange) ?v.Violation {
        if (self.to_day < self.from_day) return v.fail(DayRange, .to_day, "range.to_before_from", "must not be before from");
        return null;
    }
};

/// Its servers turn the strict error check off: the transform of
/// `search` returns `error.TooManyTags`, which no error handler maps.
const InputController = struct {
    /// The error `search` got from `ctx.query`.
    seen: ?anyerror = null,

    pub const http_routes = routes.routes(.{ .methods = .{
        .search = routes.get("/search", .{}),
        .todo = routes.get("/users/{userId}/todos/{id}", .{}),
        .orphan = routes.get("/orphan", .{}),
        .named = routes.get("/names/{name}", .{}),
        .signup = routes.post("/signup", .{}),
        .loose = routes.post("/loose", .{}),
        .typed = routes.post("/typed", .{}),
        .strict = routes.get("/strict", .{}),
        .keyed = routes.get("/headers", .{}),
        .prefs = routes.get("/cookies", .{}),
        .range = routes.get("/range", .{}),
    } });

    fn say(ctx: *Context, comptime fmt: []const u8, args: anytype) !void {
        try ctx.response.text(try std.fmt.allocPrint(ctx.allocator(), fmt, args));
    }

    pub fn search(self: *InputController, ctx: *Context) !void {
        const s = ctx.query(SearchQuery) catch |err| {
            self.seen = err;
            return err;
        };
        try say(ctx, "q={s} perPage={d} tags={s}", .{ s.q, s.per_page, try std.mem.join(ctx.allocator(), "|", s.tags) });
    }
    pub fn todo(_: *InputController, ctx: *Context) !void {
        const p = try ctx.path(TodoPath);
        try say(ctx, "user {d} todo {d}", .{ p.user_id, p.id });
    }
    /// A DTO of the path on a route without its parameters.
    pub fn orphan(_: *InputController, ctx: *Context) !void {
        _ = try ctx.path(TodoPath);
    }
    pub fn named(_: *InputController, ctx: *Context) !void {
        const p = try ctx.path(struct { name: []const u8 });
        const q = try ctx.query(struct { q: []const u8 });
        try say(ctx, "path={s} query={s}", .{ p.name, q.q });
    }
    pub fn signup(_: *InputController, ctx: *Context) !void {
        const f = try ctx.form(SignUp);
        try say(ctx, "{s} {s}", .{ f.email, f.display_name });
    }
    pub fn loose(_: *InputController, ctx: *Context) !void {
        try ctx.response.text((try ctx.form(LooseSignUp)).email);
    }
    pub fn typed(_: *InputController, ctx: *Context) !void {
        try ctx.response.text((try ctx.form(TypedSignUp)).email);
    }
    pub fn strict(_: *InputController, ctx: *Context) !void {
        try say(ctx, "page {d}", .{(try ctx.query(StrictQuery)).page});
    }
    pub fn keyed(_: *InputController, ctx: *Context) !void {
        const h = try ctx.headers(KeyHeaders);
        try say(ctx, "key={s} tags={s}", .{ h.idempotency_key orelse "-", try std.mem.join(ctx.allocator(), "|", h.x_tag) });
    }
    pub fn prefs(_: *InputController, ctx: *Context) !void {
        const c = try ctx.cookies(Prefs);
        try say(ctx, "sid={s} theme={s}", .{ c.session, c.theme orelse "-" });
    }
    pub fn range(_: *InputController, ctx: *Context) !void {
        const r = try ctx.query(DayRange);
        try say(ctx, "{d}..{d}", .{ r.from_day, r.to_day });
    }
};

test "query: max_query_params plus one is 400" {
    const test_io = testing.io;
    var input: InputController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&input}, .strict_errors = false });
    defer server.deinit(test_io);
    try server.start(test_io);

    // The default, 100: 99 unknown parameters and q pass, one more is 400.
    var target: std.ArrayList(u8) = .empty;
    defer target.deinit(testing.allocator);
    try target.appendSlice(testing.allocator, "/search?q=milk");
    for (0..99) |i| try target.print(testing.allocator, "&x{d}=1", .{i});
    var at_limit = try get(&b, target.items, &.{});
    defer at_limit.deinit();
    try testing.expectEqual(200, at_limit.status);
    try target.appendSlice(testing.allocator, "&one=more");
    var over = try get(&b, target.items, &.{});
    defer over.deinit();
    try testing.expectEqual(400, over.status);
    try testing.expectEqualStrings("invalid_request", (try problemOf(&over)).code);
}

test "query: bad percent-encoding and invalid UTF-8 are 400" {
    const test_io = testing.io;
    var input: InputController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&input}, .strict_errors = false });
    defer server.deinit(test_io);
    try server.start(test_io);
    // In an unknown parameter too: the query is taken apart as a whole.
    for ([_][]const u8{ "/search?q=%zz", "/search?q=%4", "/search?q=%FF", "/search?q=milk&utm=%C3", "/search?q=milk&%ED%A0%80=1" }) |target| {
        var res = try get(&b, target, &.{});
        defer res.deinit();
        testing.expectEqual(400, res.status) catch |err| {
            std.debug.print("{s}\n", .{target});
            return err;
        };
    }
    var fine = try get(&b, "/search?q=caf%C3%A9", &.{});
    defer fine.deinit();
    try testing.expectEqualStrings("q=café perPage=20 tags=", fine.body);
}

test "query: + is a space, in the path it is not" {
    const test_io = testing.io;
    var input: InputController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&input}, .strict_errors = false });
    defer server.deinit(test_io);
    try server.start(test_io);
    var plus = try get(&b, "/names/a+b?q=a+b", &.{});
    defer plus.deinit();
    try testing.expectEqualStrings("path=a+b query=a b", plus.body);
    var escaped = try get(&b, "/names/a%20b%2B?q=a%20b%2B", &.{});
    defer escaped.deinit();
    try testing.expectEqualStrings("path=a b+ query=a b+", escaped.body);
}

test "query: 150 unknown parameters are 422 with the first 100 violations" {
    const test_io = testing.io;
    var input: InputController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&input}, .strict_errors = false, .max_query_params = 200 });
    defer server.deinit(test_io);
    try server.start(test_io);
    var target: std.ArrayList(u8) = .empty;
    defer target.deinit(testing.allocator);
    try target.appendSlice(testing.allocator, "/strict?page=1");
    for (0..150) |i| try target.print(testing.allocator, "&x{d}=1", .{i});
    var res = try get(&b, target.items, &.{});
    defer res.deinit();
    try testing.expectEqual(422, res.status);
    const problem = try problemOf(&res);
    try testing.expectEqual(v.max_report_violations, problem.errors.len);
    try testing.expectEqualStrings("http.unknown_field", problem.errors[0].code);
    try testing.expectEqualStrings("x0", problem.errors[0].field orelse "");
    try testing.expectEqualStrings("x99", problem.errors[99].field orelse "");
}

test "form: urlencoded only; unknown fields rejected unless the DTO ignores them" {
    const test_io = testing.io;
    const form_type = "application/x-www-form-urlencoded";
    var input: InputController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    {
        var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&input}, .strict_errors = false });
        defer server.deinit(test_io);
        try server.start(test_io);
        var ok = try post(&b, "/signup", form_type, "email=+Ann%40Example.COM+&displayName=Ann");
        defer ok.deinit();
        try testing.expectEqual(200, ok.status);
        try testing.expectEqualStrings("ann@example.com Ann", ok.body);
        var with_charset = try post(&b, "/signup", "Application/X-WWW-Form-Urlencoded; charset=UTF-8", "email=a@b.example&displayName=A");
        defer with_charset.deinit();
        try testing.expectEqual(200, with_charset.status);
        // Another type, or none: 415.
        for ([_]?[]const u8{ "application/json", "multipart/form-data; boundary=x", null }) |content_type| {
            var res = try post(&b, "/signup", content_type, "email=a@b.example&displayName=A");
            defer res.deinit();
            try testing.expectEqual(415, res.status);
            try testing.expectEqualStrings("unsupported_media_type", (try problemOf(&res)).code);
        }
        // Unknown fields of a body are refused; the rules run after.
        var extra = try post(&b, "/signup", form_type, "email=a@b.example&displayName=A&role=admin&role=root");
        defer extra.deinit();
        try expectViolations(&extra, &.{.{ "http.unknown_field", "role" }});
        var bad = try post(&b, "/signup", form_type, "email=nobody&displayName=+");
        defer bad.deinit();
        try expectViolations(&bad, &.{ .{ "validation.email", "email" }, .{ "validation.not_blank", "displayName" } });
        var loose = try post(&b, "/loose", form_type, "email=a@b.example&role=admin");
        defer loose.deinit();
        try testing.expectEqualStrings("a@b.example", loose.body);
        var broken = try post(&b, "/signup", form_type, "email=%E0");
        defer broken.deinit();
        try testing.expectEqual(400, broken.status);
    }
    {
        // The server's policies: bodies ignore, queries refuse.
        var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&input}, .strict_errors = false, .unknown_fields = .{ .body = .ignore, .query = .reject } });
        defer server.deinit(test_io);
        try server.start(test_io);
        var extra = try post(&b, "/signup", form_type, "email=a@b.example&displayName=A&role=admin");
        defer extra.deinit();
        try testing.expectEqual(200, extra.status);
        var utm = try get(&b, "/search?q=milk&utm=x", &.{});
        defer utm.deinit();
        try expectViolations(&utm, &.{.{ "http.unknown_field", "utm" }});
    }
}

test "form: a DTO's unknown_fields works untyped and typed" {
    try testing.expectEqual(.ignore, strings.unknownPolicy(LooseSignUp, .reject));
    try testing.expectEqual(.ignore, strings.unknownPolicy(TypedSignUp, .reject));
    try testing.expectEqual(.reject, strings.unknownPolicy(StrictQuery, .ignore));
    try testing.expectEqual(.reject, strings.unknownPolicy(SignUp, .reject));
    try testing.expectEqual(.ignore, strings.unknownPolicy(SearchQuery, .ignore));

    const test_io = testing.io;
    var input: InputController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    // The DTO's word wins over the server's, both ways.
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&input}, .strict_errors = false, .unknown_fields = .{ .body = .reject, .query = .ignore } });
    defer server.deinit(test_io);
    try server.start(test_io);
    for ([_][]const u8{ "/loose", "/typed" }) |target| {
        var res = try post(&b, target, "application/x-www-form-urlencoded", "email=a@b.example&role=admin");
        defer res.deinit();
        try testing.expectEqual(200, res.status);
        try testing.expectEqualStrings("a@b.example", res.body);
    }
    var strict_query = try get(&b, "/strict?page=2&utm=x", &.{});
    defer strict_query.deinit();
    try expectViolations(&strict_query, &.{.{ "http.unknown_field", "utm" }});
    var plain = try get(&b, "/strict?page=2", &.{});
    defer plain.deinit();
    try testing.expectEqualStrings("page 2", plain.body);
}

test "path: parameters fill fields by outside names" {
    const test_io = testing.io;
    var input: InputController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .prefix = "/api", .controllers = .{&input}, .strict_errors = false });
    defer server.deinit(test_io);
    try server.start(test_io);
    var ok = try get(&b, "/api/users/7/todos/3", &.{});
    defer ok.deinit();
    try testing.expectEqualStrings("user 7 todo 3", ok.body);
    var not_number = try get(&b, "/api/users/x/todos/99999999999", &.{});
    defer not_number.deinit();
    try expectViolations(&not_number, &.{ .{ "http.invalid_type", "userId" }, .{ "http.invalid_type", "id" } });
    var zero = try get(&b, "/api/users/0/todos/3", &.{});
    defer zero.deinit();
    try expectViolations(&zero, &.{.{ "validation.positive", "userId" }});
    // A field that the route's pattern does not name is missing.
    var orphan = try get(&b, "/api/orphan", &.{});
    defer orphan.deinit();
    try expectViolations(&orphan, &.{ .{ "http.missing_field", "userId" }, .{ "http.missing_field", "id" } });
}

test "headers: any case; repeats fill a slice" {
    const test_io = testing.io;
    var input: InputController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&input}, .strict_errors = false });
    defer server.deinit(test_io);
    try server.start(test_io);
    var ok = try get(&b, "/headers", &.{ .{ "IDEMPOTENCY-KEY", "  k-1 " }, .{ "x-tag", "a" }, .{ "Accept", "*/*" }, .{ "X-Tag", "b, c" } });
    defer ok.deinit();
    try testing.expectEqualStrings("key=k-1 tags=a|b, c", ok.body);
    var none = try get(&b, "/headers", &.{});
    defer none.deinit();
    try testing.expectEqualStrings("key=- tags=", none.body);
    // A single header twice; a rule names the header, not the field.
    var twice = try get(&b, "/headers", &.{ .{ "idempotency-key", "a" }, .{ "Idempotency-Key", "b" } });
    defer twice.deinit();
    try expectViolations(&twice, &.{.{ "http.invalid_type", "Idempotency-Key" }});
    var long = try get(&b, "/headers", &.{.{ "idempotency-key", "123456789" }});
    defer long.deinit();
    try expectViolations(&long, &.{.{ "validation.max_length", "Idempotency-Key" }});
    var not_utf8 = try get(&b, "/headers", &.{.{ "idempotency-key", "\xff" }});
    defer not_utf8.deinit();
    try testing.expectEqual(400, not_utf8.status);
}

test "cookies: outside names; the first of two equal names wins" {
    const test_io = testing.io;
    var input: InputController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&input}, .strict_errors = false });
    defer server.deinit(test_io);
    try server.start(test_io);
    var ok = try get(&b, "/cookies", &.{ .{ "Cookie", "sid=first; theme=\"dark\"; session=zig-name" }, .{ "cookie", "sid=second" } });
    defer ok.deinit();
    try testing.expectEqualStrings("sid=first theme=dark", ok.body);
    var missing = try get(&b, "/cookies", &.{.{ "Cookie", "session=zig-name; theme=light" }});
    defer missing.deinit();
    try expectViolations(&missing, &.{.{ "http.missing_field", "sid" }});
}

test "transforms run after mapping and before rules" {
    const test_io = testing.io;
    var input: InputController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&input}, .strict_errors = false });
    defer server.deinit(test_io);
    try server.start(test_io);
    var milk = try get(&b, "/search?q=++Milk+&tags=home,shop", &.{});
    defer milk.deinit();
    try testing.expectEqualStrings("q=milk perPage=20 tags=home|shop", milk.body);
    // notBlank sees the trimmed value.
    var blank = try get(&b, "/search?q=+++", &.{});
    defer blank.deinit();
    try expectViolations(&blank, &.{.{ "validation.not_blank", "q" }});
    // A value that does not map: no transform and no rule runs.
    var not_mapped = try get(&b, "/search?q=+++&perPage=x", &.{});
    defer not_mapped.deinit();
    try expectViolations(&not_mapped, &.{.{ "http.invalid_type", "perPage" }});
    // The rules: every violation at once.
    var both = try get(&b, "/search?q=+&perPage=0", &.{});
    defer both.deinit();
    try expectViolations(&both, &.{ .{ "validation.not_blank", "q" }, .{ "validation.range", "perPage" } });
}

test "a custom transform's error reaches the caller as it is" {
    // The error of the transform is in the error set of the call.
    try testing.expect(comptime hasError(InputError(SearchQuery, .query), "TooManyTags"));
    try testing.expect(comptime hasError(InputError(SearchQuery, .query), "ValidationFailed"));
    const test_io = testing.io;
    var input: InputController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&input}, .strict_errors = false });
    defer server.deinit(test_io);
    try server.start(test_io);
    const level = testing.log_level;
    testing.log_level = .err; // the 500 is logged as a warning
    defer testing.log_level = level;
    var res = try get(&b, "/search?q=milk&tags=a,b&tags=c,d", &.{});
    defer res.deinit();
    try testing.expectEqual(@as(?anyerror, error.TooManyTags), input.seen);
    try testing.expectEqual(500, res.status);
    try testing.expectEqual(0, (try problemOf(&res)).errors.len);
}

test "validateSelf violations use outside names" {
    const test_io = testing.io;
    var input: InputController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&input}, .strict_errors = false });
    defer server.deinit(test_io);
    try server.start(test_io);
    var ok = try get(&b, "/range?from=3&to=5", &.{});
    defer ok.deinit();
    try testing.expectEqualStrings("3..5", ok.body);
    var res = try get(&b, "/range?from=5&to=3", &.{});
    defer res.deinit();
    try expectViolations(&res, &.{.{ "range.to_before_from", "to" }});
    try testing.expectEqualStrings("must not be before from", (try problemOf(&res)).errors[0].message);
}

fn hasError(comptime E: type, comptime name: []const u8) bool {
    for (@typeInfo(E).error_set.error_names.?) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

test "the checkAll report is freed" {
    const test_io = testing.io;
    // The server's allocator, counted: the reports come from it.
    var counted: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var input: InputController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(counted.allocator(), .{ .backend = b.backend(), .controllers = .{&input}, .strict_errors = false });
    defer server.deinit(test_io);
    try server.start(test_io);
    const live = counted.allocations - counted.deallocations;
    var reports_taken = false;
    for ([_][]const u8{ "/search?q=+", "/search?q=+&perPage=0", "/range?from=5&to=3", "/search?q=milk" }) |target| {
        const before = counted.allocations;
        var res = try get(&b, target, &.{});
        defer res.deinit();
        if (counted.allocations > before) reports_taken = true;
        try testing.expectEqual(live, counted.allocations - counted.deallocations);
    }
    try testing.expect(reports_taken);
    // A request without a violation takes nothing from the server.
    const before = counted.allocations;
    var fine = try get(&b, "/search?q=milk", &.{});
    defer fine.deinit();
    try testing.expectEqual(before, counted.allocations);
}

const CreateTodo = struct {
    title: []const u8,
    user_name: []const u8,
    tags: []const []const u8 = &.{},

    pub const field_rules = .{
        .title = .{ v.trim, v.notBlank, v.maxLength(200) },
        .user_name = .{ v.rename("userName"), v.trim },
    };
};

/// The response: renamed, and transformed on the way out.
const TodoView = struct {
    title: []const u8,
    user_name: []const u8,

    pub const field_rules = .{ .user_name = .{ v.rename("userName"), v.toUpper } };
};

/// A response whose transform of its own fails.
const Tagged = struct {
    tags: []const []const u8,
    pub const field_rules = .{ .tags = v.transformWith(refuseNoTags) };
};

fn refuseNoTags(_: std.mem.Allocator, tags: []const []const u8) error{NoTags}![]const []const u8 {
    if (tags.len == 0) return error.NoTags;
    return tags;
}

/// Its servers turn the strict error check off: the transform of the
/// value of `untagged` returns `error.NoTags`, which no error handler maps.
const JsonController = struct {
    pub const http_routes = routes.routes(.{ .methods = .{
        .create = routes.post("/todos", .{}),
        .twice = routes.post("/twice", .{}),
        .untagged = routes.get("/untagged", .{}),
    } });

    pub fn create(_: *JsonController, ctx: *Context) !dto.Json(TodoView) {
        const todo = try ctx.json(CreateTodo);
        return .{ .value = .{ .title = todo.title, .user_name = todo.user_name }, .status = 201 };
    }
    /// Two calls: the body read once, its bytes parsed twice.
    pub fn twice(_: *JsonController, ctx: *Context) !void {
        const first = try ctx.json(CreateTodo);
        const second = try ctx.json(CreateTodo);
        try ctx.response.text(try std.fmt.allocPrint(ctx.allocator(), "{s}|{s}", .{ first.title, second.title }));
    }
    pub fn untagged(_: *JsonController, _: *Context) !dto.Json(Tagged) {
        return .{ .value = .{ .tags = &.{} } };
    }
};

/// Starts `server` in place: once started, the backend points at it.
fn startJson(server: *Server, b: *TestingBackend, controller: *JsonController, max_depth: u16) !void {
    server.* = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{controller}, .json = .{ .max_depth = max_depth }, .strict_errors = false });
    errdefer server.deinit(testing.io);
    try server.start(testing.io);
}

test "json: needs application/json or +json, else 415" {
    var todos: JsonController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server: Server = undefined;
    try startJson(&server, &b, &todos, 64);
    defer server.deinit(testing.io);
    const payload = "{\"title\":\"Buy milk\",\"userName\":\"ann\"}";
    for ([_][]const u8{ "application/json", "Application/JSON; charset=utf-8", "application/merge-patch+json", "application/vnd.api+json ; q=1" }) |content_type| {
        var res = try post(&b, "/todos", content_type, payload);
        defer res.deinit();
        testing.expectEqual(201, res.status) catch |err| {
            std.debug.print("{s}: {s}\n", .{ content_type, res.body });
            return err;
        };
    }
    for ([_]?[]const u8{ "text/plain", "application/x-www-form-urlencoded", "text/json", "application/jsonx", "application/+json", "/x+json", "application/x y+json", null }) |content_type| {
        var res = try post(&b, "/todos", content_type, payload);
        defer res.deinit();
        testing.expectEqual(415, res.status) catch |err| {
            std.debug.print("{?s}\n", .{content_type});
            return err;
        };
        try testing.expectEqualStrings("unsupported_media_type", (try problemOf(&res)).code);
    }
}

test "json: transforms then rules" {
    var todos: JsonController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server: Server = undefined;
    try startJson(&server, &b, &todos, 64);
    defer server.deinit(testing.io);

    var ok = try post(&b, "/todos", "application/json", "{\"title\":\"  Buy milk  \",\"userName\":\" ann \"}");
    defer ok.deinit();
    try testing.expectEqual(201, ok.status);
    try testing.expectEqualStrings("application/json", ok.header("content-type").?);
    try testing.expectEqualStrings("{\"title\":\"Buy milk\",\"userName\":\"ANN\"}", ok.body);
    // notBlank sees the trimmed title; maxLength too.
    var blank = try post(&b, "/todos", "application/json", "{\"title\":\"   \",\"userName\":\"ann\"}");
    defer blank.deinit();
    try expectViolations(&blank, &.{.{ "validation.not_blank", "title" }});
    const long = try std.fmt.allocPrint(testing.allocator, "{{\"title\":\" {s} \",\"userName\":\"ann\"}}", .{&@as([201]u8, @splat('a'))});
    defer testing.allocator.free(long);
    var too_long = try post(&b, "/todos", "application/json", long);
    defer too_long.deinit();
    try expectViolations(&too_long, &.{.{ "validation.max_length", "title" }});
    // A second ctx.json parses the same bytes again.
    var twice = try post(&b, "/twice", "application/json", "{\"title\":\" a \",\"userName\":\"b\"}");
    defer twice.deinit();
    try testing.expectEqualStrings("a|a", twice.body);
}

test "json: outside names in and out" {
    var todos: JsonController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server: Server = undefined;
    try startJson(&server, &b, &todos, 64);
    defer server.deinit(testing.io);

    var zig_name = try post(&b, "/todos", "application/json", "{\"title\":\"x\",\"user_name\":\"Ann\"}");
    defer zig_name.deinit();
    try expectViolations(&zig_name, &.{ .{ "http.unknown_field", "user_name" }, .{ "http.missing_field", "userName" } });
    var all = try post(&b, "/todos", "application/json", "{\"titel\":1,\"userName\":5,\"tags\":[\"a\",2]}");
    defer all.deinit();
    try expectViolations(&all, &.{
        .{ "http.unknown_field", "titel" },
        .{ "http.invalid_type", "userName" },
        .{ "http.invalid_type", "tags[1]" },
        .{ "http.missing_field", "title" },
    });
    try testing.expectEqualStrings("must be a string", (try problemOf(&all)).errors[1].message);
    // A response's transform of its own fails as the handler would.
    const level = testing.log_level;
    testing.log_level = .err; // the 500 is logged as a warning
    defer testing.log_level = level;
    var untagged = try get(&b, "/untagged", &.{});
    defer untagged.deinit();
    try testing.expectEqual(500, untagged.status);
    try testing.expectEqualStrings("internal", (try problemOf(&untagged)).code);
}

test "json: broken JSON, a repeated key and nesting past .json.max_depth are 400" {
    var todos: JsonController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server: Server = undefined;
    try startJson(&server, &b, &todos, 2);
    defer server.deinit(testing.io);
    for ([_][]const u8{ "{\"title\":", "", "{\"title\":\"a\",\"title\":\"b\",\"userName\":\"c\"}", "{\"title\":\"a\",\"userName\":\"c\",\"tags\":[[]]}", "{\"title\":\"\xff\",\"userName\":\"c\"}" }) |payload| {
        var res = try post(&b, "/todos", "application/json", payload);
        defer res.deinit();
        testing.expectEqual(400, res.status) catch |err| {
            std.debug.print("{s}\n", .{payload});
            return err;
        };
        try testing.expectEqualStrings("invalid_request", (try problemOf(&res)).code);
    }
    // Two levels pass.
    var two = try post(&b, "/todos", "application/json", "{\"title\":\"a\",\"userName\":\"c\",\"tags\":[\"x\"]}");
    defer two.deinit();
    try testing.expectEqual(201, two.status);
}
