//! Module `harness` of the golden-vector tests. vector_gen.zig turns each
//! `vectors/<page>.json` into a test file in the build cache; every generated
//! test declares a DTO with one field,
//!
//!     const Dto = struct {
//!         value: <field_type>,
//!         pub const field_rules = .{ .value = <the record's rules> };
//!     };
//!
//! and calls `expectRecord(Dto, .{ ... })` with the record's input as JSON
//! text. This module declares the fixture types and predicates the records
//! may name (the generated file aliases each name of `fixture_names` in
//! vector_gen.zig), decodes the input into the field's type and compares
//! what `v.check` and, for a `checkAll` record, `v.checkAll` return with the
//! record.
//!
//! Input encoding, by the field type with its optionals removed:
//!
//! - integer: a JSON string of decimal digits, exact at every width: `"-128"`
//! - float: a JSON string: a decimal that round-trips in the field type, or
//!   `"nan"`, `"-nan"`, `"inf"`, `"-inf"`, `"-0"`; when the record has `bits`
//!   (lowercase hex of the IEEE bits in the type's width), they are the value
//!   and the text must parse to the same bits (to a NaN of the same sign for
//!   a NaN). A `c_longdouble` record has no `bits`, since the width depends
//!   on the target: its decimal is exact in `f64`, so it decodes to the same
//!   value everywhere
//! - string (a slice of `u8`, with or without a sentinel): a JSON string
//!   with the text; when the record has `hex` (lowercase hex of the bytes),
//!   the bytes come from it; a string inside a list or a struct that needs
//!   hex is `{ "hex": "..." }`
//! - bool: `true` or `false`
//! - enum: `".tag"`, or `"@fromBackingInt(9)"` for a value given by number
//! - optional: `null`, or the payload's encoding
//! - any other slice or array: a JSON array of the item encodings
//! - struct: a JSON object of field name to encoding; a field with a default
//!   value may be left out
const std = @import("std");
const v = @import("validator");
const Allocator = std.mem.Allocator;

pub const Role = enum { admin, user, guest };
pub const Color = enum { red, green, blue };
pub const Open = enum(u8) { a, b, _ };
pub const OpenOne = enum(u8) { only, _ };
pub const Only = enum { only };
pub const Sparse = enum(u32) { a = 1, b = 100, c = 1_000_000, d = 7 };
/// The item of the `uniqueBy` records.
pub const Item = struct { id: u32, name: []const u8, active: bool, role: Role };
/// The struct of the `custom` records.
pub const Stock = struct { sku: []const u8, qty: u32 };

pub fn isEven(x: u32) bool {
    return x % 2 == 0;
}

pub fn isEvenPtr(x: *const u32) bool {
    return x.* % 2 == 0;
}

pub fn lt100(x: u32) bool {
    return x < 100;
}

pub fn hasStock(s: Stock) bool {
    return s.qty > 0;
}

pub fn startsWithAt(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "@");
}

pub fn isNonEmpty(s: []const u8) bool {
    return s.len > 0;
}

pub fn isPositive64(x: u64) bool {
    return x > 0;
}

/// `pass`: no violation; `fail`: a rule failed; `precondition`: a rule's
/// precondition failed. Both `fail` and `precondition` compare the code.
pub const Expect = enum { pass, fail, precondition };

pub const Mode = enum { check, checkAll };

/// One violation of a `checkAll` record, in walk order; `path` is relative
/// to the DTO field, like `Record.path`.
pub const ExpectedViolation = struct { code: []const u8, path: []const u8 };

/// A record as a generated test passes it to `expectRecord`.
pub const Record = struct {
    id: []const u8,
    /// The record's `input`, as JSON text.
    input: []const u8,
    hex: ?[]const u8 = null,
    bits: ?[]const u8 = null,
    expect: Expect,
    /// Required unless `expect` is `.pass`.
    code: ?[]const u8 = null,
    /// Compared only when given.
    message: ?[]const u8 = null,
    /// The violation's field relative to the DTO field: `""`, `"[1]"`, `"[2].name"`.
    path: []const u8 = "",
    mode: Mode = .check,
    /// The whole `checkAll` report of a `checkAll` record.
    violations: []const ExpectedViolation = &.{},
};

/// Decodes `record.input` into the type of `Dto.value`, runs `v.check` with
/// a 256-byte path buffer and, for a `checkAll` record, `v.checkAll`, and
/// fails when a result differs from the record, after printing
/// `<id>: expected ..., got ...`. `pass` means no violation; otherwise the
/// code, the field (`value` followed by `record.path`) and, when the record
/// gives one, the message must match.
pub fn expectRecord(comptime Dto: type, record: Record) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const T = @FieldType(Dto, "value");
    const value = decodeInput(T, arena, record) catch |err| {
        std.debug.print("{s}: cannot decode the input {s} as {s}: {s}\n", .{ record.id, record.input, @typeName(T), @errorName(err) });
        return err;
    };
    const dto: Dto = .{ .value = value };
    var path_buf: [256]u8 = undefined;
    if (try firstMismatch(arena, record, v.check(&dto, &path_buf))) |text| return failRecord(record.id, text);
    if (record.mode == .checkAll) {
        const report = try v.checkAll(std.testing.allocator, &dto);
        defer report.deinit();
        if (try reportMismatch(arena, record, report.violations, report.truncated)) |text| return failRecord(record.id, text);
    }
}

fn failRecord(id: []const u8, text: []const u8) error{TestUnexpectedResult} {
    std.debug.print("{s}: {s}\n", .{ id, text });
    return error.TestUnexpectedResult;
}

/// How `check`'s result differs from the record, or null when it matches.
fn firstMismatch(arena: Allocator, record: Record, got: ?v.Violation) Allocator.Error!?[]const u8 {
    const want_field = try std.mem.concat(arena, u8, &.{ "value", record.path });
    const violation = got orelse {
        if (record.expect == .pass) return null;
        return try std.fmt.allocPrint(arena, "expected {s} at {s}, got pass", .{ record.code orelse "a violation", want_field });
    };
    if (record.expect == .pass) {
        return try std.fmt.allocPrint(arena, "expected pass, got {s} \"{s}\" at {s}", .{ violation.code, violation.message, violation.field orelse "(no field)" });
    }
    const same_code = std.mem.eql(u8, violation.code, record.code orelse "");
    const same_message = if (record.message) |message| std.mem.eql(u8, violation.message, message) else true;
    const same_field = if (violation.field) |field| std.mem.eql(u8, field, want_field) else false;
    if (same_code and same_message and same_field) return null;
    return try std.fmt.allocPrint(arena, "expected {s} \"{s}\" at {s}, got {s} \"{s}\" at {s}", .{
        record.code orelse "",
        record.message orelse "(any message)",
        want_field,
        violation.code,
        violation.message,
        violation.field orelse "(no field)",
    });
}

/// How a `checkAll` report differs from `record.violations`, or null when
/// it matches (a record cannot describe a truncated report).
fn reportMismatch(arena: Allocator, record: Record, violations: []const v.Violation, truncated: bool) Allocator.Error!?[]const u8 {
    const same = same: {
        if (truncated or violations.len != record.violations.len) break :same false;
        for (record.violations, violations) |want, got| {
            const want_field = try std.mem.concat(arena, u8, &.{ "value", want.path });
            const field = got.field orelse break :same false;
            if (!std.mem.eql(u8, want.code, got.code) or !std.mem.eql(u8, field, want_field)) break :same false;
        }
        break :same true;
    };
    if (same) return null;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, "expected checkAll to return [");
    for (record.violations, 0..) |want, i| {
        try text.print(arena, "{s}{s} at value{s}", .{ if (i == 0) "" else ", ", want.code, want.path });
    }
    try text.appendSlice(arena, "], got [");
    for (violations, 0..) |got, i| {
        try text.print(arena, "{s}{s} at {s}", .{ if (i == 0) "" else ", ", got.code, got.field orelse "(no field)" });
    }
    try text.appendSlice(arena, if (truncated) "] (truncated)" else "]");
    return text.items;
}

const DecodeError = error{
    /// `input` is not JSON text.
    InvalidJson,
    /// The JSON value has the wrong kind for the type (a number where the
    /// encoding asks for a string, an object for a list, ...).
    WrongKind,
    /// An integer or float text that does not parse or does not fit.
    InvalidNumber,
    /// `hex` or `bits` that are not hex digits of the right length.
    InvalidHex,
    /// `bits` and the float text are different values.
    BitsDisagree,
    /// An enum tag or number the enum does not have.
    UnknownTag,
    /// A JSON array whose length differs from the array type's.
    WrongLength,
    /// A JSON object key that is not a field of the struct.
    UnknownField,
    /// A struct field without a default value that the object leaves out.
    MissingField,
    OutOfMemory,
};

/// The record's input as a `T`; every slice is allocated from `arena`.
fn decodeInput(comptime T: type, arena: Allocator, record: Record) DecodeError!T {
    const json = std.json.parseFromSliceLeaky(std.json.Value, arena, record.input, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    return decode(T, arena, json, record.hex, record.bits);
}

/// `hex` and `bits` belong to the field itself, so they apply only at the
/// top level and through its optionals; items never get them.
fn decode(comptime T: type, arena: Allocator, json: std.json.Value, hex: ?[]const u8, bits: ?[]const u8) DecodeError!T {
    switch (@typeInfo(T)) {
        .optional => |info| {
            if (json == .null) return null;
            return try decode(info.child, arena, json, hex, bits);
        },
        .bool => return switch (json) {
            .bool => |b| b,
            else => error.WrongKind,
        },
        .int => return std.fmt.parseInt(T, try jsonString(json), 10) catch error.InvalidNumber,
        .float => return decodeFloat(T, try jsonString(json), bits),
        .@"enum" => return decodeEnum(T, try jsonString(json)),
        .pointer => |info| {
            if (info.size != .slice) @compileError("vector harness: cannot decode " ++ @typeName(T));
            if (info.child == u8) return decodeString(T, arena, json, hex);
            const items = try jsonArray(json);
            const out = if (comptime info.sentinel()) |s|
                try arena.allocSentinel(info.child, items.len, s)
            else
                try arena.alloc(info.child, items.len);
            for (out, items) |*item, element| item.* = try decode(info.child, arena, element, null, null);
            return out;
        },
        .array => |info| {
            const items = try jsonArray(json);
            if (items.len != info.len) return error.WrongLength;
            var out: T = undefined;
            for (&out, items) |*item, element| item.* = try decode(info.child, arena, element, null, null);
            return out;
        },
        .@"struct" => |info| {
            const object = switch (json) {
                .object => |o| o,
                else => return error.WrongKind,
            };
            for (object.keys()) |key| {
                if (!isFieldName(info.field_names, key)) return error.UnknownField;
            }
            var out: T = undefined;
            inline for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
                if (object.get(name)) |element| {
                    @field(out, name) = try decode(F, arena, element, null, null);
                } else if (comptime attrs.defaultValue(F)) |default| {
                    @field(out, name) = default;
                } else return error.MissingField;
            }
            return out;
        },
        else => @compileError("vector harness: cannot decode " ++ @typeName(T)),
    }
}

fn jsonString(json: std.json.Value) DecodeError![]const u8 {
    return switch (json) {
        .string => |s| s,
        else => error.WrongKind,
    };
}

fn jsonArray(json: std.json.Value) DecodeError![]const std.json.Value {
    return switch (json) {
        .array => |a| a.items,
        else => error.WrongKind,
    };
}

fn isFieldName(comptime names: []const [:0]const u8, key: []const u8) bool {
    inline for (names) |name| {
        if (std.mem.eql(u8, name, key)) return true;
    }
    return false;
}

fn decodeFloat(comptime T: type, s: []const u8, bits: ?[]const u8) DecodeError!T {
    // Parsed as the IEEE type of the same width: std.fmt.parseFloat takes no
    // c_longdouble, and it drops the sign of "-nan", so NaNs are spelled out.
    const F = switch (@bitSizeOf(T)) {
        16 => f16,
        32 => f32,
        64 => f64,
        80 => f80,
        128 => f128,
        else => @compileError("vector harness: cannot decode " ++ @typeName(T)),
    };
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    const parsed: F = if (std.mem.eql(u8, s, "nan"))
        std.math.nan(F)
    else if (std.mem.eql(u8, s, "-nan"))
        -std.math.nan(F)
    else
        std.fmt.parseFloat(F, s) catch return error.InvalidNumber;
    const hex = bits orelse return @bitCast(parsed);
    if (hex.len != @bitSizeOf(T) / 4) return error.InvalidHex;
    const exact: F = @bitCast(std.fmt.parseInt(Bits, hex, 16) catch return error.InvalidHex);
    if (std.math.isNan(exact)) {
        if (!std.math.isNan(parsed) or std.math.signbit(parsed) != std.math.signbit(exact)) return error.BitsDisagree;
    } else if (@as(Bits, @bitCast(parsed)) != @as(Bits, @bitCast(exact))) return error.BitsDisagree;
    return @bitCast(exact);
}

fn decodeEnum(comptime T: type, s: []const u8) DecodeError!T {
    if (std.mem.startsWith(u8, s, ".")) return std.meta.stringToEnum(T, s[1..]) orelse error.UnknownTag;
    const prefix = "@fromBackingInt(";
    if (!std.mem.startsWith(u8, s, prefix) or !std.mem.endsWith(u8, s, ")")) return error.WrongKind;
    const Tag = @typeInfo(T).@"enum".tag_type;
    const n = std.fmt.parseInt(Tag, s[prefix.len .. s.len - 1], 10) catch return error.InvalidNumber;
    return std.enums.fromInt(T, n) orelse error.UnknownTag;
}

fn decodeString(comptime T: type, arena: Allocator, json: std.json.Value, hex: ?[]const u8) DecodeError!T {
    const bytes = if (hex) |h| try fromHex(arena, h) else switch (json) {
        .string => |s| s,
        .object => |o| bytes: {
            const item_hex = o.get("hex") orelse return error.WrongKind;
            if (o.count() != 1 or item_hex != .string) return error.WrongKind;
            break :bytes try fromHex(arena, item_hex.string);
        },
        else => return error.WrongKind,
    };
    if (comptime @typeInfo(T).pointer.sentinel()) |s| {
        const out = try arena.allocSentinel(u8, bytes.len, s);
        @memcpy(out, bytes);
        return out;
    }
    return try arena.dupe(u8, bytes);
}

fn fromHex(arena: Allocator, hex: []const u8) DecodeError![]const u8 {
    const out = try arena.alloc(u8, hex.len / 2);
    return std.fmt.hexToBytes(out, hex) catch error.InvalidHex;
}

fn decodeTest(comptime T: type, arena: Allocator, input: []const u8) DecodeError!T {
    return decodeInput(T, arena, .{ .id = "t-001", .input = input, .expect = .pass });
}

test "integers decode from decimal strings, exact at every width" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqual(std.math.maxInt(u128), try decodeTest(u128, arena, "\"340282366920938463463374607431768211455\""));
    try std.testing.expectEqual(std.math.minInt(i128), try decodeTest(i128, arena, "\"-170141183460469231731687303715884105728\""));
    try std.testing.expectEqual(@as(i8, -128), try decodeTest(i8, arena, "\"-128\""));
    try std.testing.expectError(error.InvalidNumber, decodeTest(u8, arena, "\"256\""));
    try std.testing.expectError(error.WrongKind, decodeTest(u8, arena, "5"));
    try std.testing.expectError(error.InvalidJson, decodeTest(u8, arena, "\"5"));
}

test "floats decode from text, and from bits that the text must match" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const negative_zero = try decodeTest(f64, arena, "\"-0\"");
    try std.testing.expect(negative_zero == 0 and std.math.signbit(negative_zero));
    try std.testing.expect(std.math.isNan(try decodeTest(f64, arena, "\"nan\"")));
    try std.testing.expect(std.math.isNegativeInf(try decodeTest(f64, arena, "\"-inf\"")));
    const nan = try decodeInput(f64, arena, .{ .id = "t-001", .input = "\"nan\"", .bits = "7ff8000000000000", .expect = .pass });
    try std.testing.expectEqual(@as(u64, 0x7ff8000000000000), @as(u64, @bitCast(nan)));
    const tenth = try decodeInput(f32, arena, .{ .id = "t-001", .input = "\"0.1\"", .bits = "3dcccccd", .expect = .pass });
    try std.testing.expectEqual(@as(f32, 0.1), tenth);
    const smallest = try decodeInput(f64, arena, .{ .id = "t-001", .input = "\"5e-324\"", .bits = "0000000000000001", .expect = .pass });
    try std.testing.expectEqual(std.math.floatTrueMin(f64), smallest);
    try std.testing.expectError(error.BitsDisagree, decodeInput(f32, arena, .{ .id = "t-001", .input = "\"0.2\"", .bits = "3dcccccd", .expect = .pass }));
    try std.testing.expectError(error.BitsDisagree, decodeInput(f64, arena, .{ .id = "t-001", .input = "\"-nan\"", .bits = "7ff8000000000000", .expect = .pass }));
    const negative_nan = try decodeInput(f64, arena, .{ .id = "t-001", .input = "\"-nan\"", .bits = "fff8000000000000", .expect = .pass });
    try std.testing.expect(std.math.isNan(negative_nan) and std.math.signbit(negative_nan));
    try std.testing.expectEqual(@as(c_longdouble, 0.5), try decodeTest(c_longdouble, arena, "\"0.5\""));
    try std.testing.expectEqual(@as(f80, -2.5), try decodeTest(f80, arena, "\"-2.5\""));
    try std.testing.expectEqual(@as(f16, 65504), try decodeTest(f16, arena, "\"65504\""));
    try std.testing.expectError(error.InvalidHex, decodeInput(f64, arena, .{ .id = "t-001", .input = "\"0.1\"", .bits = "3dcccccd", .expect = .pass }));
    try std.testing.expectError(error.InvalidNumber, decodeTest(f64, arena, "\"one\""));
}

test "strings decode from text, from hex and from hex items" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("a b", try decodeTest([]const u8, arena, "\"a b\""));
    const bytes = try decodeInput([]const u8, arena, .{ .id = "t-001", .input = "\"a\\\\xffb\"", .hex = "61ff62", .expect = .pass });
    try std.testing.expectEqualStrings("a\xffb", bytes);
    const sentinel = try decodeTest([:0]const u8, arena, "\"ab\"");
    try std.testing.expectEqualStrings("ab", sentinel);
    try std.testing.expectEqual(@as(u8, 0), sentinel[sentinel.len]);
    const mutable = try decodeTest([]u8, arena, "\"\"");
    try std.testing.expectEqual(@as(usize, 0), mutable.len);
    const items = try decodeTest([]const []const u8, arena, "[\"a\",{\"hex\":\"ff\"}]");
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("\xff", items[1]);
    try std.testing.expectError(error.InvalidHex, decodeInput([]const u8, arena, .{ .id = "t-001", .input = "\"x\"", .hex = "f", .expect = .pass }));
    try std.testing.expectError(error.WrongKind, decodeTest([]const u8, arena, "[\"a\"]"));
}

test "enums decode from a tag or from a number" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqual(Role.admin, try decodeTest(Role, arena, "\".admin\""));
    try std.testing.expectEqual(@as(Open, @fromBackingInt(9)), try decodeTest(Open, arena, "\"@fromBackingInt(9)\""));
    try std.testing.expectEqual(Sparse.d, try decodeTest(Sparse, arena, "\"@fromBackingInt(7)\""));
    try std.testing.expectError(error.UnknownTag, decodeTest(Role, arena, "\".nope\""));
    try std.testing.expectError(error.UnknownTag, decodeTest(Role, arena, "\"@fromBackingInt(3)\""));
    try std.testing.expectError(error.WrongKind, decodeTest(Role, arena, "\"admin\""));
}

test "optionals, lists, arrays and structs decode item by item" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqual(@as(?u32, null), try decodeTest(?u32, arena, "null"));
    try std.testing.expectEqual(@as(??f64, @as(?f64, 0.0)), try decodeTest(??f64, arena, "\"0\""));
    const optionals = try decodeTest([]const ?u32, arena, "[null,\"0\"]");
    try std.testing.expectEqualSlices(?u32, &.{ null, 0 }, optionals);
    const pair = try decodeTest([2][]const u8, arena, "[\"a\",\"b\"]");
    try std.testing.expectEqualStrings("b", pair[1]);
    try std.testing.expectError(error.WrongLength, decodeTest([2]u8, arena, "[\"1\"]"));
    const stock = try decodeTest(Stock, arena, "{\"sku\":\"ABCDEFGH\",\"qty\":\"0\"}");
    try std.testing.expectEqualStrings("ABCDEFGH", stock.sku);
    try std.testing.expectEqual(@as(u32, 0), stock.qty);
    const item = try decodeTest(Item, arena, "{\"id\":\"1\",\"name\":\"a\",\"active\":true,\"role\":\".guest\"}");
    try std.testing.expectEqual(Role.guest, item.role);
    const Defaulted = struct { a: u8, b: u8 = 7 };
    try std.testing.expectEqual(@as(u8, 7), (try decodeTest(Defaulted, arena, "{\"a\":\"1\"}")).b);
    try std.testing.expectError(error.UnknownField, decodeTest(Stock, arena, "{\"sku\":\"A\",\"qty\":\"0\",\"price\":\"1\"}"));
    try std.testing.expectError(error.MissingField, decodeTest(Stock, arena, "{\"sku\":\"A\"}"));
}

test "expectRecord accepts the results a record describes" {
    const Name = struct {
        value: []const u8,
        pub const field_rules = .{ .value = v.notEmpty };
    };
    try expectRecord(Name, .{ .id = "t-001", .input = "\"a\"", .expect = .pass });
    try expectRecord(Name, .{ .id = "t-002", .input = "\"\"", .expect = .fail, .code = "validation.not_empty", .message = "must not be empty" });
    const Amount = struct {
        value: f64,
        pub const field_rules = .{ .value = v.positive };
    };
    try expectRecord(Amount, .{ .id = "t-003", .input = "\"nan\"", .expect = .precondition, .code = "validation.finite", .message = "must be a finite number" });
    const Counts = struct {
        value: []const u32,
        pub const field_rules = .{ .value = v.each(v.positive) };
    };
    try expectRecord(Counts, .{ .id = "t-004", .input = "[\"1\",\"0\"]", .expect = .fail, .code = "validation.positive", .path = "[1]" });
    try expectRecord(Counts, .{
        .id = "t-005",
        .input = "[\"0\",\"1\",\"0\"]",
        .expect = .fail,
        .code = "validation.positive",
        .path = "[0]",
        .mode = .checkAll,
        .violations = &.{
            .{ .code = "validation.positive", .path = "[0]" },
            .{ .code = "validation.positive", .path = "[2]" },
        },
    });
}

test "a mismatch names what the record expects and what came back" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const record: Record = .{ .id = "t-001", .input = "[]", .expect = .fail, .code = "validation.positive", .message = "must be greater than 0", .path = "[1]" };
    const right: v.Violation = .{ .code = "validation.positive", .message = "must be greater than 0", .field = "value[1]" };
    try std.testing.expect(try firstMismatch(arena, record, right) == null);
    try std.testing.expectEqualStrings(
        "expected validation.positive at value[1], got pass",
        (try firstMismatch(arena, record, null)).?,
    );
    try std.testing.expectEqualStrings(
        "expected validation.positive \"must be greater than 0\" at value[1], got validation.positive \"must be greater than 0\" at value[0]",
        (try firstMismatch(arena, record, .{ .code = right.code, .message = right.message, .field = "value[0]" })).?,
    );
    try std.testing.expectEqualStrings(
        "expected validation.positive \"must be greater than 0\" at value[1], got validation.positive \"is positive\" at (no field)",
        (try firstMismatch(arena, record, .{ .code = right.code, .message = "is positive" })).?,
    );
    const pass: Record = .{ .id = "t-002", .input = "[]", .expect = .pass };
    try std.testing.expectEqualStrings(
        "expected pass, got validation.positive \"must be greater than 0\" at value[1]",
        (try firstMismatch(arena, pass, right)).?,
    );
    const all: Record = .{ .id = "t-003", .input = "[]", .expect = .fail, .code = "validation.positive", .mode = .checkAll, .violations = &.{.{ .code = "validation.positive", .path = "[1]" }} };
    try std.testing.expect(try reportMismatch(arena, all, &.{right}, false) == null);
    try std.testing.expectEqualStrings(
        "expected checkAll to return [validation.positive at value[1]], got [validation.positive at value[1]] (truncated)",
        (try reportMismatch(arena, all, &.{right}, true)).?,
    );
    try std.testing.expectEqualStrings(
        "expected checkAll to return [validation.positive at value[1]], got []",
        (try reportMismatch(arena, all, &.{}, false)).?,
    );
}
