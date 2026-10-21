//! Values in the document as the server writes them: the examples of the
//! declarations, the defaults of fields and the bodies `mapError` gives
//! errors. `value` follows the writer of zefir-http's responses: fields by
//! their outside names (`v.rename`) in the order of their declaration, a
//! union as an object of one key, a float that is not finite as `null`. It
//! runs no transforms: an example shows what the type holds.
const std = @import("std");
const v = @import("validator");
const json = @import("json.zig");
const declarations = @import("openapi.zig");

/// The JSON of `x`, a value of `T`, as the server writes it; with
/// `problem`, inside the body of an `http.Problem`, whose null fields it
/// leaves out. `where` names the value in a message.
pub fn value(comptime T: type, comptime x: T, comptime problem: bool, comptime where: []const u8) json.Node {
    comptime {
        @setEvalBranchQuota(1_000_000);
        switch (@typeInfo(T)) {
            .bool => return .{ .boolean = x },
            .int, .comptime_int => return .{ .raw = std.fmt.comptimePrint("{d}", .{x}) },
            .float => {
                if (!std.math.isFinite(x)) return .null;
                if (@as(f64, @floatCast(x)) != x) @compileError("zefir.openapi: " ++ where ++ ": " ++ @typeName(T) ++ " " ++ std.fmt.comptimePrint("{}", .{x}) ++ " has no JSON number");
                return .{ .raw = std.fmt.comptimePrint("{}", .{@as(f64, @floatCast(x))}) };
            },
            .optional => |o| return if (x) |payload| value(o.child, payload, problem, where) else .null,
            .@"enum" => |e| {
                if (declarations.writesItself(T)) writesItself(T, where);
                for (e.field_names) |name| {
                    if (x == @field(T, name)) return .{ .string = name };
                }
                return .{ .raw = std.fmt.comptimePrint("{d}", .{@backingInt(x)}) };
            },
            .pointer => |p| switch (p.size) {
                .one => return value(p.child, x.*, problem, where),
                .slice => return if (p.child == u8) string(x, where) else items(p.child, x, problem, where),
                .many => if (p.sentinel() != null) return value([]const p.child, std.mem.span(x), problem, where),
                .c => {},
            },
            .array => |a| return if (a.child == u8) string(&x, where) else items(a.child, &x, problem, where),
            .@"struct" => |s| {
                if (declarations.writesItself(T)) writesItself(T, where);
                if (s.is_tuple) {
                    var out: [s.field_types.len]json.Node = undefined;
                    for (s.field_types, &out, 0..) |F, *item, i| item.* = value(F, x[i], problem, where);
                    const final = out;
                    return .{ .array = &final };
                }
                var members: []const json.Member = &.{};
                for (s.field_names, s.field_types) |name, F| {
                    if (F == void) continue;
                    const field = @field(x, name);
                    if (problem and @typeInfo(F) == .optional and field == null) continue;
                    const key = v.nameOf(T, @field(std.meta.FieldEnum(T), name));
                    members = members ++ [_]json.Member{.{ .key = key, .value = value(F, field, problem, where ++ "." ++ key) }};
                }
                return .{ .object = members };
            },
            .@"union" => |u| if (u.tag_type != null) {
                if (declarations.writesItself(T)) writesItself(T, where);
                const tag = @tagName(std.meta.activeTag(x));
                const P = @FieldType(T, tag);
                const payload: json.Node = if (P == void) .{ .object = &.{} } else value(P, @field(x, tag), problem, where ++ "." ++ tag);
                return .{ .object = &.{.{ .key = tag, .value = payload }} };
            },
            else => {},
        }
        @compileError("zefir.openapi: " ++ where ++ ": a value of " ++ @typeName(T) ++ " has no JSON");
    }
}

fn items(comptime Item: type, comptime list: []const Item, comptime problem: bool, comptime where: []const u8) json.Node {
    var out: [list.len]json.Node = undefined;
    for (list, &out, 0..) |item, *node, i| node.* = value(Item, item, problem, std.fmt.comptimePrint("{s}[{d}]", .{ where, i }));
    const final = out;
    return .{ .array = &final };
}

/// A string of the document; the server would write bytes that are not
/// UTF-8 as U+FFFD, which an example has no reason to hold.
fn string(comptime bytes: []const u8, comptime where: []const u8) json.Node {
    if (!std.unicode.utf8ValidateSlice(bytes)) @compileError("zefir.openapi: " ++ where ++ ": the string is not valid UTF-8");
    return .{ .string = bytes };
}

fn writesItself(comptime T: type, comptime where: []const u8) noreturn {
    @compileError("zefir.openapi: " ++ where ++ ": " ++ @typeName(T) ++ " writes itself with jsonStringify, so its JSON is known only when the program runs; leave this value out of the document");
}

const testing = std.testing;
const http = @import("http");

/// `node` as compact JSON, as `ctx.response.json` writes: no whitespace.
fn compact(node: json.Node, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (node) {
        .object => |members| {
            try w.writeByte('{');
            for (members, 0..) |m, i| {
                if (i > 0) try w.writeByte(',');
                try std.json.Stringify.encodeJsonString(m.key, .{}, w);
                try w.writeByte(':');
                try compact(m.value, w);
            }
            try w.writeByte('}');
        },
        .array => |list| {
            try w.writeByte('[');
            for (list, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try compact(item, w);
            }
            try w.writeByte(']');
        },
        .string => |s| try std.json.Stringify.encodeJsonString(s, .{}, w),
        .raw => |text| try w.writeAll(text),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .null => try w.writeAll("null"),
    }
}

// Application code of the tests: the types of the values.
const Priority = enum { low, normal, high };
const Open = enum(u8) { a, b, _ };
const Line = struct {
    display_name: []const u8,
    done: bool = false,
    pub const field_rules = .{ .display_name = v.rename("displayName") };
};
const Shape = union(enum) {
    circle: struct {
        radius_mm: u32,
        pub const field_rules = .{ .radius_mm = v.rename("radiusMm") };
    },
    none,
};
const Every = struct {
    id: u64,
    delta: i8,
    ratio: f64,
    small: f32,
    nothing: f64,
    done: bool,
    priority: Priority,
    open: Open,
    title: []const u8,
    note: ?[]const u8,
    owner: ?Line,
    lines: []const Line,
    tags: [2][]const u8,
    code: [3]u8,
    pair: struct { u8, []const u8 },
    shapes: []const Shape,
    empty: void = {},
    comptime version: u32 = 2,

    pub const field_rules = .{ .delta = v.rename("deltaValue") };
};

const sample: Every = .{
    .id = 18446744073709551615,
    .delta = -3,
    .ratio = 0.1,
    .small = 0.1,
    .nothing = std.math.nan(f64),
    .done = true,
    .priority = .high,
    .open = @fromBackingInt(@intCast(7)),
    .title = "Buy \"milk\"\n\t\\ é 😀 \x01",
    .note = null,
    .owner = .{ .display_name = "Ann" },
    .lines = &.{ .{ .display_name = "a" }, .{ .display_name = "b", .done = true } },
    .tags = .{ "home", "shop" },
    .code = .{ 'a', 'b', 'c' },
    .pair = .{ 7, "seven" },
    .shapes = &.{ .{ .circle = .{ .radius_mm = 3 } }, .none },
};

const Problem = http.Problem;
const not_found: Problem = .{
    .title = "Not found",
    .status = 404,
    .code = "todos.not_found",
    .errors = &.{.{ .code = "validation.min", .message = "must be at least 1" }},
};

/// Answers with the values of the tests, each at its own path, as a
/// handler that writes JSON itself would.
const ValuesController = struct {
    pub const http_routes = http.routes(.{
        .methods = .{
            .every = http.get("/every", .{}),
            .number = http.get("/number", .{}),
            .list = http.get("/list", .{}),
            .missing = http.get("/missing", .{}),
        },
    });

    pub fn every(_: *ValuesController, ctx: *http.Context) !void {
        try ctx.response.json(sample);
    }
    pub fn number(_: *ValuesController, ctx: *http.Context) !void {
        try ctx.response.json(@as(f32, 1.5e-7));
    }
    pub fn list(_: *ValuesController, ctx: *http.Context) !void {
        try ctx.response.json(@as([]const ?Priority, &.{ .low, null }));
    }
    pub fn missing(_: *ValuesController, _: *http.Context) error{TodoNotFound}!void {
        return error.TodoNotFound;
    }
};

/// Maps the error of the tests to an `http.Problem`, whose null fields the
/// server leaves out.
const AppErrors = struct {
    pub fn mapError(err: anyerror) http.ErrorResponse(Problem) {
        return switch (err) {
            error.TodoNotFound => .{ .status = 404, .body = not_found },
            else => .fallback(err, .{ .title = http.defaultTitle(err), .status = http.defaultStatus(err), .code = http.defaultCode(err) }),
        };
    }
};

/// The body that the server answers `GET target` with.
fn bodyOf(backend: *http.testing.Backend, target: []const u8) ![]u8 {
    var res = try backend.request(testing.io, .{ .method = .GET, .target = target });
    defer res.deinit();
    return testing.allocator.dupe(u8, res.body);
}

fn expectSame(backend: *http.testing.Backend, target: []const u8, node: json.Node) !void {
    const body = try bodyOf(backend, target);
    defer testing.allocator.free(body);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try compact(node, &out.writer);
    try testing.expectEqualStrings(body, out.written());
}

test "value: the bytes of ctx.response.json and of an error's http.Problem" {
    var values: ValuesController = .{};
    var app_errors: AppErrors = .{};
    var backend: http.testing.Backend = .init(testing.allocator);
    defer backend.deinit();
    var server: http.Server = try .init(testing.allocator, .{ .backend = backend.backend(), .controllers = .{&values}, .error_handler = &app_errors });
    defer server.deinit(testing.io);
    try server.start(testing.io);

    try expectSame(&backend, "/every", comptime value(Every, sample, false, "every"));
    try expectSame(&backend, "/number", comptime value(f32, 1.5e-7, false, "number"));
    try expectSame(&backend, "/list", comptime value([]const ?Priority, &.{ .low, null }, false, "list"));
    // The body of an error: no detail, no instance, no field of a violation.
    try expectSame(&backend, "/missing", comptime value(Problem, not_found, true, "problem"));
}

test "value: the fields by their outside names; a problem leaves its null fields out" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try compact(comptime value(Line, .{ .display_name = "a" }, false, "line"), &out.writer);
    try testing.expectEqualStrings("{\"displayName\":\"a\",\"done\":false}", out.written());
    out.clearRetainingCapacity();
    try compact(comptime value(Problem, not_found, true, "problem"), &out.writer);
    try testing.expectEqualStrings("{\"type\":\"about:blank\",\"title\":\"Not found\",\"status\":404,\"code\":\"todos.not_found\",\"errors\":[{\"code\":\"validation.min\",\"message\":\"must be at least 1\"}]}", out.written());
    out.clearRetainingCapacity();
    try compact(comptime value(Problem, not_found, false, "problem"), &out.writer);
    try testing.expectEqualStrings("{\"type\":\"about:blank\",\"title\":\"Not found\",\"status\":404,\"detail\":null,\"instance\":null,\"code\":\"todos.not_found\",\"errors\":[{\"code\":\"validation.min\",\"message\":\"must be at least 1\",\"field\":null}]}", out.written());
}
