//! Compile-time checks of the fields a call logs: names and types. A
//! broken rule is a compile error at the call; nothing is checked at run
//! time.

const std = @import("std");
const redact = @import("redact.zig");
const isSensitive = @import("core").isSensitive;

/// The input field that carries the call site: `.src = @src()`.
pub const source_field = "src";

/// Keys the record writes itself, now or in later versions. A user field
/// with one of these names would collide with them.
const reserved = [_][]const u8{
    "timestamp",           "level",           "message",                     "service.name",
    "service.instance.id", "service.version", "deployment.environment.name", "scope",
    "source",              "trace_id",        "span_id",                     "truncated",
    "request_id",          "correlation_id",  "tenant_id",                   "pid",
    "thread_id",           "labels",          "suppressed",
};

/// Record keys that hold objects: their dotted subfields are reserved too.
const reserved_objects = [_][]const u8{ "source", "labels" };

/// Checks the fields of one call. Every level method calls it at compile
/// time, so the error points at the user's call.
pub fn check(comptime Fields: type) void {
    @setEvalBranchQuota(1_000_000);
    const info = switch (@typeInfo(Fields)) {
        .@"struct" => |s| s,
        else => @compileError("zefir.log: fields must be a struct literal such as .{ .user_id = id }, got '" ++ @typeName(Fields) ++ "'"),
    };
    if (info.is_tuple and info.field_names.len > 0)
        @compileError("zefir.log: fields need names: write .{ .user_id = id }, not .{ id }");
    inline for (info.field_names, info.field_types) |name, T| {
        checkName(name, name, true);
        if (comptime std.mem.eql(u8, name, source_field)) {
            if (T != std.lang.SourceLocation)
                @compileError("zefir.log: field 'src' is the call site and must be a std.lang.SourceLocation; pass .src = @src()");
        } else if (comptime !redact.isSensitiveName(name)) {
            if (T == void) @compileError("zefir.log: field '" ++ name ++ "': cannot log 'void'; remove the field");
            checkValue(name, T, true, &.{});
        }
    }
}

/// Checks one key: `name` is its own part, `path` the way to it from the
/// fields. `flat` paths reach it through objects only, so they are keys of
/// the record as a flat view sees it, and must not take a reserved name.
fn checkName(comptime path: []const u8, comptime name: []const u8, comptime flat: bool) void {
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.' and c != '-')
            @compileError("zefir.log: field name '" ++ path ++ "' may contain only [A-Za-z0-9_.-]");
    }
    if (!flat or !isReserved(path)) return;
    if (path.len == name.len)
        @compileError("zefir.log: field name '" ++ name ++ "' is reserved for record metadata; rename it, e.g. 'user_" ++ name ++ "'");
    const top = path[0 .. std.mem.findScalar(u8, path, '.') orelse path.len];
    @compileError("zefir.log: field '" ++ path ++ "' is reserved for record metadata; rename '" ++ top ++ "', e.g. 'user_" ++ top ++ "'");
}

fn isReserved(comptime path: []const u8) bool {
    for (reserved) |taken| {
        if (std.mem.eql(u8, path, taken)) return true;
    }
    for (reserved_objects) |object| {
        if (path.len > object.len and std.mem.startsWith(u8, path, object) and path[object.len] == '.') return true;
    }
    return false;
}

/// Checks a value of type `T` at `path`. `visited` holds the types on the
/// way to it, so a type that contains itself is checked once.
fn checkValue(comptime path: []const u8, comptime T: type, comptime flat: bool, comptime visited: []const type) void {
    // The same order as the encoder: marker, logValue, format, the rest.
    if (redactsWhole(T)) return;
    for (visited) |seen| {
        if (seen == T) return;
    }
    const next = visited ++ [_]type{T};
    if (LogValue(T)) |R| return checkValue(path, R, flat, next);
    if (hasFormat(T) or isString(T)) return;
    switch (@typeInfo(T)) {
        .bool, .int, .float, .comptime_int, .comptime_float, .@"enum", .enum_literal, .error_set, .null, .type => {},
        .optional => |o| checkValue(path, o.child, flat, next),
        .error_union => @compileError("zefir.log: field '" ++ path ++ "': cannot log error union '" ++ @typeName(T) ++ "'; handle it with try or catch first, then log the payload or the error"),
        .pointer => |p| switch (p.size) {
            .one => switch (@typeInfo(p.child)) {
                .@"opaque" => @compileError("zefir.log: field '" ++ path ++ "': cannot log '" ++ @typeName(T) ++ "': an opaque type has no value to log"),
                .@"fn" => @compileError("zefir.log: field '" ++ path ++ "': cannot log function '" ++ @typeName(T) ++ "'"),
                else => checkValue(path, p.child, flat, next),
            },
            .slice => checkValue(path ++ "[]", p.child, false, next),
            .many => @compileError("zefir.log: field '" ++ path ++ "': cannot log many-item pointer '" ++ @typeName(T) ++ "': it has no length; log a slice, ptr[0..len]"),
            .c => @compileError("zefir.log: field '" ++ path ++ "': cannot log C pointer '" ++ @typeName(T) ++ "'; convert it to a slice or log the address as an integer"),
        },
        .array => |a| checkValue(path ++ "[]", a.child, false, next),
        .vector => |v| checkValue(path ++ "[]", v.child, false, next),
        .@"struct" => |s| if (s.is_tuple) {
            inline for (s.field_types) |Item| checkValue(path ++ "[]", Item, false, next);
        } else {
            inline for (s.field_names, s.field_types) |name, Field| {
                if (Field == void) continue;
                checkName(path ++ "." ++ name, name, flat);
                if (comptime !redact.isSensitiveName(name)) checkValue(path ++ "." ++ name, Field, flat, next);
            }
        },
        .@"union" => |u| {
            if (u.tag_type == null)
                @compileError("zefir.log: field '" ++ path ++ "': cannot log untagged union '" ++ @typeName(T) ++ "': its active field is unknown; use union(enum) or log one of its fields");
            inline for (u.field_names, u.field_types) |name, Payload| {
                checkName(path ++ "." ++ name, name, flat);
                if (Payload != void and comptime !redact.isSensitiveName(name)) checkValue(path ++ "." ++ name, Payload, flat, next);
            }
        },
        .@"fn" => @compileError("zefir.log: field '" ++ path ++ "': cannot log function '" ++ @typeName(T) ++ "'"),
        else => @compileError("zefir.log: cannot log type '" ++ @typeName(T) ++ "' in field '" ++ path ++ "'; give it a format or logValue method, or log one of its fields"),
    }
}

fn isContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
}

/// Whether a value of `T` is written as one "[REDACTED]": a type marked
/// `pub const zefir_sensitive = true;`, or an optional, pointer, slice or
/// array around one. One placeholder tells neither presence nor count.
pub fn redactsWhole(comptime T: type) bool {
    if (isSensitive(T)) return true;
    return switch (@typeInfo(T)) {
        .optional => |o| redactsWhole(o.child),
        .pointer => |p| redactsWhole(p.child),
        .array => |a| redactsWhole(a.child),
        .vector => |v| redactsWhole(v.child),
        else => false,
    };
}

/// The method `name` of `T` if its first parameter is `T` or `*const T`.
fn method(comptime T: type, comptime name: []const u8) ?std.lang.Type.Fn {
    if (!isContainer(T) or !@hasDecl(T, name)) return null;
    const info = switch (@typeInfo(@TypeOf(@field(T, name)))) {
        .@"fn" => |f| f,
        else => return null,
    };
    if (info.param_types.len == 0) return null;
    const Self = info.param_types[0] orelse return null;
    return if (Self == T or Self == *const T) info else null;
}

/// Whether `T` has the method that `{f}` uses:
/// `pub fn format(self, w: *std.Io.Writer) std.Io.Writer.Error!void`. Its
/// output is logged as a string.
pub fn hasFormat(comptime T: type) bool {
    const f = method(T, "format") orelse return false;
    return f.param_types.len == 2 and f.param_types[1] == *std.Io.Writer and
        f.return_type == std.Io.Writer.Error!void;
}

/// The type `T.logValue(self)` returns, when `T` has that method: the
/// logger writes what it returns in place of the value.
pub fn LogValue(comptime T: type) ?type {
    const f = method(T, "logValue") orelse return null;
    if (f.param_types.len != 1) return null;
    const R = f.return_type orelse return null;
    if (R == T) @compileError("zefir.log: " ++ @typeName(T) ++ ".logValue must return another type, not " ++ @typeName(T) ++ " itself");
    return R;
}

/// Whether `T` is written as a string: a slice or array of bytes, or a
/// pointer to one.
pub fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .array => |a| a.child == u8,
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            .many => p.child == u8 and p.sentinel() != null,
            .c => false,
        },
        else => false,
    };
}

test "scalars, strings, optionals, enums, errors and the call site pass" {
    const Status = enum { active, banned };
    var id: u64 = 1;
    var text: []const u8 = "x";
    var maybe: ?i32 = null;
    var status: Status = .active;
    _ = &id;
    _ = &text;
    _ = &maybe;
    _ = &status;
    comptime check(@TypeOf(.{}));
    comptime check(@TypeOf(.{ .ok = true, .count = 3, .ratio = 0.5, .note = "x", .kind = .admin, .none = null, .failure = error.Boom }));
    comptime check(@TypeOf(.{ .id = id, .text = text, .maybe = maybe, .status = status, .src = @src() }));
    comptime check(@TypeOf(.{ .@"http.method" = "GET", .@"user-agent" = "curl" }));
}

test "a named struct of scalars passes as the fields" {
    const Request = struct { method: []const u8, status: u16 };
    comptime check(Request);
}

test "a field named like a secret is not type-checked: it is never written" {
    const Raw = struct { ptr: [*]const u8, len: usize };
    var raw: Raw = .{ .ptr = "x", .len = 1 };
    _ = &raw;
    comptime check(@TypeOf(.{ .password = raw }));
}

test "isString: byte slices, byte arrays and pointers to them" {
    try std.testing.expect(isString([]const u8));
    try std.testing.expect(isString([]u8));
    try std.testing.expect(isString([:0]const u8));
    try std.testing.expect(isString(*const [3:0]u8));
    try std.testing.expect(isString(*[4]u8));
    try std.testing.expect(isString([4]u8));
    try std.testing.expect(isString([*:0]const u8));
    try std.testing.expect(!isString([*]const u8));
    try std.testing.expect(!isString([]const u16));
    try std.testing.expect(!isString(*const u8));
    try std.testing.expect(!isString(u8));
}

test "nested values pass: structs, unions, arrays, slices, pointers, optionals and types" {
    const Mode = enum { a, b };
    const Inner = struct { host: []const u8, port: u16, mode: Mode };
    const State = union(enum) { idle, running: u32 };
    const Config = struct {
        name: []const u8,
        db: Inner,
        state: State,
        tags: []const []const u8,
        ports: [2]u16,
        maybe: ?*const Inner,
        nothing: void,
    };
    comptime check(@TypeOf(.{ .config = @as(Config, undefined) }));
    comptime check(@TypeOf(.{ .ty = u8, .tuple = .{ 1, "two" }, .vec = @as(@Vector(2, u8), .{ 1, 2 }) }));
    comptime check(@TypeOf(.{ .flags = @as(packed struct { a: bool, b: u3 }, undefined) }));
}

test "recursive types pass" {
    const Node = struct { value: u32, next: ?*const @This() };
    comptime check(@TypeOf(.{ .head = @as(Node, undefined) }));
}

test "types with format or logValue pass, whatever their fields" {
    const Raw = struct {
        ptr: [*]const u8,
        pub fn format(_: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.writeAll("raw");
        }
    };
    const User = struct {
        id: u64,
        password_hash: [*]const u8,
        pub fn logValue(u: @This()) struct { id: u64 } {
            return .{ .id = u.id };
        }
    };
    comptime check(@TypeOf(.{ .raw = @as(Raw, undefined), .user = @as(User, undefined) }));
}

test "marked types and wrappers around them pass: they are never written" {
    const Secret = struct {
        ptr: [*]const u8,
        len: usize,
        pub const zefir_sensitive = true;
    };
    comptime check(@TypeOf(.{
        .a = @as(Secret, undefined),
        .b = @as(?Secret, null),
        .c = @as([]const Secret, &.{}),
        .d = @as([2]Secret, undefined),
        .e = @as(*const Secret, undefined),
    }));
    try std.testing.expect(redactsWhole(?*const [2]Secret));
    try std.testing.expect(!redactsWhole(struct { s: Secret }));
}

test "a nested field named like a secret is not type-checked either" {
    const Db = struct { password: [*]const u8, host: []const u8 };
    comptime check(@TypeOf(.{ .db = @as(Db, undefined) }));
}

test "format and logValue count only with the signatures zefir.log calls" {
    const ByValue = struct {
        pub fn format(_: @This(), _: *std.Io.Writer) std.Io.Writer.Error!void {}
    };
    const ByPointer = struct {
        pub fn format(_: *const @This(), _: *std.Io.Writer) std.Io.Writer.Error!void {}
    };
    const OtherFormat = struct {
        pub fn format(_: @This(), _: []const u8) void {}
    };
    const Valued = struct {
        pub fn logValue(_: @This()) u32 {
            return 1;
        }
    };
    try std.testing.expect(hasFormat(ByValue));
    try std.testing.expect(hasFormat(ByPointer));
    try std.testing.expect(!hasFormat(OtherFormat));
    try std.testing.expect(!hasFormat(u8));
    try std.testing.expect(LogValue(Valued).? == u32);
    try std.testing.expect(LogValue(ByValue) == null);
}
