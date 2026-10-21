//! The claims of a token. The application describes its own claims as a
//! struct, `Claims`, which `verify` fills from the payload and `sign`
//! writes into it; the registered claims of RFC 7519 §4.1 ("iss", "sub",
//! "aud", "exp", "nbf", "iat", "jti") are jwt's own, in `jwt.Registered`,
//! and the struct never names them at its top level.
//!
//! | Field        | From JSON                                    |
//! |--------------|----------------------------------------------|
//! | `bool`       | `true`, `false`                              |
//! | an integer   | a number without a fraction or an exponent   |
//! | `f32`, `f64` | a number, finite                             |
//! | an enum      | a string, the name of a variant              |
//! | `[]const u8` | a string                                     |
//! | `[]const T`  | an array                                     |
//! | `?T`         | `null`, or the claim absent                  |
//! | a struct     | an object, with its own names and rules      |
//!
//! A claim's name is its entry in `pub const claim_names`, such as
//! `.{ .is_root = "http://example.com/is_root" }`, or else the outside name
//! of zefir-validator: `v.rename("userName")` or the Zig name. A type the
//! table does not have, a claims type that contains itself, and a name
//! that is empty, given twice or registered stop the build with a message
//! that starts with `jwt: `.

const std = @import("std");
const v = @import("validator");

/// The registered claims (RFC 7519 §4.1), which jwt sets and checks itself.
pub const registered_names = [_][]const u8{ "iss", "sub", "aud", "exp", "nbf", "iat", "jti" };

/// The name of the claim that `field` of `T` holds: its entry in
/// `T.claim_names`, or else its outside name for zefir-validator.
pub fn nameOf(comptime T: type, comptime field: std.meta.FieldEnum(T)) []const u8 {
    comptime {
        if (claimName(T, @tagName(field))) |name| return name;
        return v.nameOf(T, field);
    }
}

/// Stops the build when `Claims` cannot be the claims of `verify` and
/// `sign`: when it is not `void` or a struct of the types of the table,
/// when it contains itself, or when its names are wrong.
pub fn check(comptime Claims: type) void {
    comptime {
        @setEvalBranchQuota(100_000);
        if (Claims == void) return;
        if (isPlainStruct(Claims)) return checkStruct(Claims, @typeName(Claims), true, &.{});
        @compileError("jwt: " ++ @typeName(Claims) ++ ": claims are a struct, or void when jwt.Registered is enough");
    }
}

fn checkStruct(comptime S: type, comptime label: []const u8, comptime top: bool, comptime outer: []const type) void {
    const info = @typeInfo(S).@"struct";
    if (@hasDecl(S, "claim_names")) {
        const Names = @TypeOf(S.claim_names);
        if (!isPlainStruct(Names))
            @compileError("jwt: " ++ label ++ ".claim_names: write .{ .field = \"name\" }, such as .{ .is_root = \"http://example.com/is_root\" }");
        for (@typeInfo(Names).@"struct".field_names) |entry| {
            if (!@hasField(S, entry)) @compileError("jwt: " ++ label ++ ".claim_names." ++ entry ++ ": " ++ label ++ " has no field " ++ entry);
            const name = asName(@field(S.claim_names, entry));
            if (name == null or name.?.len == 0 or !std.unicode.utf8ValidateSlice(name.?))
                @compileError("jwt: " ++ label ++ ".claim_names." ++ entry ++ ": a claim name is a non-empty string of UTF-8, such as \"https://shop.example.com/" ++ entry ++ "\"");
            if (!std.mem.eql(u8, v.nameOf(S, @field(std.meta.FieldEnum(S), entry)), entry))
                @compileError("jwt: " ++ label ++ "." ++ entry ++ ": both claim_names and v.rename name the field; keep one of them");
        }
    }
    for (info.field_names, info.field_attrs, 0..) |field, attrs, i| {
        if (attrs.@"comptime") continue;
        const name = nameOf(S, @field(std.meta.FieldEnum(S), field));
        if (!std.unicode.utf8ValidateSlice(name))
            @compileError("jwt: " ++ label ++ "." ++ field ++ ": a claim name is a non-empty string of UTF-8; name the field in claim_names");
        if (top and isRegistered(name))
            @compileError("jwt: " ++ label ++ "." ++ field ++ ": \"" ++ name ++ "\" is a registered claim, which jwt sets and checks itself (jwt.Registered); remove the field or give it another claim name");
        for (info.field_names[0..i], info.field_attrs[0..i]) |earlier, earlier_attrs| {
            if (!earlier_attrs.@"comptime" and std.mem.eql(u8, nameOf(S, @field(std.meta.FieldEnum(S), earlier)), name))
                @compileError("jwt: " ++ label ++ ": " ++ earlier ++ " and " ++ field ++ " are both the claim \"" ++ name ++ "\"; give each field a claim name of its own");
        }
    }
    for (info.field_names, info.field_types, info.field_attrs) |field, F, attrs| {
        if (!attrs.@"comptime") checkType(F, label ++ "." ++ field, outer ++ &[_]type{S});
    }
}

fn checkType(comptime T: type, comptime where: []const u8, comptime outer: []const type) void {
    switch (@typeInfo(T)) {
        .bool => return,
        .int => |int| {
            if (int.bits >= 1 and int.bits <= 64) return;
            @compileError(std.fmt.comptimePrint("jwt: {s}: {s} has {d} bits; a claim integer has 1 to 64, such as u64 or i64", .{ where, @typeName(T), int.bits }));
        },
        .float => if (T == f32 or T == f64) return,
        .@"enum" => |info| if (info.mode == .exhaustive) return,
        .optional => |info| {
            if (@typeInfo(info.child) == .optional)
                @compileError("jwt: " ++ where ++ ": " ++ @typeName(T) ++ " is an optional of an optional, which JSON null cannot tell apart; use " ++ @typeName(info.child));
            return checkType(info.child, where, outer);
        },
        .pointer => if (ListItem(T)) |Item| {
            if (Item == u8) return;
            return checkType(Item, where ++ "[]", outer);
        },
        .@"struct" => if (isPlainStruct(T)) {
            for (outer) |Outer| {
                if (Outer == T)
                    @compileError("jwt: " ++ where ++ ": " ++ @typeName(T) ++ " contains itself; claims nest only as deep as their type, so give each level a type of its own");
            }
            return checkStruct(T, if (isAnonymous(T)) where else @typeName(T), false, outer);
        },
        else => {},
    }
    @compileError("jwt: " ++ where ++ ": " ++ @typeName(T) ++ " is not a claim type; a claim is bool, an integer, f32, f64, an enum, []const u8 or a struct, alone, as ?T or as []const T");
}

/// The items of `T` when it is a slice `[]const Item` that holds a string
/// (`u8`) or a list; null for every other pointer.
fn ListItem(comptime T: type) ?type {
    const p = @typeInfo(T).pointer;
    if (p.size != .slice or !p.attrs.@"const" or p.sentinel_ptr != null) return null;
    if (p.attrs.@"volatile" or p.attrs.@"allowzero") return null;
    if ((p.attrs.@"align" orelse @alignOf(p.child)) != @alignOf(p.child)) return null;
    if ((p.attrs.@"addrspace" orelse .generic) != .generic) return null;
    return p.child;
}

fn isPlainStruct(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| !s.is_tuple and s.layout == .auto,
        else => false,
    };
}

/// A struct declared inline, such as `order: struct { id: u64 }`: errors
/// name it by the path of its field.
fn isAnonymous(comptime T: type) bool {
    const name = @typeName(T);
    const at = std.mem.findLast(u8, name, "__struct_") orelse return false;
    const digits = name[at + "__struct_".len ..];
    if (digits.len == 0) return false;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn isRegistered(name: []const u8) bool {
    for (registered_names) |registered| {
        if (std.mem.eql(u8, registered, name)) return true;
    }
    return false;
}

/// The entry of `field` in `T.claim_names`, if it has one.
fn claimName(comptime T: type, comptime field: []const u8) ?[]const u8 {
    if (!@hasDecl(T, "claim_names") or !@hasField(@TypeOf(T.claim_names), field)) return null;
    return asName(@field(T.claim_names, field));
}

/// `value` as a string, when it is one: a literal or a `[]const u8`.
fn asName(comptime value: anytype) ?[]const u8 {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) return value,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| if (a.child == u8) return value,
                else => {},
            },
            else => {},
        },
        else => {},
    }
    return null;
}

const testing = std.testing;

const Named = struct {
    is_root: bool = false,
    user_name: []const u8 = "",
    level: u8 = 0,

    pub const claim_names = .{ .is_root = "http://example.com/is_root" };
    pub const field_rules = .{ .user_name = v.rename("userName") };
};

test "a claim is named by claim_names first, then by its outside name" {
    try testing.expectEqualStrings("http://example.com/is_root", comptime nameOf(Named, .is_root));
    try testing.expectEqualStrings("userName", comptime nameOf(Named, .user_name));
    try testing.expectEqualStrings("level", comptime nameOf(Named, .level));
    comptime check(Named);
    comptime check(void);
}
