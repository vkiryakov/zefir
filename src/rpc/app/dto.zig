//! The types a request or a response may have: what the JSON codec of rpc
//! carries. Internal to the module; `rpc.Contract` checks the request and
//! the response of every method with `problem`.
//!
//! A DTO is built from structs with named fields, `bool`, integers 1 to 64
//! bits wide, `f32` and `f64`, exhaustive enums, optionals, strings
//! (`[]const u8`, UTF-8), slices `[]const T` and arrays `[N]T`. A request
//! is a struct; a response is any DTO type or `void`. Everything else
//! stops the build with the path of the field: pointers, unions, maps,
//! types that contain themselves, `usize` and `isize`.
//!
//! Each type in a DTO, the whole request or response included, takes at
//! most `max_type_bytes` (16 KiB): requests and responses, with their
//! copies while they are decoded and encoded, live on the stack of the
//! call's task, and the stack of a coroutine is small. Many items go in a
//! slice, `[]const T`, whose items live in the call's arena.

const std = @import("std");

/// The most bytes one type in a DTO may take, `@sizeOf` of the whole
/// request or response included.
pub const max_type_bytes = 16 * 1024;

/// Which side of a method a type is: only a response may be `void`, and a
/// request is always a struct.
pub const Role = enum { request, response };

/// Why `T` cannot be the request or the response of a method, as the end of
/// a compile error ("response app.User.avatar has unsupported type
/// *app.File"), or null when it can. The path starts at `T` itself:
/// `.name` for a field, `[]` for the items of a slice or an array.
pub fn problem(comptime T: type, comptime role: Role) ?[]const u8 {
    return comptime check(T, role);
}

fn check(comptime T: type, comptime role: Role) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    const name = @tagName(role);
    switch (role) {
        .request => if (@typeInfo(T) != .@"struct") return name ++ " must be a struct, got " ++ @typeName(T),
        .response => if (T == void) return null,
    }
    const found = walk(T, null, T, &.{}) orelse return null;
    return name ++ found;
}

/// The first problem inside `T`, which sits at `path` (null: `T` is the
/// whole request or response, `Root`). `outer` lists the structs that
/// contain `T`, to find a type that contains itself.
fn walk(comptime T: type, comptime path: ?[]const u8, comptime Root: type, comptime outer: []const type) ?[]const u8 {
    // The path of the parts of T: the name of the root type, then fields
    // and items.
    const here = path orelse @typeName(Root);
    const unsupported = (if (path) |p| " " ++ p else "") ++ " has unsupported type " ++ @typeName(T);
    switch (@typeInfo(T)) {
        .bool => return null,
        .int => |int| {
            if (T == usize or T == isize) return unsupported ++ "; its size depends on the target: use u64 or i64";
            // c_int and the other C types are distinct types of a size that
            // depends on the target too.
            if (T != @Int(int.signedness, int.bits)) return unsupported ++ "; its size depends on the target: use an integer of a fixed width such as i32";
            if (int.bits == 0 or int.bits > 64) return unsupported ++ "; integers are 1 to 64 bits wide";
            return null;
        },
        .float => return if (T == f32 or T == f64) null else unsupported ++ "; floats are f32 or f64",
        .@"enum" => |info| return if (info.mode == .exhaustive) null else unsupported ++ "; an enum must be exhaustive, so that every value has a name to send",
        .optional => |info| {
            if (@typeInfo(info.child) == .optional) return unsupported ++ "; JSON null cannot tell the two optionals apart";
            return walk(info.child, path, Root, outer);
        },
        .pointer => |info| {
            if (info.size != .slice) return unsupported;
            if (!info.attrs.@"const") return unsupported ++ "; a slice in a DTO is const: []const " ++ @typeName(info.child);
            if (info.sentinel_ptr != null) return unsupported ++ "; a slice with a sentinel is not supported";
            if (info.attrs.@"volatile" or info.attrs.@"allowzero") return unsupported;
            if ((info.attrs.@"align" orelse @alignOf(info.child)) != @alignOf(info.child)) return unsupported;
            if ((info.attrs.@"addrspace" orelse .generic) != .generic) return unsupported;
            // []const u8 is a string.
            if (info.child == u8) return null;
            return walk(info.child, here ++ "[]", Root, outer);
        },
        .array => |info| {
            if (info.sentinel_ptr != null) return unsupported ++ "; an array with a sentinel is not supported";
            if (walk(info.child, here ++ "[]", Root, outer)) |found| return found;
            return tooLarge(T, here, "use a slice, []const " ++ @typeName(info.child));
        },
        .@"struct" => |info| {
            if (info.is_tuple) return unsupported ++ "; a tuple has no field names: use a struct";
            if (info.layout != .auto) return unsupported ++ "; packed and extern structs are not DTOs: use a plain struct";
            for (outer) |Outer| {
                if (Outer == T) return " " ++ here ++ ": recursive types are not supported; " ++ @typeName(T) ++ " contains itself";
            }
            const inner = outer ++ [_]type{T};
            for (info.field_names, info.field_types, info.field_attrs) |field, Field, attrs| {
                const field_path = here ++ "." ++ field;
                if (attrs.@"comptime") return " " ++ field_path ++ " is a comptime field; a DTO has only runtime fields";
                if (Field == void) return " " ++ field_path ++ " has unsupported type void; void is only a whole response";
                if (walk(Field, field_path, Root, inner)) |found| return found;
            }
            return tooLarge(T, here, "keep large parts in slices, []const T");
        },
        .void => return unsupported ++ "; void is only a whole response",
        .@"union" => return unsupported ++ "; unions are not supported",
        else => return unsupported,
    }
}

/// The problem of `T` at `here` if it takes more than `max_type_bytes`.
/// Only for arrays and structs whose parts passed: the other types are
/// small, and an unsupported part may have no size.
fn tooLarge(comptime T: type, comptime here: []const u8, comptime hint: []const u8) ?[]const u8 {
    if (@sizeOf(T) <= max_type_bytes) return null;
    return std.fmt.comptimePrint(" {s} takes {d} bytes; a type in a DTO takes at most {d} (16 KiB), since requests and responses live on the stack of a call: {s}", .{ here, @sizeOf(T), max_type_bytes, hint });
}

const testing = std.testing;

fn expectProblem(comptime T: type, comptime role: Role, comptime expected: ?[]const u8) !void {
    const actual = comptime problem(T, role);
    if (expected) |text| {
        if (actual == null) {
            std.debug.print("expected a problem: {s}\ngot none\n", .{text});
            return error.TestExpectedProblem;
        }
        try testing.expectEqualStrings(text, actual.?);
    } else if (actual) |text| {
        std.debug.print("expected no problem, got: {s}\n", .{text});
        return error.TestUnexpectedProblem;
    }
}

const Color = enum { red, green };
const Point = struct { x: f64, y: f64 };
const Valid = struct {
    flag: bool,
    small: u1,
    count: u32,
    big: i64,
    ratio: f32,
    color: Color,
    note: ?[]const u8 = null,
    name: []const u8,
    tags: []const []const u8,
    points: []const Point,
    pair: [2]u8,
    nested: ?struct { inner: [3]Color } = null,
    empty: struct {} = .{},

    pub const field_rules = .{};
    pub fn helper() void {}
};

test "every kind of DTO type passes, and declarations do not count" {
    try expectProblem(Valid, .request, null);
    try expectProblem(Valid, .response, null);
    try expectProblem(struct {}, .request, null);
}

test "a response may be void or any DTO type; a request is a struct" {
    try expectProblem(void, .response, null);
    try expectProblem(u64, .response, null);
    try expectProblem([]const Point, .response, null);
    try expectProblem(?Point, .response, null);
    try expectProblem([]const u8, .response, null);
    try expectProblem(void, .request, "request must be a struct, got void");
    try expectProblem(u64, .request, "request must be a struct, got u64");
    try expectProblem([]const Point, .request, "request must be a struct, got []const app.dto.Point");
}

const File = struct { fd: i32 };
const User = struct { id: u64, avatar: ?*File };
const Product = struct { id: u64, owner: *const File };
const Item = struct { product: Product, count: u32 };
const Order = struct { items: []const Item };

test "the path of a problem starts at the type and names each field" {
    try expectProblem(User, .response, "response app.dto.User.avatar has unsupported type *app.dto.File");
    try expectProblem(Order, .request, "request app.dto.Order.items[].product.owner has unsupported type *const app.dto.File");
    try expectProblem(*User, .response, "response has unsupported type *app.dto.User");
    try expectProblem(?*User, .response, "response has unsupported type *app.dto.User");
    try expectProblem([]const User, .response, "response []const app.dto.User[].avatar has unsupported type *app.dto.File");
    try expectProblem([2][]User, .response, "response [2][]app.dto.User[] has unsupported type []app.dto.User; a slice in a DTO is const: []const app.dto.User");
}

const Sized = struct { n: usize };
const Signed = struct { n: isize };
const CInt = struct { n: c_int };
const Wide = struct { n: u65 };
const Zero = struct { n: u0 };
const Half = struct { n: f16 };
const Long = struct { n: f128 };
const Widths = struct { a: u1, b: i64, c: u64, d: i1, e: f32, f: f64 };

test "integers are 1 to 64 bits of a fixed width, floats f32 or f64" {
    try expectProblem(Widths, .request, null);
    try expectProblem(Sized, .request, "request app.dto.Sized.n has unsupported type usize; its size depends on the target: use u64 or i64");
    try expectProblem(Signed, .request, "request app.dto.Signed.n has unsupported type isize; its size depends on the target: use u64 or i64");
    try expectProblem(CInt, .request, "request app.dto.CInt.n has unsupported type c_int; its size depends on the target: use an integer of a fixed width such as i32");
    try expectProblem(Wide, .request, "request app.dto.Wide.n has unsupported type u65; integers are 1 to 64 bits wide");
    try expectProblem(Zero, .request, "request app.dto.Zero.n has unsupported type u0; integers are 1 to 64 bits wide");
    try expectProblem(Half, .request, "request app.dto.Half.n has unsupported type f16; floats are f32 or f64");
    try expectProblem(Long, .request, "request app.dto.Long.n has unsupported type f128; floats are f32 or f64");
}

const Open = enum(u8) { a, _ };
const WithOpen = struct { e: Open };
const Shape = union(enum) { circle: f64, square: f64 };
const Untagged = union { a: u32, b: u32 };
const Pair = struct { u32, u32 };
const Packed = packed struct { a: u4, b: u4 };
const Extern = extern struct { a: u32 };
const WithPacked = struct { p: Packed };

test "unions, tuples, packed and extern structs and open enums are not DTOs" {
    try expectProblem(WithOpen, .request, "request app.dto.WithOpen.e has unsupported type app.dto.Open; an enum must be exhaustive, so that every value has a name to send");
    try expectProblem(Shape, .response, "response has unsupported type app.dto.Shape; unions are not supported");
    try expectProblem(Untagged, .response, "response has unsupported type app.dto.Untagged; unions are not supported");
    try expectProblem(Pair, .response, "response has unsupported type struct { u32, u32 }; a tuple has no field names: use a struct");
    try expectProblem(Pair, .request, "request has unsupported type struct { u32, u32 }; a tuple has no field names: use a struct");
    try expectProblem(Packed, .request, "request has unsupported type app.dto.Packed; packed and extern structs are not DTOs: use a plain struct");
    try expectProblem(Extern, .response, "response has unsupported type app.dto.Extern; packed and extern structs are not DTOs: use a plain struct");
    try expectProblem(WithPacked, .request, "request app.dto.WithPacked.p has unsupported type app.dto.Packed; packed and extern structs are not DTOs: use a plain struct");
}

const Mutable = struct { name: []u8 };
const Terminated = struct { name: [:0]const u8 };
const TerminatedArray = struct { name: [4:0]u8 };
const Many = struct { name: [*]const u8 };
const Aligned = struct { items: []align(1) const u32 };
const NaturallyAligned = struct { items: []align(@alignOf(u32)) const u32 };
const Text = struct { name: []const u8, bytes: [4]u8, lines: []const []const u8 };

test "strings and lists are const slices and arrays without a sentinel" {
    try expectProblem(Text, .request, null);
    try expectProblem(NaturallyAligned, .request, null);
    try expectProblem(Mutable, .request, "request app.dto.Mutable.name has unsupported type []u8; a slice in a DTO is const: []const u8");
    try expectProblem(Terminated, .request, "request app.dto.Terminated.name has unsupported type [:0]const u8; a slice with a sentinel is not supported");
    try expectProblem(TerminatedArray, .request, "request app.dto.TerminatedArray.name has unsupported type [4:0]u8; an array with a sentinel is not supported");
    try expectProblem(Many, .request, "request app.dto.Many.name has unsupported type [*]const u8");
    try expectProblem(Aligned, .request, "request app.dto.Aligned.items has unsupported type []align(1) const u32");
}

const Twice = struct { n: ??u32 };
const VoidField = struct { done: void };
const Fixed = struct { comptime version: u32 = 1 };
const Callback = struct { f: *const fn () void };
const Failing = struct { r: anyerror!u32 };

test "nested optionals, void fields, comptime fields and other types are not DTOs" {
    try expectProblem(Twice, .request, "request app.dto.Twice.n has unsupported type ??u32; JSON null cannot tell the two optionals apart");
    try expectProblem(VoidField, .request, "request app.dto.VoidField.done has unsupported type void; void is only a whole response");
    try expectProblem(Fixed, .request, "request app.dto.Fixed.version is a comptime field; a DTO has only runtime fields");
    try expectProblem(Callback, .request, "request app.dto.Callback.f has unsupported type *const fn () void");
    try expectProblem(Failing, .request, "request app.dto.Failing.r has unsupported type anyerror!u32");
    try expectProblem(?void, .response, "response has unsupported type void; void is only a whole response");
}

const Blob = struct { id: u64, data: [20_000]u8 };
const Crowded = struct { a: [8192]u8, b: [8192]u8, c: u8 };
const AtLimit = struct { data: [16_384]u8 };
const Rows = struct { rows: []const [16_000]u8 };
const BigRows = struct { rows: []const [20_000]u8 };
const MaybeBlob = struct { data: ?[20_000]u8 };
const Grid = struct { cells: [4][8192]u8 };
const Huge = struct { items: [100_001]u8 };

test "a type in a DTO takes at most 16 KiB: the root, a field, an item, the payload of an optional" {
    try expectProblem(AtLimit, .request, null);
    try expectProblem(Rows, .response, null);
    try expectProblem(?[1000]u64, .response, null);
    try expectProblem(Blob, .request, "request app.dto.Blob.data takes 20000 bytes; a type in a DTO takes at most 16384 (16 KiB), since requests and responses live on the stack of a call: use a slice, []const u8");
    try expectProblem(Crowded, .response, "response app.dto.Crowded takes 16385 bytes; a type in a DTO takes at most 16384 (16 KiB), since requests and responses live on the stack of a call: keep large parts in slices, []const T");
    try expectProblem(BigRows, .response, "response app.dto.BigRows.rows[] takes 20000 bytes; a type in a DTO takes at most 16384 (16 KiB), since requests and responses live on the stack of a call: use a slice, []const u8");
    try expectProblem(MaybeBlob, .request, "request app.dto.MaybeBlob.data takes 20000 bytes; a type in a DTO takes at most 16384 (16 KiB), since requests and responses live on the stack of a call: use a slice, []const u8");
    try expectProblem(Grid, .request, "request app.dto.Grid.cells takes 32768 bytes; a type in a DTO takes at most 16384 (16 KiB), since requests and responses live on the stack of a call: use a slice, []const [8192]u8");
    try expectProblem([20_000]u8, .response, "response [20000]u8 takes 20000 bytes; a type in a DTO takes at most 16384 (16 KiB), since requests and responses live on the stack of a call: use a slice, []const u8");
    // An array that JSON could never fill: more items than a body may hold.
    try expectProblem(Huge, .request, "request app.dto.Huge.items takes 100001 bytes; a type in a DTO takes at most 16384 (16 KiB), since requests and responses live on the stack of a call: use a slice, []const u8");
}

const Node = struct { name: []const u8, children: []const Node };
const Parent = struct { child: ?Child };
const Child = struct { parents: []const Parent };
const Shared = struct { a: Point, b: Point, c: []const Point };

test "a type that contains itself is not a DTO; a type used twice is" {
    try expectProblem(Shared, .request, null);
    try expectProblem(Node, .response, "response app.dto.Node.children[]: recursive types are not supported; app.dto.Node contains itself");
    try expectProblem(Parent, .request, "request app.dto.Parent.child.parents[]: recursive types are not supported; app.dto.Parent contains itself");
    try expectProblem([]const Child, .response, "response []const app.dto.Child[].parents[].child: recursive types are not supported; app.dto.Child contains itself");
}
