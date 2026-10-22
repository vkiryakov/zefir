//! The parts of `rpc.Client.init`: their compile-time checks, and how the
//! middleware written as a literal becomes the engine's list. Each check
//! returns the message of the first problem it finds, or null;
//! `rpc.Client.init` stops the build with it. Internal to the module.

const std = @import("std");
const middleware = @import("../middleware.zig");
const ClientMiddleware = middleware.ClientMiddleware;
const ClientMiddlewareFn = middleware.ClientMiddlewareFn;
const ClientNext = middleware.ClientNext;
const ClientContext = @import("../engine/RawClient.zig").ClientContext;
const handlers = @import("handlers.zig");

const at = "rpc.Client.init: ";
const link_function = "fn (*rpc.ClientContext, *rpc.ClientNext) anyerror!void";
const link_method = "pub fn run(self, *rpc.ClientContext, *rpc.ClientNext) anyerror!void";

/// The compile error for the parts of `rpc.Client.init`, of type `P`, or
/// null: a struct literal of `.middleware` at most.
pub fn partsProblem(comptime P: type) ?[]const u8 {
    const shape = "parts must be a struct literal such as .{ .middleware = .{ clientMetrics, &breaker } } or .{}, got ";
    const info = switch (@typeInfo(P)) {
        .@"struct" => |info| info,
        else => return at ++ shape ++ @typeName(P),
    };
    if (info.is_tuple and info.field_names.len > 0) return at ++ shape ++ "a tuple";
    for (info.field_names) |name| {
        if (!std.mem.eql(u8, name, "middleware")) return at ++ "unknown part ." ++ name ++ "; the parts are .middleware";
    }
    if (@hasField(P, "middleware")) {
        if (linksProblem(@FieldType(P, "middleware"))) |found| return found;
    }
    return null;
}

/// The links of `.middleware`, a tuple whose type passed `linksProblem`, in
/// `buffer`, one for each item.
pub fn linksOf(links: anytype, buffer: []ClientMiddleware) []const ClientMiddleware {
    const names = @typeInfo(@TypeOf(links)).@"struct".field_names;
    inline for (names, 0..) |name, i| buffer[i] = .of(@field(links, name));
    return buffer[0..names.len];
}

/// The problem of the links of a client, a value of type `L`: middleware
/// functions and pointers to objects.
fn linksProblem(comptime L: type) ?[]const u8 {
    const shape = ".middleware must be a tuple such as .{ clientMetrics, &breaker }; got ";
    const info = switch (@typeInfo(L)) {
        .@"struct" => |info| info,
        else => return at ++ shape ++ @typeName(L),
    };
    if (!info.is_tuple and info.field_names.len > 0) return at ++ shape ++ @typeName(L);
    inline for (info.field_types, 0..) |Item, i| {
        if (@typeInfo(Item) == .@"fn" and Item != ClientMiddlewareFn)
            return std.fmt.comptimePrint("{s}.middleware[{d}] must be " ++ link_function ++ ", with anyerror written out, not inferred; got {s}", .{ at, i, handlers.typeName(Item) });
        const fits = Item == ClientMiddlewareFn or switch (@typeInfo(Item)) {
            .pointer => |pointer| pointer.size == .one and !pointer.attrs.@"const" and hasRun(pointer.child),
            else => false,
        };
        if (!fits) return std.fmt.comptimePrint("{s}.middleware[{d}] must be " ++ link_function ++ " or a pointer to a type with " ++ link_method, .{ at, i });
    }
    return null;
}

/// Whether `X` has `pub fn run(self: *X, ctx: *rpc.ClientContext, next: *rpc.ClientNext) anyerror!void`.
fn hasRun(comptime X: type) bool {
    switch (@typeInfo(X)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return false,
    }
    if (!@hasDecl(X, "run")) return false;
    return @TypeOf(X.run) == fn (*X, *ClientContext, *ClientNext) anyerror!void;
}

const testing = std.testing;

fn expectProblem(comptime P: type, comptime expected: []const u8) !void {
    const found = comptime partsProblem(P);
    if (found == null) {
        std.debug.print("expected: {s}\ngot no problem\n", .{expected});
        return error.TestExpectedProblem;
    }
    try testing.expectEqualStrings(expected, found.?);
}

fn expectNoProblem(comptime P: type) !void {
    const found = comptime partsProblem(P);
    if (found) |message| {
        std.debug.print("unexpected: {s}\n", .{message});
        return error.TestUnexpectedProblem;
    }
}

/// The parts of a client with the field `name` of type `T`.
fn With(comptime name: [:0]const u8, comptime T: type) type {
    return @Struct(.auto, null, &.{name}, &.{T}, &@splat(.{}));
}

fn countCalls(ctx: *ClientContext, next: *ClientNext) anyerror!void {
    _ = ctx;
    return next.run();
}

fn inferredLink(ctx: *ClientContext, next: *ClientNext) !void {
    _ = ctx;
    return next.run();
}

const Breaker = struct {
    pub fn run(self: *Breaker, ctx: *ClientContext, next: *ClientNext) anyerror!void {
        _ = self;
        _ = ctx;
        return next.run();
    }
};

/// A middleware object of the server, not of the client.
const ServerSide = struct {
    pub fn run(self: *ServerSide, ctx: *@import("../engine/Context.zig").Context, next: *middleware.Next) anyerror!void {
        _ = self;
        _ = ctx;
        return next.run();
    }
};

test "good parts pass" {
    try expectNoProblem(@TypeOf(.{}));
    try expectNoProblem(With("middleware", struct { @TypeOf(countCalls), *Breaker }));
    try expectNoProblem(With("middleware", @TypeOf(.{})));
}

test "the shape of the parts" {
    try expectProblem(u32, "rpc.Client.init: parts must be a struct literal such as .{ .middleware = .{ clientMetrics, &breaker } } or .{}, got u32");
    try expectProblem(struct { u32 }, "rpc.Client.init: parts must be a struct literal such as .{ .middleware = .{ clientMetrics, &breaker } } or .{}, got a tuple");
    // A setting among the parts: it goes into the options.
    try expectProblem(With("credentials", u8), "rpc.Client.init: unknown part .credentials; the parts are .middleware");
}

test "the links of a client are functions or pointers to objects" {
    try expectNoProblem(With("middleware", struct { @TypeOf(countCalls), *Breaker }));
    const message = "rpc.Client.init: .middleware[1] must be fn (*rpc.ClientContext, *rpc.ClientNext) anyerror!void or a pointer to a type with pub fn run(self, *rpc.ClientContext, *rpc.ClientNext) anyerror!void";
    try expectProblem(With("middleware", struct { @TypeOf(countCalls), Breaker }), message);
    try expectProblem(With("middleware", struct { @TypeOf(countCalls), *const Breaker }), message);
    try expectProblem(With("middleware", struct { @TypeOf(countCalls), *ServerSide }), message);
    try expectProblem(With("middleware", struct { @TypeOf(countCalls), []Breaker }), message);
    try expectProblem(With("middleware", struct { @TypeOf(countCalls), @TypeOf(inferredLink) }), "rpc.Client.init: .middleware[1] must be fn (*rpc.ClientContext, *rpc.ClientNext) anyerror!void, with anyerror written out, not inferred; got fn (*rpc.ClientContext, *rpc.ClientNext) !void");
    try expectProblem(With("middleware", *Breaker), "rpc.Client.init: .middleware must be a tuple such as .{ clientMetrics, &breaker }; got *app.client_options.Breaker");
}

test "the links become the engine's, in order" {
    var breaker: Breaker = .{};
    var buffer: [2]ClientMiddleware = undefined;
    const links = linksOf(.{ countCalls, &breaker }, &buffer);
    try testing.expectEqual(@as(usize, 2), links.len);
    try testing.expectEqual(@as(?*anyopaque, null), links[0].ptr);
    try testing.expectEqual(@as(?*anyopaque, &breaker), links[1].ptr);
    try testing.expectEqual(@as(usize, 0), linksOf(.{}, &buffer).len);
}
