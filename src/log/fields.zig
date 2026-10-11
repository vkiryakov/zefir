//! Compile-time checks of the fields a call logs: names and types. A
//! broken rule is a compile error at the call; nothing is checked at run
//! time.

const std = @import("std");
const redact = @import("redact.zig");

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
    @setEvalBranchQuota(100_000);
    const info = switch (@typeInfo(Fields)) {
        .@"struct" => |s| s,
        else => @compileError("zefir.log: fields must be a struct literal such as .{ .user_id = id }, got '" ++ @typeName(Fields) ++ "'"),
    };
    if (info.is_tuple and info.field_names.len > 0)
        @compileError("zefir.log: fields need names: write .{ .user_id = id }, not .{ id }");
    inline for (info.field_names, info.field_types) |name, T| {
        checkName(name);
        if (comptime std.mem.eql(u8, name, source_field)) {
            if (T != std.lang.SourceLocation)
                @compileError("zefir.log: field 'src' is the call site and must be a std.lang.SourceLocation; pass .src = @src()");
        } else if (comptime !redact.isSensitiveName(name)) {
            checkValue(name, T);
        }
    }
}

fn checkName(comptime name: []const u8) void {
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.' and c != '-')
            @compileError("zefir.log: field name '" ++ name ++ "' may contain only [A-Za-z0-9_.-]");
    }
    if (isReserved(name))
        @compileError("zefir.log: field name '" ++ name ++ "' is reserved for record metadata; rename it, e.g. 'user_" ++ name ++ "'");
}

fn isReserved(comptime name: []const u8) bool {
    for (reserved) |taken| {
        if (std.mem.eql(u8, name, taken)) return true;
    }
    for (reserved_objects) |object| {
        if (name.len > object.len and std.mem.startsWith(u8, name, object) and name[object.len] == '.') return true;
    }
    return false;
}

/// The value types this version writes: scalars, strings and optionals of
/// them.
fn checkValue(comptime name: []const u8, comptime T: type) void {
    switch (@typeInfo(T)) {
        .bool, .int, .float, .comptime_int, .comptime_float, .@"enum", .enum_literal, .error_set, .null => {},
        .optional => |o| checkValue(name, o.child),
        .pointer, .array => if (!isString(T)) unsupported(name, T),
        .error_union => @compileError("zefir.log: field '" ++ name ++ "': cannot log error union '" ++ @typeName(T) ++ "'; handle it with try or catch first, then log the payload or the error"),
        .void => @compileError("zefir.log: field '" ++ name ++ "': cannot log 'void'; remove the field"),
        else => unsupported(name, T),
    }
}

fn unsupported(comptime name: []const u8, comptime T: type) noreturn {
    @compileError("zefir.log: cannot log type '" ++ @typeName(T) ++ "' in field '" ++ name ++ "'; log scalars and strings, e.g. .{ .user_id = user.id }");
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
