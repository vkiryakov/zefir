//! The small helpers of zefir.App's comptime code: the eval branch quota,
//! the names of types in labels and in compile errors, and type predicates.
const std = @import("std");

/// The eval branch quota App sets in each of its comptime steps, so that an
/// application sets none: about 30 times what an application of 50 modules,
/// 1000 providers and 500 controllers needs.
pub const eval_quota = 20_000_000;

/// "zefir.App(Root): ", the start of each of App's compile errors.
pub fn pre(comptime Root: type) []const u8 {
    return "zefir.App(" ++ name(Root) ++ "): ";
}

/// The last part of a type's name: a module or a bean in a label
/// (`UsersModule`, `UserService`, `Generator`).
pub fn name(comptime T: type) []const u8 {
    const full = @typeName(T);
    return full[lastPart(full)..];
}

/// A type as App's compile errors write it, as short as it stays clear:
/// pointers, optionals, slices, arrays and tuples by their parts, and any
/// other type by its last name with the types it is nested in
/// (`*const Config`, `Cache.Options`, `struct { u8, u8 }`).
pub fn typeName(comptime T: type) []const u8 {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            const kind = switch (p.size) {
                .one => "*",
                .many => "[*]",
                .slice => "[]",
                .c => "[*c]",
            };
            return kind ++ (if (p.attrs.@"const") "const " else "") ++ typeName(p.child);
        },
        .optional => |o| return "?" ++ typeName(o.child),
        .array => |a| return "[" ++ num(a.len) ++ "]" ++ typeName(a.child),
        .@"struct" => |s| if (s.is_tuple) {
            if (s.field_types.len == 0) return "struct {}";
            var out: []const u8 = "struct {";
            for (s.field_types, 0..) |F, k| out = out ++ (if (k == 0) " " else ", ") ++ typeName(F);
            return out ++ " }";
        },
        else => {},
    }
    const full = @typeName(T);
    var start = lastPart(full);
    // The types T is nested in: the parts before it that name a type.
    while (start > 0) {
        const before = lastPart(full[0 .. start - 1]);
        if (!isTypeName(full[before .. start - 1])) break;
        start = before;
    }
    return full[start..];
}

/// Where the last part of a type's name starts: after its last dot outside
/// brackets and quotes, so that `mocks.Server("a.b")` ends in `Server("a.b")`.
fn lastPart(comptime full: []const u8) usize {
    var depth: usize = 0;
    var quoted = false;
    var start: usize = 0;
    for (full, 0..) |c, k| {
        if (quoted) {
            if (c == '"' and full[k - 1] != '\\') quoted = false;
            continue;
        }
        switch (c) {
            '"' => quoted = true,
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            '.' => if (depth == 0) {
                start = k + 1;
            },
            else => {},
        }
    }
    return start;
}

/// An identifier that starts with an uppercase letter: a type, by the
/// naming of Zig code, rather than a file or a namespace.
fn isTypeName(comptime part: []const u8) bool {
    if (part.len == 0 or !std.ascii.isUpper(part[0])) return false;
    for (part) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// "A, B, C": the types of a list as messages write them.
pub fn typeList(comptime list: []const type) []const u8 {
    if (list.len == 0) return "nothing";
    var out: []const u8 = typeName(list[0]);
    for (list[1..]) |T| out = out ++ ", " ++ typeName(T);
    return out;
}

/// "A -> B -> C": a path of modules.
pub fn chain(comptime path: []const type) []const u8 {
    var out: []const u8 = name(path[0]);
    for (path[1..]) |T| out = out ++ " -> " ++ name(T);
    return out;
}

pub fn num(comptime k: usize) []const u8 {
    return std.fmt.comptimePrint("{d}", .{k});
}

pub fn fieldsOf(comptime T: type) std.lang.Type.Struct {
    return @typeInfo(T).@"struct";
}

pub fn isPlainStruct(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and !@typeInfo(T).@"struct".is_tuple;
}

pub fn isTuple(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple;
}

pub fn isContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
}

/// Whether T declares `pub const module`, as a module does.
pub fn isModule(comptime T: type) bool {
    return isContainer(T) and @hasDecl(T, "module");
}

/// A single pointer to data (not to a function or an opaque type).
pub fn dataPointer(comptime T: type) ?std.lang.Type.Pointer {
    if (@typeInfo(T) != .pointer) return null;
    const ptr = @typeInfo(T).pointer;
    if (ptr.size != .one or @typeInfo(ptr.child) == .@"fn" or @typeInfo(ptr.child) == .@"opaque") return null;
    return ptr;
}

pub fn hasInitFn(comptime T: type) bool {
    return isContainer(T) and @hasDecl(T, "init") and @typeInfo(@TypeOf(T.init)) == .@"fn";
}

/// T of `T` or `E!T`.
pub fn Payload(comptime R: type) type {
    return if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.payload else R;
}

pub fn contains(comptime list: []const type, comptime T: type) bool {
    return indexOfType(list, T) != null;
}

pub fn indexOfType(comptime list: []const type, comptime T: type) ?usize {
    for (list, 0..) |X, i| if (X == T) return i;
    return null;
}

test "the short names of types" {
    const Outer = struct {
        pub const Options = struct { a: u8 = 0 };
    };
    try std.testing.expectEqualStrings("Outer", comptime name(Outer));
    try std.testing.expectEqualStrings("Options", comptime name(Outer.Options));
    try std.testing.expectEqualStrings("Outer.Options", comptime typeName(Outer.Options));
    try std.testing.expectEqualStrings("*const Outer.Options", comptime typeName(*const Outer.Options));
    try std.testing.expectEqualStrings("?*Outer", comptime typeName(?*Outer));
    try std.testing.expectEqualStrings("[]const u8", comptime typeName([]const u8));
    try std.testing.expectEqualStrings("struct { u8, *Outer }", comptime typeName(struct { u8, *Outer }));
    try std.testing.expectEqualStrings("u32", comptime typeName(u32));
    try std.testing.expectEqualStrings("Io.Writer", comptime typeName(std.Io.Writer));
    // The dot inside the argument does not end the name.
    try std.testing.expectStringStartsWith(comptime name(Server("a.b")), "Server(\"a.b\"");
}

fn Server(comptime what: []const u8) type {
    return struct {
        pub const label = what;
    };
}
