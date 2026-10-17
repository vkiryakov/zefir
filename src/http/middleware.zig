//! Middleware (design section 9): the mechanism, and not one middleware of
//! its own. An application writes its middleware and lists them in
//! `.middleware`: of the server (global), of `http.routes` (a controller)
//! and of a route (a method). Every phase runs in that order, global, then
//! controller, then method, each list from left to right; after phases too.
//!
//! An element of a `.middleware` list is one of:
//! - a function `fn (ctx: *http.Context) !http.MiddlewareResult`: a `run`
//!   phase alone;
//! - a type with any of the static phases `pub fn run(ctx: *http.Context)
//!   !http.MiddlewareResult`, `pub fn onResponse(ctx: *http.Context) !void`
//!   and `pub fn onFinish(ctx: *http.Context, outcome: http.Outcome) !void`,
//!   and optionally `pub const name` for messages and the log, such as an
//!   application's `auth.requirePermission("todos")`; `http.onResponse(f)`
//!   and `http.onFinish(f)` make such a type of a function;
//! - in the server's list: a pointer to an object of the application with
//!   any of `run(self, ctx)`, `onResponse(self, ctx)` and `onFinish(self,
//!   ctx, outcome)`, borrowed: `&access_log`;
//! - in a controller's list and a route's: `.name`, a field of the
//!   controller that points to such an object, read on every request;
//! - a set: a tuple of elements, sets among them, unfolded in place.
//!
//! ```zig
//! .middleware = .{ mw.requestId, &access_log, http.onResponse(mw.securityHeaders), &cors, &token_auth },
//! // a controller: an application's set and a type with its permission
//! .middleware = .{ mw.protected, auth.requirePermission("todos") },
//! // a method: a field of the controller
//! .delete = http.delete("/{id}", .{ .middleware = .{ auth.requirePermission("todos:delete"), .audit } }),
//! ```
//!
//! The phases of a request:
//! - `run`, before the handler: `.next` goes on, `.handled` ends the chain
//!   with the response it wrote, a status or a body (with neither, it is
//!   `error.HandledWithoutResponse`, 500). An error goes to the error
//!   handler. The server's elements run before the route is applied, so
//!   that a preflight and an unknown path reach them: `ctx.route()` is
//!   null there.
//! - `onResponse`, right before the head of the response goes out, for the
//!   response of the handler and for the answer to an error: its status and
//!   fields can still change. An error is logged, and the response goes as
//!   it is.
//! - `onFinish`, once, when the request has ended: answered, cut or
//!   canceled. It runs on a task of its own with a context of its own: the
//!   request's trace, no token of the request, and a deadline
//!   `.finish_timeout` away, after which what is left of it is canceled. An
//!   error is logged, and the next one runs.
//!
//! An element gets its after phases (`onResponse`, `onFinish`) when its
//! `run` returned, `.next` or `.handled`, or, without a `run`, when every
//! `run` before it returned `.next`. A `run` that fails gets none, so it
//! cleans up what it took itself.
//!
//! One object serves every request at once, and zio may run them on
//! several threads: its fields that change are atomics or behind a
//! `std.Io.Mutex`.
const std = @import("std");
const Context = @import("Context.zig");
const plan = @import("plan.zig");

const log = std.log.scoped(.http);

/// What a `run` phase answers: `.next` goes on with the chain, `.handled`
/// ends it with the response the phase wrote.
pub const MiddlewareResult = enum { next, handled };

/// How a request ended, for `onFinish`.
pub const Outcome = struct {
    /// The status that went out; 0 when no response did.
    status: u16,
    /// From the parsed head of the request to its end.
    duration: std.Io.Duration,
    /// No whole response went out: the client left, the server canceled
    /// the request, or the response was cut.
    aborted: bool,
    /// The error the request ended with: of its handler, of a middleware,
    /// of the framework (`RouteNotFound`, `RequestTimeout`, ...), or
    /// `Canceled` when the client left or the server stopped; null when it
    /// ended without one.
    err: ?anyerror,
};

/// A function as the `onResponse` phase of an element:
/// `http.onResponse(securityHeaders)`, where `f` is
/// `fn (ctx: *http.Context) !void`. The element is named
/// `onResponse(securityHeaders)`.
pub fn onResponse(comptime f: anytype) type {
    comptime expectWrapped(f, "http.onResponse", &.{*Context}, "fn (ctx: *http.Context) !void");
    return struct {
        pub const name = "onResponse(" ++ fnName(f) ++ ")";
        pub fn onResponse(ctx: *Context) ErrorSetOf(@TypeOf(f))!void {
            return f(ctx);
        }
    };
}

/// A function as the `onFinish` phase of an element:
/// `http.onFinish(countRequest)`, where `f` is
/// `fn (ctx: *http.Context, outcome: http.Outcome) !void`. The element is
/// named `onFinish(countRequest)`.
pub fn onFinish(comptime f: anytype) type {
    comptime expectWrapped(f, "http.onFinish", &.{ *Context, Outcome }, "fn (ctx: *http.Context, outcome: http.Outcome) !void");
    return struct {
        pub const name = "onFinish(" ++ fnName(f) ++ ")";
        pub fn onFinish(ctx: *Context, outcome: Outcome) ErrorSetOf(@TypeOf(f))!void {
            return f(ctx, outcome);
        }
    };
}

/// A function element as a type: its `run`, under its name.
fn FnLink(comptime f: anytype) type {
    return struct {
        pub const name = fnName(f);
        pub fn run(ctx: *Context) ErrorSetOf(@TypeOf(f))!MiddlewareResult {
            return f(ctx);
        }
    };
}

// ---------- At compile time ----------

/// The list an element sits in.
pub const Level = enum { global, controller, method };

/// Where a list sits: its level, and for a controller's list and a
/// method's, the controller and the method.
pub const Place = struct {
    level: Level,
    Controller: type = void,
    method: []const u8 = "",
};

/// What the phases of an element run on.
pub const Binding = enum {
    /// A function or a type: nothing.
    static,
    /// An object of the application that the server's list points to.
    pointer,
    /// An object that a field of the controller points to, read on every
    /// request.
    field,
};

/// One element of a chain, at compile time.
pub const Elem = struct {
    /// For messages, the log and `http.testing.chainNames`: requestId,
    /// AccessLog, requirePermission(todos), .audit (Audit).
    name: []const u8,
    /// The type whose phases run: a type element, the type made of a
    /// function, or the type of the object. The strict error check reads
    /// the errors of each one's `run` once.
    Impl: type,
    binding: Binding,
    /// `.pointer`: the place of the pointer in the server's `.middleware`,
    /// through the sets around it.
    path: []const usize = &.{},
    /// `.field`: the controller and its field.
    Controller: type = void,
    field: []const u8 = "",
};

/// The elements of the list of type `List` (a tuple, the type of a
/// `.middleware`) at `place`, sets unfolded in place, in order. `path` leads
/// to the list from the `.middleware` of its level. Values known at compile
/// time (functions, types, `.field`) are read from the tuple's type; a
/// pointer to an object is only checked here, the server takes it at run
/// time.
pub fn unfold(comptime List: type, comptime place: Place, comptime path: []const usize) []const Elem {
    const info = @typeInfo(List);
    if (info != .@"struct" or !info.@"struct".is_tuple)
        fail(place, path, "it is a tuple of middleware, such as .{ mw.requestId, &access_log }; got '" ++ @typeName(List) ++ "'");
    var list: []const Elem = &.{};
    for (info.@"struct".field_types, info.@"struct".field_attrs, 0..) |Item, attrs, i| {
        const here = path ++ [_]usize{i};
        if (isTuple(Item)) {
            list = list ++ unfold(Item, place, here);
            continue;
        }
        const value = if (attrs.@"comptime") attrs.defaultValue(Item).? else {};
        list = list ++ [_]Elem{describe(Item, value, place, here)};
    }
    return list;
}

fn isTuple(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple;
}

/// One element of type `Item` at `place`; `value` is the element itself
/// when it is known at compile time, else `{}`.
fn describe(comptime Item: type, comptime value: anytype, comptime place: Place, comptime path: []const usize) Elem {
    switch (@typeInfo(Item)) {
        .@"fn" => {
            if (!fits(Item, &.{*Context}, MiddlewareResult))
                fail(place, path, fnName(value) ++ " is " ++ plan.fnForm(Item) ++ "; write a function fn (ctx: *http.Context) !http.MiddlewareResult");
            const L = FnLink(value);
            return .{ .name = L.name, .Impl = L, .binding = .static };
        },
        .type => {
            const T: type = value;
            if (@typeInfo(T) != .@"struct")
                fail(place, path, "the type '" ++ @typeName(T) ++ "' is not middleware: a type is a struct with pub fn run, onResponse or onFinish");
            expectPhases(T, .static, place, path);
            return .{ .name = nameOf(T), .Impl = T, .binding = .static };
        },
        .enum_literal => {
            const field = @tagName(value);
            if (place.level == .global)
                fail(place, path, "." ++ field ++ " names a field of a controller; the server's middleware takes functions, types and pointers to objects");
            const C = place.Controller;
            const cname = plan.shortName(@typeName(C));
            if (!@hasField(C, field)) fail(place, path, "." ++ field ++ " is not a field of " ++ cname);
            const F = @FieldType(C, field);
            const pointer = @typeInfo(F) == .pointer and @typeInfo(F).pointer.size == .one and @typeInfo(@typeInfo(F).pointer.child) == .@"struct";
            if (!pointer)
                fail(place, path, "field '" ++ field ++ "' of " ++ cname ++ " is '" ++ @typeName(F) ++ "'; it must point to a middleware object");
            if (@typeInfo(F).pointer.attrs.@"const")
                fail(place, path, "field '" ++ field ++ "' of " ++ cname ++ " is '" ++ @typeName(F) ++ "'; the object must be mutable: *" ++ @typeName(@typeInfo(F).pointer.child));
            const T = @typeInfo(F).pointer.child;
            expectPhases(T, .object, place, path);
            return .{ .name = "." ++ field ++ " (" ++ plan.shortName(@typeName(T)) ++ ")", .Impl = T, .binding = .field, .Controller = C, .field = field };
        },
        .pointer => |p| {
            if (place.level != .global)
                fail(place, path, "a pointer to an object goes into the server's middleware; in a controller, make it a field and name it: .field");
            if (p.size != .one or @typeInfo(p.child) != .@"struct")
                fail(place, path, "'" ++ @typeName(Item) ++ "' is not a pointer to a middleware object");
            if (p.attrs.@"const")
                fail(place, path, "'" ++ @typeName(Item) ++ "': the object must be mutable, declared with var");
            expectPhases(p.child, .object, place, path);
            return .{ .name = plan.shortName(@typeName(p.child)), .Impl = p.child, .binding = .pointer, .path = path };
        },
        .@"struct" => fail(place, path, "'" ++ @typeName(Item) ++ "' is an object by value; pass a pointer to it: &object"),
        else => fail(place, path, "an element of type '" ++ @typeName(Item) ++ "' is not middleware; write a function fn (ctx: *http.Context) !http.MiddlewareResult, " ++
            "a type with pub fn run, a pointer to an object with run, onResponse or onFinish, http.onResponse(f), http.onFinish(f), a tuple of them, or in a controller .field"),
    }
}

/// The name of a type element: its `pub const name`, else its own.
fn nameOf(comptime T: type) []const u8 {
    if (!@hasDecl(T, "name")) return plan.shortName(@typeName(T));
    const N = @TypeOf(T.name);
    const string = N == []const u8 or (@typeInfo(N) == .pointer and @typeInfo(N).pointer.size == .one and
        @typeInfo(@typeInfo(N).pointer.child) == .array and @typeInfo(@typeInfo(N).pointer.child).array.child == u8);
    if (!string) @compileError("zefir.http: " ++ @typeName(T) ++ ".name is '" ++ @typeName(N) ++ "'; the name of a middleware is a string");
    return T.name;
}

/// Stops the build on a mistake of the list at `place`, at `path`.
fn fail(comptime place: Place, comptime path: []const usize, comptime what: []const u8) noreturn {
    var text: []const u8 = switch (place.level) {
        .global => "Server.init .middleware",
        .controller => plan.shortName(@typeName(place.Controller)) ++ ".http_routes.middleware",
        .method => plan.shortName(@typeName(place.Controller)) ++ ".http_routes.methods." ++ place.method ++ ".middleware",
    };
    for (path) |i| text = text ++ std.fmt.comptimePrint("[{d}]", .{i});
    @compileError("zefir.http: " ++ text ++ ": " ++ what);
}

const Form = enum { static, object };
const Phase = enum { run, onResponse, onFinish };

/// The phase as the application writes it.
fn phaseForm(comptime form: Form, comptime phase: Phase) []const u8 {
    const self = switch (form) {
        .static => "",
        .object => "self: *@This(), ",
    };
    return switch (phase) {
        .run => "pub fn run(" ++ self ++ "ctx: *http.Context) !http.MiddlewareResult",
        .onResponse => "pub fn onResponse(" ++ self ++ "ctx: *http.Context) !void",
        .onFinish => "pub fn onFinish(" ++ self ++ "ctx: *http.Context, outcome: http.Outcome) !void",
    };
}

/// At least one phase, each of its form.
fn expectPhases(comptime T: type, comptime form: Form, comptime place: Place, comptime path: []const usize) void {
    if (!@hasDecl(T, "run") and !@hasDecl(T, "onResponse") and !@hasDecl(T, "onFinish"))
        fail(place, path, @typeName(T) ++ " has none of " ++ phaseForm(form, .run) ++ ", " ++ phaseForm(form, .onResponse) ++ ", " ++ phaseForm(form, .onFinish));
    inline for (.{ Phase.run, Phase.onResponse, Phase.onFinish }) |phase| {
        if (@hasDecl(T, @tagName(phase))) {
            const F = @TypeOf(@field(T, @tagName(phase)));
            const params: []const type = if (phase == .onFinish) &.{ *Context, Outcome } else &.{*Context};
            const Payload = if (phase == .run) MiddlewareResult else void;
            const ok = switch (form) {
                .static => fits(F, params, Payload),
                .object => fits(F, withSelf(*T, params), Payload) or fits(F, withSelf(*const T, params), Payload),
            };
            if (!ok) fail(place, path, plan.typeName(T) ++ "." ++ @tagName(phase) ++ " is " ++ plan.fnForm(F) ++ "; write " ++ phaseForm(form, phase));
        }
    }
}

/// `params` after `Self`.
fn withSelf(comptime Self: type, comptime params: []const type) []const type {
    var list: [params.len + 1]type = undefined;
    list[0] = Self;
    for (params, list[1..]) |param, *slot| slot.* = param;
    const final = list;
    return &final;
}

/// Whether `F` is a function of `params` that returns `Payload` or an
/// error union of it.
fn fits(comptime F: type, comptime params: []const type, comptime Payload: type) bool {
    if (@typeInfo(F) != .@"fn") return false;
    const info = @typeInfo(F).@"fn";
    if (info.is_generic or info.param_types.len != params.len) return false;
    for (params, info.param_types) |want, got| {
        if (got.? != want) return false;
    }
    const R = info.return_type orelse return false;
    const P = if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.payload else R;
    return P == Payload;
}

fn expectWrapped(comptime f: anytype, comptime wrapper: []const u8, comptime params: []const type, comptime written: []const u8) void {
    const F = @TypeOf(f);
    if (!fits(F, params, void)) @compileError("zefir.http: " ++ wrapper ++ " takes " ++ written ++ "; got " ++ plan.fnForm(F));
}

/// The error set a function type returns; `error{}` without one.
pub fn ErrorSetOf(comptime F: type) type {
    const R = @typeInfo(F).@"fn".return_type.?;
    return if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.error_set else error{};
}

/// The name of a function as it was declared: `requestId`.
pub fn fnName(comptime f: anytype) []const u8 {
    const full = @typeName(NameOf(f));
    const start = (std.mem.find(u8, full, "(function '") orelse return "a function") + "(function '".len;
    const end = std.mem.findScalarLast(u8, full, '\'') orelse return "a function";
    return full[start..end];
}

/// A type whose name holds the name of `f`.
fn NameOf(comptime f: anytype) type {
    return struct {
        comptime {
            _ = f;
        }
    };
}

// ---------- At run time ----------

/// One element of a chain at run time: its phases, their types erased.
pub const Link = struct {
    /// The element's name, for the log.
    name: []const u8,
    /// What the phases run on: the application's object (`.pointer`), or
    /// the controller whose field points to it (`.field`); null for a
    /// function or a type. The server sets it.
    ptr: ?*anyopaque = null,
    run: ?*const fn (ptr: ?*anyopaque, ctx: *Context) anyerror!MiddlewareResult = null,
    on_response: ?*const fn (ptr: ?*anyopaque, ctx: *Context) anyerror!void = null,
    on_finish: ?*const fn (ptr: ?*anyopaque, ctx: *Context, outcome: Outcome) anyerror!void = null,
};

/// The link of `e`, its `ptr` left to the server.
pub fn linkOf(comptime e: Elem) Link {
    const T = e.Impl;
    const Phases = switch (e.binding) {
        .static => StaticPhases(T),
        .pointer => ObjectPhases(T, PointerSelf(T).of),
        .field => ObjectPhases(T, FieldSelf(e.Controller, e.field).of),
    };
    return .{
        .name = e.name,
        .run = if (@hasDecl(T, "run")) &Phases.run else null,
        .on_response = if (@hasDecl(T, "onResponse")) &Phases.onResponse else null,
        .on_finish = if (@hasDecl(T, "onFinish")) &Phases.onFinish else null,
    };
}

fn StaticPhases(comptime T: type) type {
    return struct {
        fn run(_: ?*anyopaque, ctx: *Context) anyerror!MiddlewareResult {
            return T.run(ctx);
        }
        fn onResponse(_: ?*anyopaque, ctx: *Context) anyerror!void {
            return T.onResponse(ctx);
        }
        fn onFinish(_: ?*anyopaque, ctx: *Context, outcome: Outcome) anyerror!void {
            return T.onFinish(ctx, outcome);
        }
    };
}

/// The phases of the object of type `T` that `selfOf` finds behind `ptr`.
fn ObjectPhases(comptime T: type, comptime selfOf: fn (ptr: ?*anyopaque) *T) type {
    return struct {
        fn run(ptr: ?*anyopaque, ctx: *Context) anyerror!MiddlewareResult {
            return T.run(selfOf(ptr), ctx);
        }
        fn onResponse(ptr: ?*anyopaque, ctx: *Context) anyerror!void {
            return T.onResponse(selfOf(ptr), ctx);
        }
        fn onFinish(ptr: ?*anyopaque, ctx: *Context, outcome: Outcome) anyerror!void {
            return T.onFinish(selfOf(ptr), ctx, outcome);
        }
    };
}

fn PointerSelf(comptime T: type) type {
    return struct {
        fn of(ptr: ?*anyopaque) *T {
            return @ptrCast(@alignCast(ptr.?));
        }
    };
}

/// The object the field `field` of the controller behind `ptr` points to
/// now.
fn FieldSelf(comptime C: type, comptime field: []const u8) type {
    return struct {
        fn of(ptr: ?*anyopaque) *@typeInfo(@FieldType(C, field)).pointer.child {
            const controller: *C = @ptrCast(@alignCast(ptr.?));
            return @field(controller, field);
        }
    };
}

/// The object of the server's list at `path`: `options.middleware[1]`, or
/// `[1][0]` inside a set.
pub fn objectAt(list: anytype, comptime path: []const usize) *anyopaque {
    if (path.len == 1) return list[path[0]];
    return objectAt(list[path[0]], path[1..]);
}

/// The links of a request and how far it got: the server's links, then the
/// route's once it is applied. The first `count` of them reached their
/// after phases.
pub const Reached = struct {
    global: []const Link = &.{},
    route: []const Link = &.{},
    count: usize = 0,

    fn at(r: *const Reached, i: usize) Link {
        return if (i < r.global.len) r.global[i] else r.route[i - r.global.len];
    }
};

/// Runs the `run` phases of `links`, which come right after the links the
/// request reached so far: true when one answered `.handled` with a
/// response written. An error of a `run` comes back as it is; that element
/// does not reach its after phases.
pub fn runPhases(ctx: *Context, links: []const Link) anyerror!bool {
    const reached = &ctx.internal.middleware;
    for (links) |link| {
        const run = link.run orelse {
            reached.count += 1;
            continue;
        };
        const result = try run(link.ptr, ctx);
        reached.count += 1;
        if (result == .next) continue;
        if (ctx.response.internal.written()) return true;
        log.warn("{s}.run returned .handled without a response, no status and no body; the response is 500 (request {s})", .{ link.name, ctx.requestId() });
        return error.HandledWithoutResponse;
    }
    return false;
}

/// The hook of the response before its head goes out: the `onResponse`
/// phases of the links the request reached, in order.
pub fn beforeHead(ctx: *Context) Context.Response.BeforeHead {
    return .{ .ptr = ctx, .call = onResponsePhases };
}

fn onResponsePhases(ptr: *anyopaque) void {
    const ctx: *Context = @ptrCast(@alignCast(ptr));
    const reached = &ctx.internal.middleware;
    for (0..reached.count) |i| {
        const link = reached.at(i);
        const phase = link.on_response orelse continue;
        phase(link.ptr, ctx) catch |err|
            log.warn("{s}.onResponse failed with error.{t}; the response goes as it is (request {s})", .{ link.name, err, ctx.requestId() });
    }
}

/// Whether a link the request reached has an `onFinish` phase.
pub fn finishes(ctx: *const Context) bool {
    const reached = &ctx.internal.middleware;
    for (0..reached.count) |i| {
        if (reached.at(i).on_finish != null) return true;
    }
    return false;
}

/// The `onFinish` phases of the links the request reached, in order, each
/// once. Once `over` is set, the time for them is up: those that have not
/// begun are left out.
pub fn onFinishPhases(ctx: *Context, outcome: Outcome, over: *const std.atomic.Value(bool)) void {
    const reached = &ctx.internal.middleware;
    for (0..reached.count) |i| {
        const link = reached.at(i);
        const phase = link.on_finish orelse continue;
        if (over.load(.acquire)) {
            log.warn("{s}.onFinish did not run: the .finish_timeout of the request had passed (request {s})", .{ link.name, ctx.requestId() });
            continue;
        }
        phase(link.ptr, ctx, outcome) catch |err|
            log.warn("{s}.onFinish failed with error.{t} (request {s})", .{ link.name, err, ctx.requestId() });
    }
}

// ---------- Tests ----------
//
// The middleware below are application code of the tests: zefir-http
// ships none.

const testing = std.testing;
const core = @import("core");
const Server = @import("Server.zig");
const TestingBackend = @import("testing/Backend.zig");
const routes = @import("routes.zig");
const chainNames = @import("testing.zig").chainNames;
const inFlight = @import("testing.zig").inFlight;

/// What the phases of the tests' middleware did, in order, as words.
const Journal = struct {
    words: [96][]const u8 = undefined,
    len: usize = 0,

    fn add(j: *Journal, word: []const u8) void {
        if (j.len == j.words.len) return;
        j.words[j.len] = word;
        j.len += 1;
    }

    fn expect(j: *const Journal, want: []const u8) !void {
        var buffer: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        for (j.words[0..j.len], 0..) |word, i| {
            if (i > 0) try w.writeByte(' ');
            try w.writeAll(word);
        }
        try testing.expectEqualStrings(want, w.buffered());
    }
};

/// The journal of the test that runs: the tests run one at a time, and the
/// phases of one request one after another.
var journal: Journal = .{};

fn first(_: *Context) !MiddlewareResult {
    journal.add("first.run");
    return .next;
}
fn second(_: *Context) !MiddlewareResult {
    journal.add("second.run");
    return .next;
}
fn third(_: *Context) !MiddlewareResult {
    journal.add("third.run");
    return .next;
}
fn stamp(ctx: *Context) !void {
    journal.add("stamp.onResponse");
    try ctx.response.setHeader("x-stamp", "1");
}
fn count(_: *Context, _: Outcome) !void {
    journal.add("count.onFinish");
}

/// A type with the three phases, static.
const Typed = struct {
    pub fn run(_: *Context) !MiddlewareResult {
        journal.add("Typed.run");
        return .next;
    }
    pub fn onResponse(_: *Context) !void {
        journal.add("Typed.onResponse");
    }
    pub fn onFinish(_: *Context, _: Outcome) !void {
        journal.add("Typed.onFinish");
    }
};

/// An object with the three phases; what its `run` and `onResponse` do is
/// set by each test.
const Step = struct {
    run_word: []const u8,
    response_word: []const u8,
    finish_word: []const u8,
    /// The field its `onResponse` sets.
    field: []const u8,
    does: enum { next, fail, handle, handle_empty } = .next,
    response_fails: bool = false,

    fn init(comptime label: []const u8) Step {
        return .{ .run_word = label ++ ".run", .response_word = label ++ ".onResponse", .finish_word = label ++ ".onFinish", .field = "x-" ++ label };
    }

    pub fn run(self: *Step, ctx: *Context) !MiddlewareResult {
        journal.add(self.run_word);
        switch (self.does) {
            .next => return .next,
            .fail => return error.Refused,
            .handle => {
                try ctx.response.status(202).text("handled");
                return .handled;
            },
            // A field alone is no response.
            .handle_empty => {
                try ctx.response.setHeader("x-only", "a field");
                return .handled;
            },
        }
    }
    pub fn onResponse(self: *Step, ctx: *Context) !void {
        journal.add(self.response_word);
        try ctx.response.setHeader(self.field, "1");
        if (self.response_fails) return error.Broken;
    }
    pub fn onFinish(self: *Step, _: *Context, _: Outcome) !void {
        journal.add(self.finish_word);
    }
};

/// A controller with middleware of its own and of its methods, sets
/// nested in both.
const OrderV1Controller = struct {
    ctl: *Step,
    audit: *Step,

    pub const http_routes = routes.routes(.{
        .prefix = "/v1/order",
        .middleware = .{ .{ .ctl, second }, onFinish(count) },
        .methods = .{
            .get = routes.get("/{id}", .{ .middleware = .{.{ .audit, .{third} }} }),
            .fail = routes.get("/{id}/fail", .{}),
        },
    });

    pub fn get(_: *OrderV1Controller, _: *Context) !void {
        journal.add("handler");
    }
    pub fn fail(_: *OrderV1Controller, _: *Context) !void {
        journal.add("handler");
        return error.TodoNotFound;
    }
};

/// A server of `OrderV1Controller` with middleware on its three levels.
/// Its errors are the tests' own: the strict error check is off.
const OrderFixture = struct {
    a: Step = .init("a"),
    ctl: Step = .init("ctl"),
    audit: Step = .init("audit"),
    controller: OrderV1Controller = undefined,
    backend: TestingBackend = undefined,
    server: Server = undefined,

    fn start(f: *OrderFixture) !void {
        journal = .{};
        f.controller = .{ .ctl = &f.ctl, .audit = &f.audit };
        f.backend = .init(testing.allocator);
        errdefer f.backend.deinit();
        f.server = try .init(testing.allocator, .{
            .backend = f.backend.backend(),
            .controllers = .{&f.controller},
            .middleware = .{ first, &f.a, .{ Typed, onResponse(stamp) } },
            .strict_errors = false,
        });
        f.server.start(testing.io) catch |err| {
            f.server.deinit(testing.io);
            return err;
        };
    }

    fn stop(f: *OrderFixture) void {
        f.server.deinit(testing.io);
        f.backend.deinit();
    }

    fn request(f: *OrderFixture, target: []const u8) !TestingBackend.Response {
        journal = .{};
        return f.backend.request(testing.io, .{ .method = .GET, .target = target });
    }
};

test "a set unfolds in place on every level, nested sets too" {
    var f: OrderFixture = .{};
    try f.start();
    defer f.stop();
    // At compile time: the server's elements, the controller's, the method's.
    const names = comptime chainNames(@TypeOf(.{
        .backend = f.backend.backend(),
        .controllers = .{&f.controller},
        .middleware = .{ first, &f.a, .{ Typed, onResponse(stamp) } },
        .strict_errors = false,
    }), .GET, "/v1/order/{id}");
    const want = [_][]const u8{ "first", "Step", "Typed", "onResponse(stamp)", ".ctl (Step)", "second", "onFinish(count)", ".audit (Step)", "third" };
    try testing.expectEqual(want.len, names.len);
    for (want, names) |w, n| try testing.expectEqualStrings(w, n);
    // At run time: the run phases in that order, then the handler.
    var res = try f.request("/v1/order/1");
    defer res.deinit();
    try testing.expectEqual(204, res.status);
    try testing.expectEqualStrings("first.run", journal.words[0]);
    try testing.expectEqualStrings("third.run", journal.words[6]);
    try testing.expectEqualStrings("handler", journal.words[7]);
}

test "order on three levels: run, onResponse and onFinish all go forward" {
    var f: OrderFixture = .{};
    try f.start();
    defer f.stop();
    var res = try f.request("/v1/order/1");
    defer res.deinit();
    try testing.expectEqual(204, res.status);
    try journal.expect("first.run a.run Typed.run ctl.run second.run audit.run third.run handler " ++
        "a.onResponse Typed.onResponse stamp.onResponse ctl.onResponse audit.onResponse " ++
        "a.onFinish Typed.onFinish ctl.onFinish count.onFinish audit.onFinish");
    // What the after phases set went out with the response.
    try testing.expectEqualStrings("1", res.header("x-a").?);
    try testing.expectEqualStrings("1", res.header("x-stamp").?);
    try testing.expectEqualStrings("1", res.header("x-audit").?);

    // The answer to an error of the handler goes through the same phases.
    const level = testing.log_level;
    testing.log_level = .err; // the 500 is logged as a warning
    defer testing.log_level = level;
    var failed = try f.request("/v1/order/1/fail");
    defer failed.deinit();
    try testing.expectEqual(500, failed.status);
    try journal.expect("first.run a.run Typed.run ctl.run second.run handler " ++
        "a.onResponse Typed.onResponse stamp.onResponse ctl.onResponse " ++
        "a.onFinish Typed.onFinish ctl.onFinish count.onFinish");
    try testing.expectEqualStrings("1", failed.header("x-ctl").?);
}

test "a run that fails at k: elements before k get after phases, k and later do not" {
    var f: OrderFixture = .{};
    try f.start();
    defer f.stop();
    const level = testing.log_level;
    testing.log_level = .err; // each 500 is logged as a warning
    defer testing.log_level = level;

    // The controller's object fails: the server's elements before it, the
    // element without run among them too, get theirs; it and those after
    // it, onFinish(count) without run among them, get none.
    f.ctl.does = .fail;
    var at_controller = try f.request("/v1/order/1");
    defer at_controller.deinit();
    try testing.expectEqual(500, at_controller.status);
    try journal.expect("first.run a.run Typed.run ctl.run a.onResponse Typed.onResponse stamp.onResponse a.onFinish Typed.onFinish");
    try testing.expectEqual(null, at_controller.header("x-ctl"));

    // The server's object fails: no after phases at all, and the route is
    // never applied.
    f.ctl.does = .next;
    f.a.does = .fail;
    var at_server = try f.request("/v1/order/1");
    defer at_server.deinit();
    try testing.expectEqual(500, at_server.status);
    try journal.expect("first.run a.run");

    // The method's object fails: everything before it gets its after phases.
    f.a.does = .next;
    f.audit.does = .fail;
    var at_method = try f.request("/v1/order/1");
    defer at_method.deinit();
    try testing.expectEqual(500, at_method.status);
    try journal.expect("first.run a.run Typed.run ctl.run second.run audit.run " ++
        "a.onResponse Typed.onResponse stamp.onResponse ctl.onResponse " ++
        "a.onFinish Typed.onFinish ctl.onFinish count.onFinish");
}

test ".handled stops the chain; .handled without a response is 500" {
    var f: OrderFixture = .{};
    try f.start();
    defer f.stop();

    // Its response goes out; nothing after it runs, the handler neither.
    f.a.does = .handle;
    var handled = try f.request("/v1/order/1");
    defer handled.deinit();
    try testing.expectEqual(202, handled.status);
    try testing.expectEqualStrings("handled", handled.body);
    try journal.expect("first.run a.run a.onResponse a.onFinish");

    // A field alone is no response: 500, and the element still gets its
    // after phases.
    const level = testing.log_level;
    testing.log_level = .err; // the empty .handled and the 500 are logged as warnings
    defer testing.log_level = level;
    f.a.does = .handle_empty;
    var empty = try f.request("/v1/order/1");
    defer empty.deinit();
    try testing.expectEqual(500, empty.status);
    try testing.expectEqualStrings("application/problem+json", empty.header("content-type").?);
    try testing.expectEqualStrings("a field", empty.header("x-only").?);
    try journal.expect("first.run a.run a.onResponse a.onFinish");
}

test "an onResponse error is logged and the response goes as it is" {
    var f: OrderFixture = .{};
    try f.start();
    defer f.stop();
    const level = testing.log_level;
    testing.log_level = .err; // the failing onResponse is logged as a warning
    defer testing.log_level = level;
    f.a.response_fails = true;
    var res = try f.request("/v1/order/1");
    defer res.deinit();
    // The handler's response, what the phase set before it failed, and the
    // phases after it.
    try testing.expectEqual(204, res.status);
    try testing.expectEqualStrings("1", res.header("x-a").?);
    try testing.expectEqualStrings("1", res.header("x-audit").?);
    try journal.expect("first.run a.run Typed.run ctl.run second.run audit.run third.run handler " ++
        "a.onResponse Typed.onResponse stamp.onResponse ctl.onResponse audit.onResponse " ++
        "a.onFinish Typed.onFinish ctl.onFinish count.onFinish audit.onFinish");
}

/// A global middleware that answers a CORS preflight itself, and notes
/// whether it saw a route.
const Preflight = struct {
    runs: u32 = 0,
    saw_route: bool = false,

    pub fn run(self: *Preflight, ctx: *Context) !MiddlewareResult {
        self.runs += 1;
        if (ctx.route() != null) self.saw_route = true;
        if (ctx.request.method != .OPTIONS or ctx.request.header("access-control-request-method") == null) return .next;
        try ctx.response.status(204).setHeader("access-control-allow-origin", "https://app.example");
        return .handled;
    }
};

const PlainController = struct {
    pub const http_routes = routes.routes(.{ .methods = .{ .ok = routes.get("/ok", .{}) } });

    pub fn ok(_: *PlainController, _: *Context) !void {}
};

test "global middleware runs before routing: a preflight OPTIONS to an unknown path reaches it" {
    const io = testing.io;
    var preflight: Preflight = .{};
    var plain: PlainController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&plain}, .middleware = .{&preflight} });
    defer server.deinit(io);
    try server.start(io);

    // A preflight of a path without a route: the middleware's 204, no body.
    var cors = try b.request(io, .{ .method = .OPTIONS, .target = "/nowhere", .headers = &.{
        .{ "origin", "https://app.example" },
        .{ "access-control-request-method", "DELETE" },
    } });
    defer cors.deinit();
    try testing.expectEqual(204, cors.status);
    try testing.expectEqualStrings("https://app.example", cors.header("access-control-allow-origin").?);
    try testing.expectEqualStrings("", cors.body);

    // A path without a route and a method the path does not take: the
    // middleware ran first.
    var missing = try b.request(io, .{ .method = .GET, .target = "/nowhere" });
    defer missing.deinit();
    try testing.expectEqual(404, missing.status);
    var wrong = try b.request(io, .{ .method = .PUT, .target = "/ok" });
    defer wrong.deinit();
    try testing.expectEqual(405, wrong.status);
    // The route of a request is applied after the server's middleware.
    var ok = try b.request(io, .{ .method = .GET, .target = "/ok" });
    defer ok.deinit();
    try testing.expectEqual(204, ok.status);
    try testing.expectEqual(4, preflight.runs);
    try testing.expect(!preflight.saw_route);
}

/// Notes every onFinish: how many, and the last outcome and context.
const Finisher = struct {
    calls: std.atomic.Value(u32) = .init(0),
    last: ?Outcome = null,
    /// The context of the last onFinish, and its clock then.
    operation: ?core.Context = null,
    now: ?std.Io.Timestamp = null,
    /// The trace's state in the last onFinish, copied.
    state: [32]u8 = undefined,
    state_len: usize = 0,

    pub fn onFinish(self: *Finisher, ctx: *Context, outcome: Outcome) !void {
        self.last = outcome;
        self.operation = ctx.operation();
        self.now = ctx.now();
        if (ctx.operation().trace) |trace| {
            self.state_len = @min(trace.state.header.len, self.state.len);
            @memcpy(self.state[0..self.state_len], trace.state.header[0..self.state_len]);
        }
        _ = self.calls.fetchAdd(1, .monotonic);
    }
};

/// Answers a request with `x-early` itself.
const Early = struct {
    pub fn run(_: *Early, ctx: *Context) !MiddlewareResult {
        if (ctx.request.header("x-early") == null) return .next;
        try ctx.response.status(202).text("early");
        return .handled;
    }
};

/// Keeps the request's own context in `run`, and in `onFinish` reads what
/// its token and the bytes of its trace's state say then.
const Keeper = struct {
    kept: ?core.Context = null,
    cancelled_at_finish: ?bool = null,
    state: [32]u8 = undefined,
    state_len: usize = 0,

    pub fn run(self: *Keeper, ctx: *Context) !MiddlewareResult {
        self.kept = ctx.operation();
        return .next;
    }
    pub fn onFinish(self: *Keeper, _: *Context, _: Outcome) !void {
        const kept = self.kept orelse return;
        self.cancelled_at_finish = kept.isCancelled();
        const header = kept.trace.?.state.header;
        self.state_len = @min(header.len, self.state.len);
        @memcpy(self.state[0..self.state_len], header[0..self.state_len]);
    }
};

/// Handlers of every outcome. Its servers turn the strict error check off:
/// `fail` answers 500 with an error that no error handler maps.
const OutcomeController = struct {
    entered: std.atomic.Value(u32) = .init(0),
    edges: std.atomic.Value(u32) = .init(0),
    gate: std.Io.Event = .unset,

    pub const http_routes = routes.routes(.{
        .methods = .{
            .ok = routes.get("/ok", .{}),
            .fail = routes.get("/fail", .{}),
            .stay = routes.get("/stay", .{}),
            .slow = routes.get("/slow", .{ .timeout = std.Io.Duration.fromMilliseconds(50) }),
            .stuck = routes.get("/stuck", .{}),
            .gated = routes.get("/gated", .{}),
            // 5 ms ± 1 ms of work, a deadline of 5 ms.
            .edge = routes.get("/edge", .{ .timeout = std.Io.Duration.fromMilliseconds(5) }),
        },
    });

    pub fn ok(_: *OutcomeController, _: *Context) !void {}
    pub fn fail(_: *OutcomeController, _: *Context) !void {
        return error.TodoNotFound;
    }
    pub fn stay(_: *OutcomeController, ctx: *Context) !void {
        try ctx.io().sleep(.fromSeconds(5), .awake);
    }
    pub fn slow(_: *OutcomeController, ctx: *Context) !void {
        try ctx.io().sleep(.fromSeconds(1), .awake);
    }
    pub fn stuck(self: *OutcomeController, ctx: *Context) !void {
        _ = self.entered.fetchAdd(1, .monotonic);
        try ctx.io().sleep(.fromSeconds(10), .awake);
    }
    pub fn gated(self: *OutcomeController, ctx: *Context) !void {
        _ = self.entered.fetchAdd(1, .monotonic);
        try self.gate.wait(ctx.io());
    }
    pub fn edge(self: *OutcomeController, ctx: *Context) !void {
        // From 4 to 6 ms, spread over the calls.
        const n: u64 = self.edges.fetchAdd(1, .monotonic);
        const spread: i64 = @intCast((n *% 2654435761) % 2001);
        try ctx.io().sleep(.fromMicroseconds(4000 + spread), .awake);
        try ctx.response.text("done");
    }
};

/// Ends the process with code 4 when a test runs past its limit, so that a
/// deadlock fails the run instead of hanging it.
const Watchdog = struct {
    future: std.Io.Future(void),

    fn start(io: std.Io, name: []const u8) std.Io.ConcurrentError!Watchdog {
        return .{ .future = try io.concurrent(watch, .{ io, name }) };
    }

    fn stop(w: *Watchdog, io: std.Io) void {
        w.future.cancel(io);
    }

    fn watch(io: std.Io, name: []const u8) void {
        io.sleep(.fromSeconds(120), .awake) catch return;
        std.debug.print("test \"{s}\" still runs after 120 s: a deadlock\n", .{name});
        std.process.exit(4);
    }
};

fn sinceMs(io: std.Io, start: std.Io.Timestamp) i64 {
    return start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
}

/// Waits until `value` reaches `n`, two seconds at most.
fn waitCount(io: std.Io, value: *const std.atomic.Value(u32), n: u32) !void {
    var tries: u32 = 0;
    while (value.load(.monotonic) < n) : (tries += 1) {
        if (tries == 2000) return error.TestUnexpectedResult;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// A request on a task of its own; its response, or null for an error.
fn requestInto(backend: *TestingBackend, io: std.Io, req: TestingBackend.Request, out: *?TestingBackend.Response) std.Io.Cancelable!void {
    out.* = backend.request(io, req) catch null;
}

fn expectOutcome(finisher: *const Finisher, calls: u32, status: u16, aborted: bool, err: ?anyerror) !void {
    try testing.expectEqual(calls, finisher.calls.load(.monotonic));
    const last = finisher.last.?;
    errdefer std.debug.print("outcome: {d}, aborted {}, err {?}\n", .{ last.status, last.aborted, last.err });
    try testing.expectEqual(status, last.status);
    try testing.expectEqual(aborted, last.aborted);
    try testing.expectEqual(err, last.err);
    try testing.expect(last.duration.nanoseconds > 0);
}

test "onFinish runs exactly once: success, error, early response, client gone, deadline, stop" {
    const io = testing.io;
    var dog = try Watchdog.start(io, "onFinish runs exactly once");
    defer dog.stop(io);
    var finisher: Finisher = .{};
    var early: Early = .{};
    var outcomes: OutcomeController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{
        .backend = b.backend(),
        .controllers = .{&outcomes},
        .middleware = .{ &finisher, &early },
        .strict_errors = false,
        .shutdown_grace = std.Io.Duration.fromMilliseconds(100),
    });
    defer server.deinit(io);
    try server.start(io);
    const level = testing.log_level;
    testing.log_level = .err; // the 500 is logged as a warning
    defer testing.log_level = level;

    var ok = try b.request(io, .{ .method = .GET, .target = "/ok" });
    defer ok.deinit();
    try expectOutcome(&finisher, 1, 204, false, null);

    var failed = try b.request(io, .{ .method = .GET, .target = "/fail" });
    defer failed.deinit();
    try expectOutcome(&finisher, 2, 500, false, error.TodoNotFound);

    var answered = try b.request(io, .{ .method = .GET, .target = "/ok", .headers = &.{.{ "x-early", "1" }} });
    defer answered.deinit();
    try testing.expectEqualStrings("early", answered.body);
    try expectOutcome(&finisher, 3, 202, false, null);

    var gone = try b.request(io, .{ .method = .GET, .target = "/stay", .leave_after = .fromMilliseconds(20) });
    defer gone.deinit();
    try testing.expect(gone.aborted);
    try expectOutcome(&finisher, 4, 0, true, error.Canceled);

    var late = try b.request(io, .{ .method = .GET, .target = "/slow" });
    defer late.deinit();
    try testing.expectEqual(504, late.status);
    try expectOutcome(&finisher, 5, 504, false, error.RequestTimeout);
    try testing.expect(finisher.last.?.duration.toMilliseconds() >= 50);

    // A request at work when the server stops: canceled after the grace.
    var result: ?TestingBackend.Response = null;
    var client = try io.concurrent(requestInto, .{ &b, io, .{ .method = .GET, .target = "/stuck" }, &result });
    defer client.cancel(io) catch {};
    defer if (result) |*res| res.deinit();
    try waitCount(io, &outcomes.entered, 1);
    try server.shutdown(io);
    try client.await(io);
    try testing.expect(result.?.aborted);
    try expectOutcome(&finisher, 6, 0, true, error.Canceled);
    try testing.expectEqual(0, inFlight(&server));
}

test "onFinish gets a fresh context: same trace and tracestate, not canceled, its own deadline" {
    const io = testing.io;
    var dog = try Watchdog.start(io, "onFinish gets a fresh context");
    defer dog.stop(io);
    var finisher: Finisher = .{};
    var outcomes: OutcomeController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{
        .backend = b.backend(),
        .controllers = .{&outcomes},
        .middleware = .{&finisher},
        .strict_errors = false,
        .finish_timeout = std.Io.Duration.fromSeconds(2),
    });
    defer server.deinit(io);
    try server.start(io);

    // The client leaves: the request's token is canceled, its deadline of
    // 30 s far away.
    var gone = try b.request(io, .{ .method = .GET, .target = "/stay", .leave_after = .fromMilliseconds(20), .headers = &.{
        .{ "traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" },
        .{ "tracestate", "vendor=value" },
    } });
    defer gone.deinit();
    try testing.expect(gone.aborted);
    const op = finisher.operation.?;
    try testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736", &op.trace.?.trace_id.toHex());
    try testing.expectEqualStrings("vendor=value", finisher.state[0..finisher.state_len]);
    // No token of the request, so nothing cancels it.
    try testing.expectEqual(null, op.cancellation);
    try testing.expect(!op.isCancelled());
    // The deadline is .finish_timeout from the end of the request.
    const left = op.remaining(finisher.now.?).?;
    try testing.expect(left.nanoseconds > 0 and left.nanoseconds <= std.time.ns_per_s * 2);
}

/// An onFinish that waits ten seconds, and one after it.
const Sleeper = struct {
    canceled: bool = false,

    pub fn onFinish(self: *Sleeper, ctx: *Context, _: Outcome) !void {
        ctx.io().sleep(.fromSeconds(10), .awake) catch |err| {
            self.canceled = true;
            return err;
        };
    }
};

const AfterSleeper = struct {
    ran: bool = false,

    pub fn onFinish(self: *AfterSleeper, _: *Context, _: Outcome) !void {
        self.ran = true;
    }
};

test "onFinish past finish_timeout is canceled" {
    const io = testing.io;
    var dog = try Watchdog.start(io, "onFinish past finish_timeout is canceled");
    defer dog.stop(io);
    var sleeper: Sleeper = .{};
    var after: AfterSleeper = .{};
    var outcomes: OutcomeController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{
        .backend = b.backend(),
        .controllers = .{&outcomes},
        .middleware = .{ &sleeper, &after },
        .strict_errors = false,
        .finish_timeout = std.Io.Duration.fromMilliseconds(50),
    });
    defer server.deinit(io);
    try server.start(io);
    const level = testing.log_level;
    testing.log_level = .err; // the canceled phases are logged as warnings
    defer testing.log_level = level;

    const start = std.Io.Clock.awake.now(io);
    var res = try b.request(io, .{ .method = .GET, .target = "/ok" });
    defer res.deinit();
    try testing.expectEqual(204, res.status);
    const elapsed = sinceMs(io, start);
    try testing.expect(elapsed >= 50 and elapsed < 2000);
    // The phase at work is canceled; the one after it is left out.
    try testing.expect(sleeper.canceled);
    try testing.expect(!after.ran);
    try testing.expectEqual(0, inFlight(&server));
}

test "the request's token and tracestate stay valid until onFinish ends" {
    const io = testing.io;
    var dog = try Watchdog.start(io, "the request's token and tracestate stay valid until onFinish ends");
    defer dog.stop(io);
    var keeper: Keeper = .{};
    var outcomes: OutcomeController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&outcomes}, .middleware = .{&keeper}, .strict_errors = false });
    defer server.deinit(io);
    try server.start(io);

    var gone = try b.request(io, .{ .method = .GET, .target = "/stay", .leave_after = .fromMilliseconds(20), .headers = &.{
        .{ "traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" },
        .{ "tracestate", "vendor=value" },
    } });
    defer gone.deinit();
    // The context the request ran with: its token, canceled when the client
    // left, and the bytes of its tracestate, both still there.
    try testing.expectEqual(true, keeper.cancelled_at_finish.?);
    try testing.expectEqualStrings("vendor=value", keeper.state[0..keeper.state_len]);
}

/// Values with a `deinit` that writes into the journal.
const FirstValue = struct {
    pub fn deinit(_: *FirstValue) void {
        journal.add("FirstValue.deinit");
    }
};
const SecondValue = struct {
    pub fn deinit(_: *SecondValue) void {
        journal.add("SecondValue.deinit");
    }
};

/// Puts both values, and notes its onFinish.
const Putter = struct {
    pub fn run(_: *Putter, ctx: *Context) !MiddlewareResult {
        try ctx.locals.put(FirstValue, .{});
        try ctx.locals.put(SecondValue, .{});
        return .next;
    }
    pub fn onFinish(_: *Putter, ctx: *Context, _: Outcome) !void {
        // The values are still there.
        if (ctx.locals.get(FirstValue) != null and ctx.locals.get(SecondValue) != null) journal.add("Putter.onFinish");
    }
};

test "deinit of stored values runs after onFinish, last put first" {
    const io = testing.io;
    var putter: Putter = .{};
    var outcomes: OutcomeController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&outcomes}, .middleware = .{&putter}, .strict_errors = false });
    defer server.deinit(io);
    try server.start(io);
    journal = .{};
    var res = try b.request(io, .{ .method = .GET, .target = "/ok" });
    defer res.deinit();
    try journal.expect("Putter.onFinish SecondValue.deinit FirstValue.deinit");
}

/// Notes each outcome of `/edge`: the handler's 200, or 504, once each.
const EdgeFinisher = struct {
    calls: std.atomic.Value(u32) = .init(0),
    wrong: std.atomic.Value(u32) = .init(0),

    pub fn onFinish(self: *EdgeFinisher, _: *Context, outcome: Outcome) !void {
        _ = self.calls.fetchAdd(1, .monotonic);
        const answered = !outcome.aborted and outcome.status == 200 and outcome.err == null;
        const timed_out = if (outcome.err) |err| err == error.RequestTimeout else false;
        const late = !outcome.aborted and outcome.status == 504 and timed_out;
        if (!answered and !late) _ = self.wrong.fetchAdd(1, .monotonic);
    }
};

/// Requests of `/edge` until `taken` reaches `total`.
fn requestEdges(backend: *TestingBackend, io: std.Io, taken: *std.atomic.Value(u32), total: u32, failed: *std.atomic.Value(u32)) std.Io.Cancelable!void {
    while (taken.fetchAdd(1, .monotonic) < total) {
        var res = backend.request(io, .{ .method = .GET, .target = "/edge" }) catch {
            _ = failed.fetchAdd(1, .monotonic);
            continue;
        };
        res.deinit();
    }
}

test "onFinish runs once when the handler ends at its deadline" {
    // Review focus 3: 1 000 requests, 16 at a time; the handler ends 5 ms
    // ± 1 ms in, the deadline is 5 ms. Every request reaches onFinish once,
    // with the handler's 200 or the 504.
    const io = testing.io;
    var dog = try Watchdog.start(io, "onFinish runs once when the handler ends at its deadline");
    defer dog.stop(io);
    var finisher: EdgeFinisher = .{};
    var outcomes: OutcomeController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&outcomes}, .middleware = .{&finisher}, .strict_errors = false });
    defer server.deinit(io);
    try server.start(io);

    var taken: std.atomic.Value(u32) = .init(0);
    var failed: std.atomic.Value(u32) = .init(0);
    var workers: std.Io.Group = .init;
    defer workers.cancel(io);
    for (0..16) |_| try workers.concurrent(io, requestEdges, .{ &b, io, &taken, 1000, &failed });
    try workers.await(io);
    try testing.expectEqual(0, failed.load(.monotonic));
    try testing.expectEqual(1000, finisher.calls.load(.monotonic));
    try testing.expectEqual(0, finisher.wrong.load(.monotonic));
    try testing.expectEqual(0, inFlight(&server));
}

/// Does what the request's `x-do` says: `handle` answers 202 itself, `fail`
/// fails its run, `finish-fail` fails its onFinish.
const Switch = struct {
    pub fn run(_: *Switch, ctx: *Context) !MiddlewareResult {
        const what = ctx.request.header("x-do") orelse return .next;
        if (std.mem.eql(u8, what, "handle")) {
            _ = ctx.response.status(202);
            return .handled;
        }
        if (std.mem.eql(u8, what, "fail")) return error.Refused;
        return .next;
    }
    pub fn onFinish(_: *Switch, ctx: *Context, _: Outcome) !void {
        const what = ctx.request.header("x-do") orelse return;
        if (std.mem.eql(u8, what, "finish-fail")) return error.Broken;
    }
};

/// One request with `x-do: what`; a status other than `status` or 503
/// counts in `wrong`.
fn requestSwitch(backend: *TestingBackend, io: std.Io, what: []const u8, status: u16, wrong: *std.atomic.Value(u32)) std.Io.Cancelable!void {
    var res = backend.request(io, .{ .method = .GET, .target = "/ok", .headers = &.{.{ "x-do", what }} }) catch {
        _ = wrong.fetchAdd(1, .monotonic);
        return;
    };
    defer res.deinit();
    if (res.aborted or (res.status != status and res.status != 503)) _ = wrong.fetchAdd(1, .monotonic);
}

test "in-flight slots come back after .handled, a failing run and a failing onFinish" {
    // Review focus 2: 1 002 requests, six at a time, on four places, so
    // that some get 503; then four requests at once all enter.
    const io = testing.io;
    var dog = try Watchdog.start(io, "in-flight slots come back after .handled, a failing run and a failing onFinish");
    defer dog.stop(io);
    var choice: Switch = .{};
    var outcomes: OutcomeController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{
        .backend = b.backend(),
        .controllers = .{&outcomes},
        .middleware = .{&choice},
        .strict_errors = false,
        .max_in_flight = 4,
    });
    defer server.deinit(io);
    try server.start(io);
    const level = testing.log_level;
    testing.log_level = .err; // the 500s and the failing onFinish are logged as warnings
    defer testing.log_level = level;

    const kinds = [_]struct { []const u8, u16 }{
        .{ "handle", 202 }, .{ "fail", 500 }, .{ "finish-fail", 204 },
        .{ "handle", 202 }, .{ "fail", 500 }, .{ "finish-fail", 204 },
    };
    var wrong: std.atomic.Value(u32) = .init(0);
    for (0..167) |_| {
        var clients: std.Io.Group = .init;
        defer clients.cancel(io);
        for (kinds) |kind| try clients.concurrent(io, requestSwitch, .{ &b, io, kind[0], kind[1], &wrong });
        try clients.await(io);
    }
    try testing.expectEqual(0, wrong.load(.monotonic));
    try testing.expectEqual(0, inFlight(&server));

    // All four places are free.
    var held: [4]?TestingBackend.Response = @splat(null);
    var clients: std.Io.Group = .init;
    defer clients.cancel(io);
    defer for (&held) |*r| if (r.*) |*res| res.deinit();
    for (&held) |*out| try clients.concurrent(io, requestInto, .{ &b, io, .{ .method = .GET, .target = "/gated" }, out });
    try waitCount(io, &outcomes.entered, 4);
    outcomes.gate.set(io);
    try clients.await(io);
    for (held) |r| try testing.expectEqual(204, r.?.status);
    try testing.expectEqual(0, inFlight(&server));
}

/// The middleware of the application of design section 9, as far as the
/// chain of `DELETE /api/v1/todos/{id}` goes; each phase writes its name
/// into the journal.
const sketch = struct {
    const CurrentUser = struct {
        permissions: []const []const u8,

        fn has(user: CurrentUser, permission: []const u8) bool {
            for (user.permissions) |held| {
                if (std.mem.eql(u8, held, permission)) return true;
            }
            return false;
        }
    };

    fn requestId(ctx: *Context) !MiddlewareResult {
        journal.add("requestId.run");
        try ctx.response.setHeader("x-request-id", ctx.requestId());
        return .next;
    }
    fn securityHeaders(ctx: *Context) !void {
        journal.add("securityHeaders.onResponse");
        try ctx.response.setHeader("x-content-type-options", "nosniff");
    }
    fn noCache(ctx: *Context) !void {
        journal.add("noCache.onResponse");
        try ctx.response.setHeader("cache-control", "no-store");
    }
    fn requireUser(ctx: *Context) !MiddlewareResult {
        journal.add("requireUser.run");
        _ = ctx.locals.get(CurrentUser) orelse return error.Unauthenticated;
        return .next;
    }
    fn requirePermission(comptime permission: []const u8) type {
        return struct {
            pub const name = "requirePermission(" ++ permission ++ ")";
            pub fn run(ctx: *Context) !MiddlewareResult {
                journal.add(name ++ ".run");
                const user = ctx.locals.get(CurrentUser) orelse return error.Unauthenticated;
                if (!user.has(permission)) return error.PermissionDenied;
                return .next;
            }
        };
    }
    const protected = .{ requireUser, onResponse(noCache) };

    const AccessLog = struct {
        pub fn onFinish(_: *AccessLog, _: *Context, _: Outcome) !void {
            journal.add("AccessLog.onFinish");
        }
    };
    const ServerTiming = struct {
        pub fn run(_: *ServerTiming, _: *Context) !MiddlewareResult {
            journal.add("ServerTiming.run");
            return .next;
        }
        pub fn onResponse(_: *ServerTiming, _: *Context) !void {
            journal.add("ServerTiming.onResponse");
        }
    };
    const Maintenance = struct {
        pub fn run(_: *Maintenance, _: *Context) !MiddlewareResult {
            journal.add("Maintenance.run");
            return .next;
        }
    };
    const Cors = struct {
        pub fn run(_: *Cors, _: *Context) !MiddlewareResult {
            journal.add("Cors.run");
            return .next;
        }
        pub fn onResponse(_: *Cors, _: *Context) !void {
            journal.add("Cors.onResponse");
        }
    };
    const JwtAuth = struct {
        pub fn run(_: *JwtAuth, ctx: *Context) !MiddlewareResult {
            journal.add("JwtAuth.run");
            if (ctx.request.header("authorization") != null) try ctx.locals.put(CurrentUser, .{ .permissions = &.{ "todos", "todos:delete" } });
            return .next;
        }
    };
    const Audit = struct {
        pub fn onFinish(_: *Audit, _: *Context, _: Outcome) !void {
            journal.add("Audit.onFinish");
        }
    };

    const TodosV1Controller = struct {
        audit: *Audit,

        pub const http_routes = routes.routes(.{
            .prefix = "/v1/todos",
            .middleware = .{ protected, requirePermission("todos") },
            .methods = .{
                .delete = routes.delete("/{id}", .{ .middleware = .{ requirePermission("todos:delete"), .audit } }),
            },
        });

        pub fn delete(_: *TodosV1Controller, _: *Context) !void {
            journal.add("delete");
        }
    };
};

test "the chain of DELETE /v1/todos/{id} for the sketch's options" {
    const io = testing.io;
    var access_log: sketch.AccessLog = .{};
    var timing: sketch.ServerTiming = .{};
    var maintenance: sketch.Maintenance = .{};
    var cors: sketch.Cors = .{};
    var jwt_auth: sketch.JwtAuth = .{};
    var audit: sketch.Audit = .{};
    var todos: sketch.TodosV1Controller = .{ .audit = &audit };
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    const options = .{
        .backend = b.backend(),
        .prefix = "/api",
        .controllers = .{&todos},
        .middleware = .{ sketch.requestId, &access_log, &timing, onResponse(sketch.securityHeaders), &maintenance, &cors, &jwt_auth },
    };

    // The order of design section 9, at compile time.
    const names = comptime chainNames(@TypeOf(options), .DELETE, "/v1/todos/{id}");
    const want = [_][]const u8{
        "requestId",           "AccessLog",                "ServerTiming",                    "onResponse(securityHeaders)",
        "Maintenance",         "Cors",                     "JwtAuth",                         "requireUser",
        "onResponse(noCache)", "requirePermission(todos)", "requirePermission(todos:delete)", ".audit (Audit)",
    };
    try testing.expectEqual(want.len, names.len);
    for (want, names) |w, n| try testing.expectEqualStrings(w, n);

    // And each phase at run time, forward.
    var server = try Server.init(testing.allocator, options);
    defer server.deinit(io);
    try server.start(io);
    journal = .{};
    var res = try b.request(io, .{ .method = .DELETE, .target = "/api/v1/todos/1", .headers = &.{.{ "authorization", "Bearer ann" }} });
    defer res.deinit();
    try testing.expectEqual(204, res.status);
    try journal.expect("requestId.run ServerTiming.run Maintenance.run Cors.run JwtAuth.run requireUser.run requirePermission(todos).run requirePermission(todos:delete).run delete " ++
        "ServerTiming.onResponse securityHeaders.onResponse Cors.onResponse noCache.onResponse " ++
        "AccessLog.onFinish Audit.onFinish");
    try testing.expectEqualStrings("no-store", res.header("cache-control").?);

    // Without a user, requireUser ends it with 401: the elements before it
    // get their after phases, those after it none.
    journal = .{};
    var anonymous = try b.request(io, .{ .method = .DELETE, .target = "/api/v1/todos/1" });
    defer anonymous.deinit();
    try testing.expectEqual(401, anonymous.status);
    try journal.expect("requestId.run ServerTiming.run Maintenance.run Cors.run JwtAuth.run requireUser.run " ++
        "ServerTiming.onResponse securityHeaders.onResponse Cors.onResponse AccessLog.onFinish");
    try testing.expectEqual(null, anonymous.header("cache-control"));
}

/// An onFinish that fails, before one that notes it ran.
const FailingFinish = struct {
    pub fn onFinish(_: *FailingFinish, _: *Context, _: Outcome) !void {
        journal.add("FailingFinish.onFinish");
        return error.Broken;
    }
};

test "a failing onFinish is logged and the next one runs" {
    const io = testing.io;
    var failing: FailingFinish = .{};
    var after: AfterSleeper = .{};
    var outcomes: OutcomeController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&outcomes}, .middleware = .{ &failing, &after }, .strict_errors = false });
    defer server.deinit(io);
    try server.start(io);
    const level = testing.log_level;
    testing.log_level = .err; // the failing onFinish is logged as a warning
    defer testing.log_level = level;
    journal = .{};
    var res = try b.request(io, .{ .method = .GET, .target = "/ok" });
    defer res.deinit();
    try testing.expectEqual(204, res.status);
    try journal.expect("FailingFinish.onFinish");
    try testing.expect(after.ran);
}

test "a field of the controller is read on every request" {
    var f: OrderFixture = .{};
    try f.start();
    defer f.stop();
    var other: Step = .init("other");
    var before = try f.request("/v1/order/1");
    defer before.deinit();
    try testing.expectEqualStrings("audit.run", journal.words[5]);
    // The controller points .audit elsewhere: the next request runs that.
    f.controller.audit = &other;
    var after = try f.request("/v1/order/1");
    defer after.deinit();
    try testing.expectEqualStrings("other.run", journal.words[5]);
    try testing.expectEqualStrings("1", after.header("x-other").?);
}
