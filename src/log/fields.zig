//! Compile-time checks of the fields a call logs: names and types. A
//! broken rule is a compile error at the call; nothing is checked at run
//! time.

const std = @import("std");
const redact = @import("redact.zig");
const isSensitive = @import("core").isSensitive;
const Context = @import("core").Context;

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
/// `src` stands for the call site, which text writes as `src.function`
/// and `src.module`.
const reserved_objects = [_][]const u8{ "source", "labels", "src" };

/// Checks the fields of one call. Every level method calls it at compile
/// time, so the first "referenced by" line under the error is the user's
/// call.
pub fn check(comptime Fields: type) void {
    @setEvalBranchQuota(1_000_000);
    const info = switch (@typeInfo(Fields)) {
        .@"struct" => |s| s,
        else => @compileError("zefir.log: fields must be a struct literal such as .{ .user_id = id }, got '" ++ @typeName(Fields) ++ "'"),
    };
    if (info.is_tuple and info.field_names.len > 0)
        @compileError("zefir.log: fields need names: write .{ .user_id = id }, not .{ id }");
    checkMarker("", Fields);
    // A value with its own logged form would lose it as the fields: its
    // members would be written one by one.
    if (redactsWhole(Fields))
        @compileError("zefir.log: '" ++ @typeName(Fields) ++ "' is sensitive and cannot be the fields; log it as one field: .{ .key = key }");
    if (LogValue(Fields) != null or hasFormat(Fields))
        @compileError("zefir.log: '" ++ @typeName(Fields) ++ "' has its own logged form; log it as one field: .{ .value = value }");
    if (Fields == Context)
        @compileError("zefir.log: a core.Context is not the fields; bind it with logger.withContext(ctx)");
    inline for (info.field_names, info.field_types) |name, T| {
        // Records write the call site as "source", so this name is a likely
        // slip for `.src`.
        if (T == std.lang.SourceLocation and comptime std.mem.eql(u8, name, "source"))
            @compileError("zefir.log: field name 'source' is reserved for record metadata; the call site goes in .src = @src()");
        checkName(name, name);
        if (comptime std.mem.eql(u8, name, source_field)) {
            if (T != std.lang.SourceLocation)
                @compileError("zefir.log: field 'src' is the call site and must be a std.lang.SourceLocation; pass .src = @src()");
        } else if (comptime !redact.isSensitiveName(name)) {
            checkValue(name, T, &.{});
        }
    }
}

/// Checks one key: `name` is its own part, `path` the way to it from the
/// fields, with `[]` for the items of an array. The path without the `[]`
/// is the key a flat view of the record shows (search engines flatten
/// arrays of objects too), so it must not take a reserved name.
fn checkName(comptime path: []const u8, comptime name: []const u8) void {
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.' and c != '-')
            @compileError("zefir.log: field name '" ++ path ++ "' may contain only [A-Za-z0-9_.-]");
    }
    const flat = comptime flatPath(path);
    if (!isReserved(flat)) return;
    if (path.len == name.len)
        @compileError("zefir.log: field name '" ++ name ++ "' is reserved for record metadata; rename it, e.g. 'user_" ++ name ++ "'");
    const top = flat[0 .. std.mem.findScalar(u8, flat, '.') orelse flat.len];
    @compileError("zefir.log: field '" ++ path ++ "' is reserved for record metadata; rename '" ++ top ++ "', e.g. 'user_" ++ top ++ "'");
}

/// `path` without its `[]` marks.
fn flatPath(comptime path: []const u8) []const u8 {
    var flat: []const u8 = "";
    var rest = path;
    while (std.mem.find(u8, rest, "[]")) |i| {
        flat = flat ++ rest[0..i];
        rest = rest[i + 2 ..];
    }
    return flat ++ rest;
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
fn checkValue(comptime path: []const u8, comptime T: type, comptime visited: []const type) void {
    // The same order as the encoder: marker, logValue, format, the rest.
    const where = "field '" ++ path ++ "': ";
    checkMarker(where, T);
    if (redactsWhole(T)) return;
    if (T == Context)
        @compileError("zefir.log: field '" ++ path ++ "': bind a core.Context with logger.withContext(ctx), not as a field");
    for (visited) |seen| {
        if (seen == T) return;
    }
    const next = visited ++ [_]type{T};
    if (logValueAt(where, T)) |R| return checkValue(path, R, next);
    if (formatAt(where, T) or isString(T)) return;
    switch (@typeInfo(T)) {
        .bool, .int, .float, .comptime_int, .comptime_float, .@"enum", .enum_literal, .error_set, .null, .type => {},
        .optional => |o| checkValue(path, o.child, next),
        .error_union => @compileError("zefir.log: field '" ++ path ++ "': cannot log error union '" ++ @typeName(T) ++ "'; handle it with try or catch first, then log the payload or the error"),
        .void => @compileError("zefir.log: field '" ++ path ++ "': cannot log 'void'; remove the field"),
        .pointer => |p| switch (p.size) {
            .one => switch (@typeInfo(p.child)) {
                // An opaque type has no value of its own, but its methods
                // take the pointer.
                .@"opaque" => if (logValueAt(where, p.child)) |R|
                    checkValue(path, R, next)
                else if (!formatAt(where, p.child))
                    @compileError("zefir.log: field '" ++ path ++ "': cannot log '" ++ @typeName(T) ++ "': an opaque type has no value to log"),
                .@"fn" => @compileError("zefir.log: field '" ++ path ++ "': cannot log function '" ++ @typeName(T) ++ "'"),
                else => checkValue(path, p.child, next),
            },
            .slice => checkValue(path ++ "[]", p.child, next),
            .many => @compileError("zefir.log: field '" ++ path ++ "': cannot log many-item pointer '" ++ @typeName(T) ++ "': it has no length; log a slice, ptr[0..len]"),
            .c => @compileError("zefir.log: field '" ++ path ++ "': cannot log C pointer '" ++ @typeName(T) ++ "'; convert it to a slice or log the address as an integer"),
        },
        .array => |a| checkValue(path ++ "[]", a.child, next),
        .vector => |v| checkValue(path ++ "[]", v.child, next),
        .@"struct" => |s| if (s.is_tuple) {
            inline for (s.field_types) |Item| checkValue(path ++ "[]", Item, next);
        } else {
            inline for (s.field_names, s.field_types) |name, Field| {
                if (Field == void) continue;
                checkName(path ++ "." ++ name, name);
                if (comptime !redact.isSensitiveName(name)) checkValue(path ++ "." ++ name, Field, next);
            }
        },
        .@"union" => |u| {
            if (u.tag_type == null)
                @compileError("zefir.log: field '" ++ path ++ "': cannot log untagged union '" ++ @typeName(T) ++ "': its active field is unknown; use union(enum) or log one of its fields");
            inline for (u.field_names, u.field_types) |name, Payload| {
                checkName(path ++ "." ++ name, name);
                if (Payload != void and comptime !redact.isSensitiveName(name)) checkValue(path ++ "." ++ name, Payload, next);
            }
        },
        .@"fn" => @compileError("zefir.log: field '" ++ path ++ "': cannot log function '" ++ @typeName(T) ++ "'"),
        .undefined => @compileError("zefir.log: field '" ++ path ++ "' is undefined; give it a value"),
        else => @compileError("zefir.log: field '" ++ path ++ "': cannot log '" ++ @typeName(T) ++ "'"),
    }
}

/// A marker that is not a bool is an error at the field that holds it,
/// also inside an optional, a pointer, a slice or an array.
fn checkMarker(comptime where: []const u8, comptime T: type) void {
    switch (@typeInfo(T)) {
        .optional => |o| checkMarker(where, o.child),
        .pointer => |p| checkMarker(where, p.child),
        .array => |a| checkMarker(where, a.child),
        .vector => |v| checkMarker(where, v.child),
        .@"struct", .@"union", .@"enum", .@"opaque" => if (@hasDecl(T, "zefir_sensitive") and @TypeOf(T.zefir_sensitive) != bool)
            @compileError("zefir.log: " ++ where ++ "'" ++ @typeName(T) ++ ".zefir_sensitive' must be a bool: pub const zefir_sensitive = true;"),
        else => {},
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

/// The function `name` that `T` declares; null when it declares none, or
/// something else under that name. The callers check its form: a method
/// of another form is a compile error, never a fallback to the fields.
fn method(comptime T: type, comptime name: []const u8) ?std.lang.Type.Fn {
    if (!isContainer(T) or !@hasDecl(T, name)) return null;
    return switch (@typeInfo(@TypeOf(@field(T, name)))) {
        .@"fn" => |f| f,
        else => null,
    };
}

/// The `self` a hint shows: an opaque type is reached through a pointer.
fn selfHint(comptime T: type) []const u8 {
    return if (@typeInfo(T) == .@"opaque") "*const @This()" else "@This()";
}

/// Whether `f` takes self the way the encoder passes it: by value, by
/// `*const` or as `anytype`.
fn selfOk(comptime T: type, comptime f: std.lang.Type.Fn) bool {
    if (f.param_types.len == 0) return false;
    const Self = f.param_types[0] orelse return true;
    return Self == T or Self == *const T;
}

/// Whether `T` has the method that `{f}` uses,
/// `pub fn format(self: @This(), w: *std.Io.Writer) !void`, with self by
/// value or by `*const` and no errors but `std.Io.Writer.Error`, declared
/// or inferred; its output is logged as a string. A `format` of another
/// form is a compile error rather than a fallback to the fields, which the
/// method may have meant to hide.
pub fn hasFormat(comptime T: type) bool {
    return comptime formatAt("", T);
}

/// `hasFormat`, with `where` (the field) in front of its errors.
fn formatAt(comptime where: []const u8, comptime T: type) bool {
    const f = method(T, "format") orelse return false;
    const name = "'" ++ @typeName(T) ++ ".format'";
    // An opaque type has no value to take by value.
    const hint = "write pub fn format(self: " ++ selfHint(T) ++ ", w: *std.Io.Writer) !void";
    const writer_ok = f.param_types.len == 2 and (f.param_types[1] == null or f.param_types[1].? == *std.Io.Writer);
    if (!selfOk(T, f) or !writer_ok)
        @compileError("zefir.log: " ++ where ++ name ++ " has another form than the one {f} uses; " ++ hint);
    // The type of the call the encoder makes: the errors of a generic
    // writer are known only then. An opaque type is called through a
    // pointer.
    const Result = if (@typeInfo(T) == .@"opaque")
        @TypeOf(@as(*const T, undefined).format(@as(*std.Io.Writer, undefined)))
    else
        @TypeOf(@as(T, undefined).format(@as(*std.Io.Writer, undefined)));
    switch (@typeInfo(Result)) {
        .void => @compileError("zefir.log: " ++ where ++ name ++ " returns void; " ++ hint),
        .error_union => |e| if (e.payload == void) {
            const errors = @typeInfo(e.error_set).error_set.error_names orelse
                @compileError("zefir.log: " ++ where ++ name ++ " returns anyerror; {f} lets it return only std.Io.Writer.Error");
            for (errors) |error_name| {
                if (!std.mem.eql(u8, error_name, "WriteFailed"))
                    @compileError("zefir.log: " ++ where ++ name ++ " can return error." ++ error_name ++ "; {f} lets it return only std.Io.Writer.Error");
            }
            return true;
        },
        else => {},
    }
    @compileError("zefir.log: " ++ where ++ name ++ " has another form than the one {f} uses; " ++ hint);
}

/// The type `T.logValue(self)` returns, when `T` has that method: the
/// logger writes what it returns in place of the value. A `logValue` of
/// another form is a compile error, as for `format`.
pub fn LogValue(comptime T: type) ?type {
    return logValueAt("", T);
}

/// `LogValue`, with `where` (the field) in front of its errors.
fn logValueAt(comptime where: []const u8, comptime T: type) ?type {
    const f = method(T, "logValue") orelse return null;
    const name = "'" ++ @typeName(T) ++ ".logValue'";
    if (!selfOk(T, f) or f.param_types.len != 1 or f.return_type == null) @compileError("zefir.log: " ++ where ++ name ++ " has another form; write pub fn logValue(self: " ++ selfHint(T) ++
        ") U, taking self " ++ (if (@typeInfo(T) == .@"opaque") "by *const" else "by value or by *const"));
    const R = f.return_type.?;
    if (R == T) @compileError("zefir.log: " ++ where ++ name ++ " returns '" ++ @typeName(T) ++ "' itself; return another type, such as a struct of the fields to log");
    if (@typeInfo(R) == .error_union)
        @compileError("zefir.log: " ++ where ++ name ++ " returns an error union; return a value, since logging cannot fail");
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

test "service names other than the record's own pass" {
    comptime check(@TypeOf(.{ .service = "x" }));
    comptime check(@TypeOf(.{ .service = .{ .region = "eu" } }));
    comptime check(@TypeOf(.{ .@"service.namespace" = "billing" }));
}

test "every key the record writes is reserved, and names close to them are not" {
    @setEvalBranchQuota(100_000);
    inline for (.{
        "timestamp",                   "level",          "message",    "service.name", "service.instance.id", "service.version",
        "deployment.environment.name", "scope",          "source",     "trace_id",     "span_id",             "truncated",
        "request_id",                  "correlation_id", "tenant_id",  "pid",          "thread_id",           "labels",
        "suppressed",                  "source.file",    "labels.env", "src.function", "src.module",
    }) |name| try std.testing.expect(comptime isReserved(name));
    inline for (.{ "service", "service.namespace", "levels", "trace", "src", "sources", "label", "trace_id_x" }) |name|
        try std.testing.expect(comptime !isReserved(name));
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
    const AnyErrors = struct {
        pub fn format(_: @This(), _: *std.Io.Writer) !void {}
    };
    const AnyWriter = struct {
        pub fn format(_: @This(), _: anytype) !void {}
    };
    const NotAMethod = struct {
        pub const format = "json";
    };
    const Valued = struct {
        pub fn logValue(_: @This()) u32 {
            return 1;
        }
    };
    try std.testing.expect(hasFormat(ByValue));
    try std.testing.expect(hasFormat(ByPointer));
    try std.testing.expect(hasFormat(AnyErrors));
    try std.testing.expect(hasFormat(AnyWriter));
    try std.testing.expect(!hasFormat(NotAMethod));
    try std.testing.expect(!hasFormat(u8));
    try std.testing.expect(LogValue(Valued).? == u32);
    try std.testing.expect(LogValue(ByValue) == null);
}
