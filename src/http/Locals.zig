//! The locals of a request, as `ctx.locals`: values that
//! a middleware puts for the middleware after it and for the handler, one
//! value per type. The type itself is the key, so two types never share
//! one, whatever their names.
//!
//! ```zig
//! try ctx.locals.put(CurrentUser, .{ .id = claims.sub, .permissions = claims.permissions });
//! const user = ctx.locals.get(CurrentUser) orelse return error.Unauthenticated; // null: nobody put one
//! const plan = try ctx.local(Plan); // error.LocalMissing (500) when nobody put one
//! ```
//!
//! A value is copied into the request's arena and lives until the request
//! has ended. A type with `pub fn deinit(self: *T) void` has it called
//! then, after the `onFinish` phases of the middleware, the value put last
//! first. A type put again gives the newer value from then on; both get
//! their `deinit`.
const std = @import("std");

const Locals = @This();

/// Internal to the server.
internal: Internal,

pub const Internal = struct {
    arena: std.mem.Allocator,
    /// The values in the order they were put; a lookup goes from the end,
    /// so a type put again gives its newer value.
    entries: std.ArrayList(Entry) = .empty,

    /// Runs the `deinit` of every value that has one, the value put last
    /// first; the server calls it once the request has ended.
    pub fn deinitValues(i: *Internal) void {
        var at = i.entries.items.len;
        while (at > 0) {
            at -= 1;
            const entry = i.entries.items[at];
            if (entry.deinit) |deinit| deinit(entry.value);
        }
        i.entries.clearRetainingCapacity();
    }
};

const Entry = struct {
    key: *const u8,
    value: *anyopaque,
    deinit: ?*const fn (value: *anyopaque) void,
};

/// Empty locals over the request's arena.
pub fn init(arena: std.mem.Allocator) Locals {
    return .{ .internal = .{ .arena = arena } };
}

/// Puts `value` as the value of type `T`, a copy in the request's arena.
pub fn put(l: *Locals, comptime T: type, value: T) error{OutOfMemory}!void {
    const arena = l.internal.arena;
    const copy = try arena.create(T);
    copy.* = value;
    try l.internal.entries.append(arena, .{ .key = keyOf(T), .value = @ptrCast(copy), .deinit = deinitOf(T) });
}

/// The value of type `T`, or null when nobody put one.
pub fn get(l: *const Locals, comptime T: type) ?T {
    const key = keyOf(T);
    var at = l.internal.entries.items.len;
    while (at > 0) {
        at -= 1;
        const entry = l.internal.entries.items[at];
        if (entry.key == key) return @as(*const T, @ptrCast(@alignCast(entry.value))).*;
    }
    return null;
}

/// The key of `T`: the address of a variable of its own. A struct made in
/// a generic function is one type for all calls unless it captures the
/// argument, so `Key` captures `T`. `@typeName` would not do: two types
/// made by one function may share a name.
fn Key(comptime T: type) type {
    return struct {
        comptime {
            _ = T;
        }
        var unique: u8 = 0;
    };
}

fn keyOf(comptime T: type) *const u8 {
    return &Key(T).unique;
}

/// The `deinit` of `T`, when it has one of the form `fn (self: *T) void`.
fn deinitOf(comptime T: type) ?*const fn (value: *anyopaque) void {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return null,
    }
    if (!@hasDecl(T, "deinit") or @TypeOf(T.deinit) != fn (*T) void) return null;
    return struct {
        fn call(value: *anyopaque) void {
            T.deinit(@ptrCast(@alignCast(value)));
        }
    }.call;
}

const testing = std.testing;

const CurrentUser = struct { id: []const u8 };
const Plan = struct { max_todos: u32 };
/// A marker without data.
const Admin = struct {};

test "locals: put, get and local by type" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var locals: Locals = .init(arena_state.allocator());
    try testing.expectEqual(null, locals.get(CurrentUser));

    try locals.put(CurrentUser, .{ .id = "ann" });
    try locals.put(Plan, .{ .max_todos = 10 });
    try locals.put(Admin, .{});
    try locals.put(u32, 7);
    try testing.expectEqualStrings("ann", locals.get(CurrentUser).?.id);
    try testing.expectEqual(10, locals.get(Plan).?.max_todos);
    try testing.expect(locals.get(Admin) != null);
    try testing.expectEqual(7, locals.get(u32).?);
    try testing.expectEqual(null, locals.get(u64));

    // A copy: changing the value put changes nothing; putting again gives
    // the newer value.
    var plan: Plan = .{ .max_todos = 20 };
    try locals.put(Plan, plan);
    plan.max_todos = 30;
    try testing.expectEqual(20, locals.get(Plan).?.max_todos);
    locals.internal.deinitValues();
}

fn Started(comptime n: u8) type {
    const S = struct {
        at: u8 = n,
    };
    return S;
}

test "two types with the same name get different keys" {
    const First = Started(1);
    const Second = Started(2);
    try testing.expect(First != Second);
    try testing.expectEqualStrings(@typeName(First), @typeName(Second));

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var locals: Locals = .init(arena_state.allocator());
    try locals.put(First, .{});
    try testing.expectEqual(1, locals.get(First).?.at);
    try testing.expectEqual(null, locals.get(Second));
    try locals.put(Second, .{});
    try testing.expectEqual(1, locals.get(First).?.at);
    try testing.expectEqual(2, locals.get(Second).?.at);
}

/// Appends its name to `log` when its `deinit` runs.
const Tracked = struct {
    name: u8,
    log: *std.ArrayList(u8),

    pub fn deinit(self: *Tracked) void {
        self.log.appendAssumeCapacity(self.name);
    }
};

const OtherTracked = struct {
    inner: Tracked,

    pub fn deinit(self: *OtherTracked) void {
        self.inner.deinit();
    }
};

/// Its `deinit` takes an allocator: locals do not call it.
const NeedsAllocator = struct {
    var calls: u32 = 0;

    pub fn deinit(_: *NeedsAllocator, _: std.mem.Allocator) void {
        calls += 1;
    }
};

test "deinitValues runs each deinit once, the value put last first" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var buffer: [8]u8 = undefined;
    var order: std.ArrayList(u8) = .initBuffer(&buffer);
    var locals: Locals = .init(arena_state.allocator());
    try locals.put(Tracked, .{ .name = 'a', .log = &order });
    try locals.put(NeedsAllocator, .{});
    try locals.put(OtherTracked, .{ .inner = .{ .name = 'b', .log = &order } });
    try locals.put(Tracked, .{ .name = 'c', .log = &order });
    locals.internal.deinitValues();
    try testing.expectEqualStrings("cba", order.items);
    try testing.expectEqual(0, NeedsAllocator.calls);
    locals.internal.deinitValues();
    try testing.expectEqualStrings("cba", order.items);
}

const Server = @import("Server.zig");
const Context = @import("Context.zig");
const TestingBackend = @import("testing/Backend.zig");
const routes = @import("routes.zig");

/// Handlers that put locals and read them.
const LocalsController = struct {
    order: std.ArrayList(u8) = .empty,
    buffer: [8]u8 = undefined,

    pub const http_routes = routes.routes(.{ .methods = .{
        .both = routes.get("/both", .{}),
        .missing = routes.get("/missing", .{}),
    } });

    pub fn both(self: *LocalsController, ctx: *Context) !void {
        try ctx.locals.put(Tracked, .{ .name = 'a', .log = &self.order });
        try ctx.locals.put(OtherTracked, .{ .inner = .{ .name = 'b', .log = &self.order } });
        const tracked = try ctx.local(Tracked);
        try ctx.response.text(&.{tracked.name});
        // Nothing runs before the request has ended.
        if (self.order.items.len != 0) return error.TooEarly;
    }
    pub fn missing(_: *LocalsController, ctx: *Context) !void {
        _ = try ctx.local(Plan);
    }
};

test "local of a missing type is LocalMissing; the values go once the request has ended" {
    const io = testing.io;
    var controller: LocalsController = .{};
    controller.order = .initBuffer(&controller.buffer);
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .controllers = .{&controller}, .strict_errors = false }, .{ .listen = .{ .backend = b.backend() } });
    defer server.deinit(io);
    try server.start(io);
    const level = testing.log_level;
    testing.log_level = .err; // the missing value and the 500 are logged as warnings
    defer testing.log_level = level;

    var got = try b.request(io, .{ .method = .GET, .target = "/both" });
    defer got.deinit();
    try testing.expectEqual(200, got.status);
    try testing.expectEqualStrings("a", got.body);
    try testing.expectEqualStrings("ba", controller.order.items);

    var missing = try b.request(io, .{ .method = .GET, .target = "/missing" });
    defer missing.deinit();
    try testing.expectEqual(500, missing.status);
    try testing.expectEqualStrings("application/problem+json", missing.header("content-type").?);
}
