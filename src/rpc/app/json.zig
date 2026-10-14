//! The JSON codec of rpc: requests and responses as JSON, by their Zig
//! types. Internal to the module; `rpc.Server` and `rpc.Client` use it.
//!
//! - Integers up to 32 bits wide are JSON numbers. Integers of 33 to 64
//!   bits are strings of decimal digits ("9007199254740993"), so that
//!   clients in JavaScript, whose numbers are doubles, keep every digit.
//! - Floats are finite numbers, written so that they read back exactly.
//! - An enum is the name of its tag; an optional is `null` or the value;
//!   `[]const u8` is a string of UTF-8; other slices and arrays, `[N]u8`
//!   too, are JSON arrays.
//! - A struct is an object with its fields in the order of declaration; a
//!   `void` response is `{}`.
//!
//! `std.json` alone does not keep these rules: it writes big integers as
//! numbers and refuses unknown fields by default, for example.

const std = @import("std");
const dto = @import("dto.zig");
const rules = @import("../rules.zig");

const Writer = std.Io.Writer;

pub const EncodeError = Writer.Error || error{
    /// A float is NaN or infinite: JSON has no such numbers.
    NonFinite,
    /// A string is not valid UTF-8.
    InvalidUtf8,
};

/// Writes `value` as JSON to `w`, without spaces. `T` is a DTO type or
/// `void` (see dto.zig); a NaN or an infinite float, or a string that is not
/// UTF-8, stops the encoding with an error, and `w` then holds a part of the
/// JSON.
pub fn encode(comptime T: type, value: *const T, w: *Writer) EncodeError!void {
    if (comptime dto.problem(T, .response)) |found| @compileError("rpc: json.encode: " ++ found);
    try write(T, value, w);
}

fn write(comptime T: type, value: *const T, w: *Writer) EncodeError!void {
    switch (@typeInfo(T)) {
        .void => try w.writeAll("{}"),
        .bool => try w.writeAll(if (value.*) "true" else "false"),
        .int => |info| if (info.bits <= 32) try w.print("{d}", .{value.*}) else try w.print("\"{d}\"", .{value.*}),
        .float => try writeFloat(T, value.*, w),
        .@"enum" => try writeString(@tagName(value.*), w),
        .optional => |info| if (value.*) |*inner| try write(info.child, inner, w) else try w.writeAll("null"),
        .pointer => |info| if (info.child == u8) try writeString(value.*, w) else try writeItems(info.child, value.*, w),
        .array => |info| try writeItems(info.child, value, w),
        .@"struct" => |info| {
            try w.writeByte('{');
            inline for (info.field_names, info.field_types, 0..) |name, Field, i| {
                if (i > 0) try w.writeByte(',');
                try writeString(name, w);
                try w.writeByte(':');
                try write(Field, &@field(value, name), w);
            }
            try w.writeByte('}');
        },
        else => @compileError("rpc: json.encode: unsupported type " ++ @typeName(T)),
    }
}

fn writeItems(comptime Item: type, items: []const Item, w: *Writer) EncodeError!void {
    try w.writeByte('[');
    for (items, 0..) |*item, i| {
        if (i > 0) try w.writeByte(',');
        try write(Item, item, w);
    }
    try w.writeByte(']');
}

fn writeString(text: []const u8, w: *Writer) EncodeError!void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    try std.json.Stringify.encodeJsonString(text, .{}, w);
}

/// The shortest digits that read back as the same `T`: plain from 1e-6 up
/// to 1e21, with an exponent outside that range, as JavaScript writes
/// numbers.
fn writeFloat(comptime T: type, x: T, w: *Writer) EncodeError!void {
    if (!std.math.isFinite(x)) return error.NonFinite;
    const magnitude = @abs(x);
    const mode: std.fmt.float.Mode = if (magnitude == 0 or (magnitude >= 1e-6 and magnitude < 1e21)) .decimal else .scientific;
    var buffer: [std.fmt.float.bufferSize(.decimal, T)]u8 = undefined;
    const text = std.fmt.float.render(&buffer, x, .{ .mode = mode }) catch unreachable;
    try w.writeAll(text);
}

/// The limits of one `decode`; `rpc.Server` takes them from its `Limits`.
pub const Limits = struct {
    /// Arrays and objects inside each other, the outermost one included.
    max_depth: u32 = 32,
    /// Items of one array, members of one object.
    max_items: u32 = 100_000,
};

/// What is wrong with a body that `decode` refused.
pub const Problem = struct {
    /// Where: "items[2].name", in the arena of the decode. Null for the
    /// body as a whole, and for a path longer than 256 bytes or with a
    /// control character, which a client's keys may bring.
    field: ?[]const u8 = null,
    /// What, one of a few static texts such as "missing required field".
    message: []const u8 = "",
};

pub const DecodeError = error{
    /// The body breaks a rule; `problem` says where and which.
    Invalid,
    OutOfMemory,
};

/// The value of type `T` that `bytes` holds, decoded strictly:
///
/// - integers of 33 to 64 bits only from strings of digits without "+",
///   leading zeros or "-0", narrower ones only from numbers without a
///   fraction or an exponent; a value outside the type is refused;
/// - a float from a number that fits the type;
/// - `null` only for an optional;
/// - an unknown field is skipped, but its depth and its items count; a
///   missing field takes its default value, an optional without one null,
///   and any other is refused;
/// - a key that repeats in an object is refused, an unknown one too, at
///   any depth;
/// - `[N]T` takes exactly N items; an enum only the name of one of its
///   tags; strings must be UTF-8.
///
/// Memory comes from `arena`, which the caller frees as a whole, also after
/// an error. Strings of the result point into `bytes` when they have no
/// escapes, so `bytes` must outlive the result. A buffer that would grow in
/// the arena (the items of a slice, the unknown keys of an object, a string
/// with escapes) is sized once from the raw bytes, since each copy that a
/// growing buffer leaves behind stays in the arena until the end. On
/// `error.Invalid`, `problem` says what is wrong.
pub fn decode(comptime T: type, arena: std.mem.Allocator, bytes: []const u8, limits: Limits, problem: *Problem) DecodeError!T {
    if (comptime dto.problem(T, .response)) |found| @compileError("rpc: json.decode: " ++ found);
    problem.* = .{};
    var decoder: Decoder = .{
        .scanner = .initCompleteInput(arena, bytes),
        .arena = arena,
        .bytes = bytes,
        .limits = limits,
        .problem = problem,
    };
    const result = try decoder.value(T);
    switch (try decoder.next()) {
        .end_of_document => return result,
        else => return decoder.fail(invalid_json),
    }
}

const invalid_json = "invalid JSON";
const invalid_utf8 = "invalid UTF-8";
const wrong_type = "wrong type";
const missing_field = "missing required field";
const duplicate_key = "duplicate key";
const out_of_range = "number out of range";
const not_canonical = "not a canonical integer";
const unknown_enum = "unknown enum value";
const too_deep = "too deep";
const too_many_items = "too many items";
const wrong_length = "wrong array length";

const Decoder = struct {
    scanner: std.json.Scanner,
    arena: std.mem.Allocator,
    bytes: []const u8,
    limits: Limits,
    problem: *Problem,
    /// Arrays and objects open now.
    depth: u32 = 0,
    /// Where the decoder is: a key or an index for each open container.
    path: std.ArrayList(Step) = .empty,
    /// The keys of the open objects that no field takes: their duplicates
    /// are looked for when each object ends.
    keys: std.ArrayList([]const u8) = .empty,
    /// The containers open inside a value that `skip` reads.
    frames: std.ArrayList(Frame) = .empty,

    const Step = union(enum) { key: []const u8, index: usize };
    const Frame = struct { object: bool, items: usize, keys_start: usize };

    fn value(d: *Decoder, comptime T: type) DecodeError!T {
        switch (@typeInfo(T)) {
            .bool => return switch (try d.next()) {
                .true => true,
                .false => false,
                else => d.fail(wrong_type),
            },
            .int => return d.integer(T),
            .float => return d.float(T),
            .@"enum" => return std.meta.stringToEnum(T, try d.string()) orelse d.fail(unknown_enum),
            .optional => |info| {
                if (try d.peek() == .null) {
                    _ = try d.next();
                    return null;
                }
                return try d.value(info.child);
            },
            .pointer => |info| return if (info.child == u8) d.string() else d.slice(info.child),
            .array => |info| return d.array(info.child, info.len),
            .@"struct" => return d.object(T),
            .void => _ = try d.object(struct {}),
            else => @compileError("rpc: json.decode: unsupported type " ++ @typeName(T)),
        }
    }

    fn integer(d: *Decoder, comptime T: type) DecodeError!T {
        // Up to 32 bits a number, wider a string of digits.
        const text = if (@typeInfo(T).int.bits <= 32) switch (try d.next()) {
            .number => |text| text,
            .allocated_number => |text| text,
            else => return d.fail(wrong_type),
        } else try d.string();
        if (!isCanonicalInteger(text)) return d.fail(not_canonical);
        return std.fmt.parseInt(T, text, 10) catch |err| switch (err) {
            error.Overflow => d.fail(out_of_range),
            error.InvalidCharacter => d.fail(not_canonical),
        };
    }

    fn float(d: *Decoder, comptime T: type) DecodeError!T {
        const text = switch (try d.next()) {
            .number => |text| text,
            .allocated_number => |text| text,
            else => return d.fail(wrong_type),
        };
        const x = std.fmt.parseFloat(T, text) catch return d.fail(invalid_json);
        if (std.math.isInf(x)) return d.fail(out_of_range);
        return x;
    }

    fn string(d: *Decoder) DecodeError![]const u8 {
        return switch (try d.next()) {
            .string => |text| text,
            .allocated_string => |text| text,
            else => d.fail(wrong_type),
        };
    }

    fn slice(d: *Decoder, comptime Item: type) DecodeError![]const Item {
        try d.open(.array);
        var items: std.ArrayList(Item) = .empty;
        // Room for every item at once: a list that grows in an arena leaves
        // each smaller copy behind, several times the items in all.
        try items.ensureTotalCapacityPrecise(d.arena, @min(countItems(d.bytes, d.scanner.cursor), d.limits.max_items));
        try d.path.append(d.arena, .{ .index = 0 });
        while (try d.peek() != .array_end) {
            if (items.items.len == d.limits.max_items) return d.failOutside(too_many_items);
            d.path.items[d.path.items.len - 1] = .{ .index = items.items.len };
            const item = try d.value(Item);
            try items.append(d.arena, item);
        }
        d.close();
        _ = try d.next();
        return items.items;
    }

    fn array(d: *Decoder, comptime Item: type, comptime len: usize) DecodeError![len]Item {
        try d.open(.array);
        var result: [len]Item = undefined;
        var count: usize = 0;
        try d.path.append(d.arena, .{ .index = 0 });
        while (try d.peek() != .array_end) {
            if (count == d.limits.max_items) return d.failOutside(too_many_items);
            if (len == 0 or count == len) return d.failOutside(wrong_length);
            d.path.items[d.path.items.len - 1] = .{ .index = count };
            if (len > 0) result[count] = try d.value(Item);
            count += 1;
        }
        if (count != len) return d.failOutside(wrong_length);
        d.close();
        _ = try d.next();
        return result;
    }

    fn object(d: *Decoder, comptime T: type) DecodeError!T {
        const info = @typeInfo(T).@"struct";
        try d.open(.object);
        var result: T = undefined;
        var seen: [info.field_names.len]bool = @splat(false);
        const keys_start = d.keys.items.len;
        var members: usize = 0;
        while (true) {
            const key = switch (try d.next()) {
                .object_end => break,
                .string => |key| key,
                .allocated_string => |key| key,
                else => return d.fail(invalid_json),
            };
            if (members == d.limits.max_items) return d.fail(too_many_items);
            members += 1;
            try d.path.append(d.arena, .{ .key = key });
            if (!try d.field(T, &result, &seen, key)) {
                try d.pushKey(key);
                try d.skip();
            }
            d.path.items.len -= 1;
        }
        try d.checkKeys(keys_start);
        d.keys.items.len = keys_start;
        inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, Field, attrs, i| {
            if (!seen[i]) {
                if (attrs.defaultValue(Field)) |default| {
                    @field(result, name) = default;
                } else if (@typeInfo(Field) == .optional) {
                    @field(result, name) = null;
                } else {
                    try d.path.append(d.arena, .{ .key = name });
                    return d.fail(missing_field);
                }
            }
        }
        d.depth -= 1;
        return result;
    }

    /// Decodes the value of `key` into its field of `result`; false when no
    /// field of `T` is called `key`.
    fn field(d: *Decoder, comptime T: type, result: *T, seen: []bool, key: []const u8) DecodeError!bool {
        if (@typeInfo(T).@"struct".field_names.len == 0) return false;
        const which = std.meta.stringToEnum(std.meta.FieldEnum(T), key) orelse return false;
        const index = @backingInt(which);
        if (seen[index]) return d.fail(duplicate_key);
        seen[index] = true;
        switch (which) {
            inline else => |tag| @field(result, @tagName(tag)) = try d.value(@FieldType(T, @tagName(tag))),
        }
        return true;
    }

    /// Reads one value that no field takes, under the same limits: its
    /// containers count for the depth, its arrays and objects for
    /// `max_items`, and its objects may not repeat a key.
    fn skip(d: *Decoder) DecodeError!void {
        const bottom = d.frames.items.len;
        try d.enterSkipped(try d.next());
        while (d.frames.items.len > bottom) {
            const top = &d.frames.items[d.frames.items.len - 1];
            const token = try d.next();
            switch (token) {
                .object_end, .array_end => {
                    // The step of the item inside the container.
                    d.path.items.len -= 1;
                    if (top.object) try d.checkKeys(top.keys_start);
                    d.keys.items.len = top.keys_start;
                    d.frames.items.len -= 1;
                    d.depth -= 1;
                },
                else => {
                    if (top.items == d.limits.max_items) return d.failOutside(too_many_items);
                    const index = top.items;
                    top.items += 1;
                    if (top.object) {
                        const key = switch (token) {
                            .string => |key| key,
                            .allocated_string => |key| key,
                            else => return d.fail(invalid_json),
                        };
                        d.path.items[d.path.items.len - 1] = .{ .key = key };
                        try d.pushKey(key);
                        try d.enterSkipped(try d.next());
                    } else {
                        d.path.items[d.path.items.len - 1] = .{ .index = index };
                        try d.enterSkipped(token);
                    }
                },
            }
        }
    }

    /// After the first token of a skipped value: a container opens a frame,
    /// anything else is read whole.
    fn enterSkipped(d: *Decoder, token: std.json.Token) DecodeError!void {
        const is_object = switch (token) {
            .object_begin => true,
            .array_begin => false,
            else => return,
        };
        try d.deeper();
        try d.frames.append(d.arena, .{ .object = is_object, .items = 0, .keys_start = d.keys.items.len });
        try d.path.append(d.arena, .{ .index = 0 });
    }

    /// Keeps an unknown key of an open object until the object ends, to
    /// look for its repeats. The stack of keys grows rarely and by a lot:
    /// grown key by key in an arena, it would leave each smaller copy
    /// behind. When it is full, it makes room for the rest of the members
    /// of the object (they may all be unknown; at most `max_items`), at
    /// least twice its size, and at least 16 keys. So the bytes of an
    /// object are counted only when the stack runs out of room.
    fn pushKey(d: *Decoder, key: []const u8) DecodeError!void {
        if (d.keys.items.len == d.keys.capacity) {
            // The scanner stands right after the key: this member and the
            // rest.
            const rest = @min(countItems(d.bytes, d.scanner.cursor), d.limits.max_items);
            try d.keys.ensureTotalCapacityPrecise(d.arena, @max(d.keys.items.len + @max(rest, 1), 2 * d.keys.capacity, 16));
        }
        d.keys.appendAssumeCapacity(key);
    }

    /// Fails when the keys from `start` on repeat one another.
    fn checkKeys(d: *Decoder, start: usize) DecodeError!void {
        const keys = d.keys.items[start..];
        if (keys.len < 2) return;
        std.mem.sortUnstable([]const u8, keys, {}, lessThan);
        for (keys[1..], keys[0 .. keys.len - 1]) |key, previous| {
            if (std.mem.eql(u8, key, previous)) {
                try d.path.append(d.arena, .{ .key = key });
                return d.fail(duplicate_key);
            }
        }
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }

    fn open(d: *Decoder, comptime kind: enum { array, object }) DecodeError!void {
        switch (try d.next()) {
            .array_begin => if (kind != .array) return d.fail(wrong_type),
            .object_begin => if (kind != .object) return d.fail(wrong_type),
            else => return d.fail(wrong_type),
        }
        try d.deeper();
    }

    fn deeper(d: *Decoder) error{Invalid}!void {
        d.depth += 1;
        if (d.depth > d.limits.max_depth) return d.fail(too_deep);
    }

    /// Ends an array that `slice` or `array` read: drops the step of its
    /// items.
    fn close(d: *Decoder) void {
        d.path.items.len -= 1;
        d.depth -= 1;
    }

    /// The next whole token. A string without escapes is a slice of
    /// `bytes`; one with escapes is decoded into the arena, in a buffer
    /// sized once from its raw length, which escapes only shorten.
    fn next(d: *Decoder) DecodeError!std.json.Token {
        if (try d.peek() != .string) {
            // With the whole input at hand, numbers come whole too.
            return d.scanner.next() catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.SyntaxError, error.UnexpectedEndOfInput, error.BufferUnderrun => d.syntaxError(),
            };
        }
        // The scanner stands on the opening quote.
        const quote = d.scanner.cursor;
        const end = closingQuote(d.bytes, quote);
        var decoded: std.array_list.Managed(u8) = .init(d.arena);
        if (std.mem.indexOfScalar(u8, d.bytes[quote + 1 .. end], '\\') != null) {
            try decoded.ensureTotalCapacityPrecise(end - quote - 1);
        }
        const whole = d.scanner.allocNextIntoArrayListMax(&decoded, .alloc_if_needed, d.bytes.len) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SyntaxError, error.UnexpectedEndOfInput, error.BufferUnderrun, error.ValueTooLong => return d.syntaxError(),
        };
        if (whole) |text| return .{ .string = text };
        return .{ .allocated_string = decoded.items };
    }

    fn peek(d: *Decoder) DecodeError!std.json.TokenType {
        return d.scanner.peekNextTokenType() catch d.syntaxError();
    }

    /// The scanner stops at the first byte that is not JSON. When that byte
    /// starts the first sequence that is not UTF-8, the body is not UTF-8.
    fn syntaxError(d: *Decoder) error{Invalid} {
        const bad_utf8 = if (firstInvalidUtf8(d.bytes)) |at| at <= d.scanner.cursor else false;
        return d.fail(if (bad_utf8) invalid_utf8 else invalid_json);
    }

    /// Fails about the container whose items the last step counts.
    fn failOutside(d: *Decoder, message: []const u8) error{Invalid} {
        d.path.items.len -= 1;
        return d.fail(message);
    }

    fn fail(d: *Decoder, message: []const u8) error{Invalid} {
        d.problem.* = .{ .field = d.renderPath(), .message = message };
        return error.Invalid;
    }

    /// The path in the arena, such as "items[2].name". Null at the top,
    /// for a path longer than `rules.max_field_bytes` or with a control
    /// character (both only from a client's keys, and a failure carries the
    /// path to the client, in headers too), and when the arena has no room.
    fn renderPath(d: *Decoder) ?[]const u8 {
        if (d.path.items.len == 0) return null;
        var buffer: [rules.max_field_bytes]u8 = undefined;
        var out: Writer = .fixed(&buffer);
        for (d.path.items, 0..) |step, i| switch (step) {
            .key => |key| {
                if (i > 0) out.writeByte('.') catch return null;
                out.writeAll(key) catch return null;
            },
            .index => |index| out.print("[{d}]", .{index}) catch return null,
        };
        const path = out.buffered();
        for (path) |c| {
            if (c < 0x20 or c == 0x7f) return null;
        }
        return d.arena.dupe(u8, path) catch null;
    }
};

/// The items of the array, or the members of the object, that starts right
/// before `start`, from `start` to its end: the commas at its own level,
/// plus one unless nothing is left. It reads raw bytes and checks nothing;
/// the scanner refuses what is not JSON, and a count on such input only
/// sizes a buffer.
fn countItems(bytes: []const u8, start: usize) usize {
    var depth: usize = 0;
    var commas: usize = 0;
    var empty = true;
    var i = start;
    while (i < bytes.len) : (i += 1) {
        switch (bytes[i]) {
            ' ', '\t', '\n', '\r' => {},
            '"' => {
                i = closingQuote(bytes, i);
                empty = false;
            },
            '[', '{' => {
                depth += 1;
                empty = false;
            },
            ']', '}' => {
                if (depth == 0) break;
                depth -= 1;
            },
            ',' => {
                if (depth == 0) commas += 1;
            },
            else => empty = false,
        }
    }
    return if (empty) 0 else commas + 1;
}

/// Where the string that opens at `open` ends: its closing quote, or the
/// end of `bytes`.
fn closingQuote(bytes: []const u8, open: usize) usize {
    var i = open + 1;
    while (i < bytes.len) : (i += 1) {
        switch (bytes[i]) {
            '\\' => i += 1,
            '"' => return i,
            else => {},
        }
    }
    return bytes.len;
}

/// Digits with an optional "-" in front; no "+", no leading zeros, no "-0".
fn isCanonicalInteger(text: []const u8) bool {
    const digits = if (text.len > 0 and text[0] == '-') text[1..] else text;
    if (digits.len == 0) return false;
    for (digits) |c| {
        if (c < '0' or c > '9') return false;
    }
    return digits[0] != '0' or (digits.len == 1 and digits.len == text.len);
}

/// Where the first sequence that is not UTF-8 starts; null when there is
/// none.
fn firstInvalidUtf8(bytes: []const u8) ?usize {
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] < 0x80) {
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return i;
        if (i + len > bytes.len) return i;
        _ = std.unicode.utf8Decode(bytes[i..][0..len]) catch return i;
        i += len;
    }
    return null;
}

const testing = std.testing;

/// `value` encoded, in a buffer that the test frees.
fn encoded(comptime T: type, value: T) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try encode(T, &value, &out.writer);
    return out.toOwnedSlice();
}

fn expectEncoded(comptime T: type, value: T, expected: []const u8) !void {
    const text = try encoded(T, value);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

const Color = enum { red, dark_green };
const Point = struct { x: i32, y: i32 };

test "integers up to 32 bits are numbers, wider ones are strings of digits" {
    try expectEncoded(u8, 255, "255");
    try expectEncoded(i32, std.math.minInt(i32), "-2147483648");
    try expectEncoded(u32, std.math.maxInt(u32), "4294967295");
    try expectEncoded(u1, 1, "1");
    try expectEncoded(u33, 0, "\"0\"");
    try expectEncoded(u64, std.math.maxInt(u64), "\"18446744073709551615\"");
    try expectEncoded(i64, std.math.minInt(i64), "\"-9223372036854775808\"");
    try expectEncoded(u64, 9007199254740993, "\"9007199254740993\"");
}

test "floats are finite and read back exactly" {
    try expectEncoded(f64, 1.5, "1.5");
    try expectEncoded(f64, 3, "3");
    try expectEncoded(f64, -0.0, "-0");
    try expectEncoded(f64, 0.1, "0.1");
    try expectEncoded(f32, 0.1, "0.1");
    try expectEncoded(f64, 1e20, "100000000000000000000");
    try expectEncoded(f64, 1e21, "1e21");
    try expectEncoded(f64, 1.5e-7, "1.5e-7");
    try expectEncoded(f64, 0.000001, "0.000001");
    try expectEncoded(f64, 5e-324, "5e-324");
    try expectEncoded(f64, std.math.floatMax(f64), "1.7976931348623157e308");
    try expectEncoded(f32, std.math.floatMax(f32), "3.4028235e38");
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |bad| {
        var buffer: [64]u8 = undefined;
        var w: Writer = .fixed(&buffer);
        try testing.expectError(error.NonFinite, encode(f64, &bad, &w));
    }
    const nan32 = std.math.nan(f32);
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try testing.expectError(error.NonFinite, encode(f32, &nan32, &w));
}

test "strings are UTF-8 with JSON escapes" {
    try expectEncoded([]const u8, "", "\"\"");
    try expectEncoded([]const u8, "héllo, мир 😀", "\"héllo, мир 😀\"");
    try expectEncoded([]const u8, "a\"b\\c\nd\te\x00\x1f/", "\"a\\\"b\\\\c\\nd\\te\\u0000\\u001f/\"");
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    const bad: []const u8 = "ab\xffcd";
    try testing.expectError(error.InvalidUtf8, encode([]const u8, &bad, &w));
    const surrogate: []const u8 = "\xed\xa0\x80";
    try testing.expectError(error.InvalidUtf8, encode([]const u8, &surrogate, &w));
}

test "enums are tag names, optionals null or the value, bools true and false" {
    try expectEncoded(Color, .dark_green, "\"dark_green\"");
    try expectEncoded(?u32, null, "null");
    try expectEncoded(?u32, 7, "7");
    try expectEncoded(?[]const u8, "x", "\"x\"");
    try expectEncoded(bool, true, "true");
    try expectEncoded(bool, false, "false");
}

test "slices and arrays are arrays, [N]u8 too; void is an empty object" {
    try expectEncoded([]const u32, &.{ 1, 2, 3 }, "[1,2,3]");
    try expectEncoded([]const u32, &.{}, "[]");
    try expectEncoded([3]u8, .{ 'a', 'b', 0 }, "[97,98,0]");
    try expectEncoded([0]u8, .{}, "[]");
    try expectEncoded([]const []const u8, &.{ "a", "b" }, "[\"a\",\"b\"]");
    try expectEncoded([2]Point, .{ .{ .x = 1, .y = 2 }, .{ .x = -3, .y = 4 } }, "[{\"x\":1,\"y\":2},{\"x\":-3,\"y\":4}]");
    try expectEncoded(void, {}, "{}");
}

const User = struct {
    id: u64,
    name: []const u8,
    email: ?[]const u8 = null,
    color: Color = .red,
    score: f32,
    tags: []const []const u8 = &.{},
    home: ?Point = null,
};

test "structs are objects with their fields in order, nulls written out" {
    try expectEncoded(User, .{ .id = 42, .name = "Ada", .score = 0.5 }, "{\"id\":\"42\",\"name\":\"Ada\",\"email\":null,\"color\":\"red\",\"score\":0.5,\"tags\":[],\"home\":null}");
    try expectEncoded(User, .{ .id = 1, .name = "B", .email = "b@x.io", .color = .dark_green, .score = -2, .tags = &.{"t"}, .home = .{ .x = 0, .y = -1 } }, "{\"id\":\"1\",\"name\":\"B\",\"email\":\"b@x.io\",\"color\":\"dark_green\",\"score\":-2,\"tags\":[\"t\"],\"home\":{\"x\":0,\"y\":-1}}");
    try expectEncoded(struct {}, .{}, "{}");
}

test "a writer that runs out of room stops the encoding" {
    var buffer: [8]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    const value: User = .{ .id = 42, .name = "Ada", .score = 0.5 };
    try testing.expectError(error.WriteFailed, encode(User, &value, &w));
}

/// Decodes `bytes` with `limits` in an arena of the test and checks the
/// value.
fn expectDecodedWith(comptime T: type, bytes: []const u8, limits: Limits, expected: T) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var problem: Problem = .{};
    const actual = decode(T, arena.allocator(), bytes, limits, &problem) catch |err| {
        std.debug.print("decode of {s} failed: {t} at {?s}: {s}\n", .{ bytes, err, problem.field, problem.message });
        return err;
    };
    try testing.expectEqualDeep(expected, actual);
}

fn expectDecoded(comptime T: type, bytes: []const u8, expected: T) !void {
    try expectDecodedWith(T, bytes, .{}, expected);
}

/// Checks that decoding `bytes` fails with `message` at `field`.
fn expectRefusedWith(comptime T: type, bytes: []const u8, limits: Limits, field: ?[]const u8, message: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var problem: Problem = .{};
    if (decode(T, arena.allocator(), bytes, limits, &problem)) |_| {
        std.debug.print("decode of {s} passed; expected {s} at {?s}\n", .{ bytes, message, field });
        return error.TestExpectedRefusal;
    } else |err| try testing.expectEqual(error.Invalid, err);
    testing.expectEqualStrings(message, problem.message) catch |err| {
        std.debug.print("for {s}\n", .{bytes});
        return err;
    };
    if (field) |expected| {
        testing.expectEqualStrings(expected, problem.field orelse "(null)") catch |err| {
            std.debug.print("for {s}\n", .{bytes});
            return err;
        };
    } else if (problem.field) |actual| {
        std.debug.print("for {s}: expected no field, got {s}\n", .{ bytes, actual });
        return error.TestUnexpectedField;
    }
}

fn expectRefused(comptime T: type, bytes: []const u8, field: ?[]const u8, message: []const u8) !void {
    try expectRefusedWith(T, bytes, .{}, field, message);
}

test "every kind of type decodes" {
    try expectDecoded(bool, "true", true);
    try expectDecoded(bool, " false ", false);
    try expectDecoded(u8, "255", 255);
    try expectDecoded(i32, "-2147483648", std.math.minInt(i32));
    try expectDecoded(u64, "\"18446744073709551615\"", std.math.maxInt(u64));
    try expectDecoded(i64, "\"-9223372036854775808\"", std.math.minInt(i64));
    try expectDecoded(u33, "\"0\"", 0);
    try expectDecoded(f64, "1.5", 1.5);
    try expectDecoded(f64, "-2e3", -2000);
    try expectDecoded(f64, "7", 7);
    try expectDecoded(f32, "0.1", 0.1);
    try expectDecoded(Color, "\"dark_green\"", .dark_green);
    try expectDecoded(?u32, "null", null);
    try expectDecoded(?u32, "5", 5);
    try expectDecoded([]const u8, "\"h\\u00e9llo \\\"q\\\" \\n\"", "héllo \"q\" \n");
    try expectDecoded([]const u8, "\"\\ud83d\\ude00\"", "😀");
    try expectDecoded([]const u32, "[1, 2,3]", &.{ 1, 2, 3 });
    try expectDecoded([]const u32, "[]", &.{});
    try expectDecoded([3]u8, "[97,98,0]", .{ 'a', 'b', 0 });
    try expectDecoded([]const []const u8, "[\"a\",\"\"]", &.{ "a", "" });
    try expectDecoded(void, "{}", {});
    try expectDecoded(void, "{\"anything\":[1,{\"x\":null}]}", {});
    try expectDecoded(struct {}, "{}", .{});
}

test "structs decode in any order, with defaults and null for what is missing" {
    try expectDecoded(User, "{\"score\":1,\"name\":\"Ada\",\"id\":\"7\"}", .{ .id = 7, .name = "Ada", .score = 1 });
    try expectDecoded(User, "{\"id\":\"1\",\"name\":\"B\",\"email\":\"b@x.io\",\"color\":\"dark_green\",\"score\":-2,\"tags\":[\"t\"],\"home\":{\"x\":0,\"y\":-1}}", .{ .id = 1, .name = "B", .email = "b@x.io", .color = .dark_green, .score = -2, .tags = &.{"t"}, .home = .{ .x = 0, .y = -1 } });
    const Defaults = struct { a: u32 = 5, b: ?u32 = 6, c: ?u32, d: []const u8 = "x" };
    try expectDecoded(Defaults, "{}", .{ .a = 5, .b = 6, .c = null, .d = "x" });
    try expectDecoded(Defaults, "{\"b\":null,\"c\":1}", .{ .a = 5, .b = null, .c = 1, .d = "x" });
    try expectRefused(User, "{\"id\":\"1\",\"score\":0}", "name", "missing required field");
    try expectRefused(struct { inner: Point }, "{\"inner\":{\"x\":1}}", "inner.y", "missing required field");
}

test "unknown fields are skipped" {
    try expectDecoded(Point, "{\"x\":1,\"extra\":{\"a\":[1,2,{\"b\":null}],\"c\":\"s\"},\"y\":2,\"more\":true}", .{ .x = 1, .y = 2 });
    try expectDecoded(Point, "{\"z\":[],\"x\":1,\"y\":2,\"w\":{}}", .{ .x = 1, .y = 2 });
    try expectDecoded(Point, "{\"x\":1,\"y\":2,\"X\":\"case matters\"}", .{ .x = 1, .y = 2 });
}

test "integers keep the exact form of their width" {
    try expectRefused(u64, "18446744073709551615", null, "wrong type");
    try expectRefused(u32, "\"7\"", null, "wrong type");
    try expectRefused(struct { n: u64 }, "{\"n\":1}", "n", "wrong type");
    try expectRefused(u64, "\"007\"", null, "not a canonical integer");
    try expectRefused(u64, "\"+1\"", null, "not a canonical integer");
    try expectRefused(i64, "\"-0\"", null, "not a canonical integer");
    try expectRefused(u64, "\"\"", null, "not a canonical integer");
    try expectRefused(u64, "\" 1\"", null, "not a canonical integer");
    try expectRefused(u64, "\"1e3\"", null, "not a canonical integer");
    try expectRefused(u64, "\"18446744073709551616\"", null, "number out of range");
    try expectRefused(u64, "\"-1\"", null, "number out of range");
    try expectRefused(i64, "\"9223372036854775808\"", null, "number out of range");
    try expectRefused(u8, "256", null, "number out of range");
    try expectRefused(u8, "-1", null, "number out of range");
    try expectRefused(i32, "-0", null, "not a canonical integer");
    try expectRefused(u32, "1.0", null, "not a canonical integer");
    try expectRefused(u32, "1e2", null, "not a canonical integer");
    try expectDecoded(i64, "\"-1\"", -1);
    try expectDecoded(i8, "-128", -128);
    try expectDecoded(u32, "0", 0);
}

test "floats are numbers within their type" {
    try expectRefused(f32, "1e39", null, "number out of range");
    try expectRefused(f64, "1e309", null, "number out of range");
    try expectRefused(f64, "\"1.5\"", null, "wrong type");
    try expectRefused(f64, "\"NaN\"", null, "wrong type");
    try expectRefused(f64, "NaN", null, "invalid JSON");
    try expectRefused(f64, "Infinity", null, "invalid JSON");
    try expectDecoded(f32, "1e-50", 0);
    try expectDecoded(f64, "-0", -0.0);
}

test "null only for optionals, strings only for strings, a known tag for enums" {
    try expectRefused(u32, "null", null, "wrong type");
    try expectRefused(Point, "null", null, "wrong type");
    try expectRefused(struct { s: []const u8 }, "{\"s\":null}", "s", "wrong type");
    try expectRefused([]const u8, "[104]", null, "wrong type");
    try expectRefused([3]u8, "\"abc\"", null, "wrong type");
    try expectRefused(bool, "1", null, "wrong type");
    try expectRefused(Color, "\"blue\"", null, "unknown enum value");
    try expectRefused(Color, "\"RED\"", null, "unknown enum value");
    try expectRefused(Color, "0", null, "wrong type");
    try expectRefused([]const u32, "{}", null, "wrong type");
    try expectRefused(Point, "[]", null, "wrong type");
    try expectRefused(void, "null", null, "wrong type");
    try expectRefused(void, "", null, "invalid JSON");
}

test "arrays take exactly their length" {
    try expectRefused([3]u8, "[1,2]", null, "wrong array length");
    try expectRefused([3]u8, "[1,2,3,4]", null, "wrong array length");
    try expectRefused(struct { p: [2]Point }, "{\"p\":[{\"x\":1,\"y\":1}]}", "p", "wrong array length");
    try expectDecoded([0]u8, "[]", .{});
    try expectRefused([0]u8, "[1]", null, "wrong array length");
}

test "a key may not repeat, known or not, at any depth" {
    try expectRefused(Point, "{\"x\":1,\"y\":2,\"x\":3}", "x", "duplicate key");
    try expectRefused(Point, "{\"x\":1,\"y\":2,\"z\":1,\"z\":1}", "z", "duplicate key");
    try expectRefused(Point, "{\"x\":1,\"\\u0079\":2,\"y\":3}", "y", "duplicate key");
    try expectRefused(Point, "{\"x\":1,\"y\":2,\"z\":{\"a\":1,\"b\":{\"c\":1,\"c\":2}}}", "z.b.c", "duplicate key");
    try expectRefused(Point, "{\"x\":1,\"y\":2,\"z\":[{\"a\":1},{\"a\":1,\"a\":1}]}", "z[1].a", "duplicate key");
    try expectRefused(struct { list: []const Point }, "{\"list\":[{\"x\":1,\"y\":2},{\"x\":1,\"y\":2,\"y\":3}]}", "list[1].y", "duplicate key");
    // The same unknown key in sibling objects is no repeat.
    try expectDecoded(Point, "{\"x\":1,\"y\":2,\"z\":[{\"a\":1},{\"a\":1}],\"w\":{\"a\":1}}", .{ .x = 1, .y = 2 });
}

test "the problem names the path of the value" {
    const Order = struct { items: []const struct { name: []const u8, count: u32 } };
    try expectRefused(Order, "{\"items\":[{\"name\":\"a\",\"count\":1},{\"name\":\"b\",\"count\":\"2\"}]}", "items[1].count", "wrong type");
    try expectRefused(Order, "{\"items\":[{\"name\":\"a\",\"count\":1},{\"count\":2}]}", "items[1].name", "missing required field");
    try expectRefused([]const Point, "[{\"x\":1,\"y\":2},{\"x\":true,\"y\":2}]", "[1].x", "wrong type");
    try expectRefused(Point, "{\"x\":1,\"y\":2,\"z\":[1,{\"a\":01}]}", "z[1].a", "invalid JSON");
}

test "a path longer than 256 bytes or with a control character is left out" {
    // A path of exactly 256 bytes is kept, one of 257 is not.
    const fits: [256]u8 = @splat('k');
    const body_fits = "{\"x\":1,\"y\":2,\"" ++ fits ++ "\":1,\"" ++ fits ++ "\":2}";
    try expectRefused(Point, body_fits, &fits, "duplicate key");
    const over: [257]u8 = @splat('k');
    const body_over = "{\"x\":1,\"y\":2,\"" ++ over ++ "\":1,\"" ++ over ++ "\":2}";
    try expectRefused(Point, body_over, null, "duplicate key");

    // A key of 200 000 bytes, repeated or above a subtree that is too deep.
    const key = try testing.allocator.alloc(u8, 200_000);
    defer testing.allocator.free(key);
    @memset(key, 'k');
    const repeated = try std.mem.concat(testing.allocator, u8, &.{ "{\"x\":1,\"y\":2,\"", key, "\":1,\"", key, "\":2}" });
    defer testing.allocator.free(repeated);
    try expectRefused(Point, repeated, null, "duplicate key");
    const deep = try std.mem.concat(testing.allocator, u8, &.{ "{\"x\":1,\"y\":2,\"", key, "\":" ++ @as([40]u8, @splat('[')) ++ "}" });
    defer testing.allocator.free(deep);
    try expectRefused(Point, deep, null, "too deep");

    // Control characters of a key, written as escapes.
    try expectRefused(Point, "{\"x\":1,\"y\":2,\"a\\nb\":1,\"a\\nb\":2}", null, "duplicate key");
    try expectRefused(Point, "{\"x\":1,\"y\":2,\"a\\u007fb\":1,\"a\\u007fb\":2}", null, "duplicate key");
    // Other UTF-8 stays.
    try expectRefused(Point, "{\"x\":1,\"y\":2,\"имя\":1,\"имя\":2}", "имя", "duplicate key");
}

test "broken JSON and bytes that are not UTF-8 are refused" {
    try expectRefused(Point, "{\"x\":1,\"y\":2", null, "invalid JSON");
    try expectRefused(Point, "{\"x\":1 \"y\":2}", null, "invalid JSON");
    try expectRefused(Point, "{\"x\":1,\"y\":2}x", null, "invalid JSON");
    try expectRefused(Point, "{\"x\":1,\"y\":2}{}", null, "invalid JSON");
    try expectRefused(Point, "{'x':1}", null, "invalid JSON");
    try expectRefused(struct { s: []const u8 }, "{\"s\":\"a\xffb\"}", "s", "invalid UTF-8");
    try expectRefused(struct { s: []const u8 }, "{\"s\":\"\xc3\"}", "s", "invalid UTF-8");
    try expectRefused(struct { s: []const u8 }, "{\"s\":\"\xed\xa0\x80\"}", "s", "invalid UTF-8");
    try expectRefused(Point, "{\"x\":1,\"y\":2,\"z\":\"\xff\"}", "z", "invalid UTF-8");
    try expectRefused(Point, "\xff", null, "invalid UTF-8");
    // Broken JSON first, bytes that are not UTF-8 later: the first fault wins.
    try expectRefused(struct { s: []const u8 }, "{\"s\":,\"\xff\"}", "s", "invalid JSON");
    try expectRefused(struct { s: []const u8 }, "{\"s\":\"\\ud800\"}", "s", "invalid JSON");
}

test "the items of a container are counted from the raw bytes, strings and nesting skipped" {
    // `start` is right after the opening bracket, where the scanner leaves it.
    try testing.expectEqual(@as(usize, 0), countItems("[]", 1));
    try testing.expectEqual(@as(usize, 0), countItems("[ \n\t]", 1));
    try testing.expectEqual(@as(usize, 1), countItems("[0]", 1));
    try testing.expectEqual(@as(usize, 3), countItems("[1, [2, 3], {\"a\": [4, 5]}]", 1));
    try testing.expectEqual(@as(usize, 2), countItems("[\"a,b]\", \"c\\\",d\"]", 1));
    try testing.expectEqual(@as(usize, 2), countItems("{\"a,\": 1, \"b\": {\"c\": 2, \"d\": 3}}", 1));
    // A count stops at the end of its own container.
    try testing.expectEqual(@as(usize, 3), countItems("[[1,2,3],4]", 2));
    // Right after a key: that member and the rest.
    try testing.expectEqual(@as(usize, 2), countItems("{\"a\":1,\"b\":2,\"c\":3}", 10));
    // Input that is not JSON only sizes a buffer.
    try testing.expectEqual(@as(usize, 2), countItems("[1,2", 1));
    try testing.expectEqual(@as(usize, 1), countItems("[\"open", 1));
    try testing.expectEqual(@as(usize, 5), closingQuote("\"a\\\"b\" x", 0));
    try testing.expectEqual(@as(usize, 4), closingQuote("\"ab\\", 0));
}

test "depth and items have limits, in skipped values too" {
    const limits: Limits = .{ .max_depth = 3, .max_items = 3 };
    try expectDecodedWith(struct { a: []const []const u32 }, "{\"a\":[[]]}", limits, .{ .a = &.{&.{}} });
    try expectDecodedWith(Point, "{\"x\":1,\"y\":2,\"z\":[[1,2,3]]}", limits, .{ .x = 1, .y = 2 });
    try expectRefusedWith(Point, "{\"x\":1,\"y\":2,\"z\":[[[1]]]}", limits, "z[0][0]", "too deep");
    try expectRefusedWith(Point, "{\"x\":1,\"y\":2,\"z\":[1,2,3,4]}", limits, "z", "too many items");
    try expectRefusedWith(Point, "{\"x\":1,\"y\":2,\"z\":{\"a\":1,\"b\":2,\"c\":3,\"d\":4}}", limits, "z", "too many items");
    try expectRefusedWith(Point, "{\"x\":1,\"y\":2,\"z\":1,\"w\":1}", limits, null, "too many items");
    try expectRefusedWith([]const u32, "[1,2,3,4]", limits, null, "too many items");
    try expectDecodedWith([]const u32, "[1,2,3]", limits, &.{ 1, 2, 3 });
    try expectRefusedWith([4]u32, "[1,2,3,4]", limits, null, "too many items");
    try expectRefusedWith([]const []const []const []const u32, "[[[[1]]]]", limits, "[0][0][0]", "too deep");
    try expectDecodedWith([]const []const []const u32, "[[[1]]]", limits, &.{&.{&.{1}}});
}
