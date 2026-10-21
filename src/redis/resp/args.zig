//! The arguments of commands: values that become bulk strings, by one
//! table for every command that takes a value (`set`, `rpush`, the fields
//! of `hset` and `xadd`, `raw`, the arguments of scripts).
//!
//! | Zig                                  | On the wire                        |
//! |--------------------------------------|------------------------------------|
//! | a string (`[]const u8`, a literal)   | as it is, any byte included        |
//! | an integer of any width              | its decimal text                   |
//! | a float                              | its shortest text that reads back as the same float; `inf`, `-inf` |
//! | `bool`                               | `1` or `0`                         |
//! | an exhaustive enum, an enum literal  | the name of its tag                |
//! | a list of strings, where allowed     | one argument per string            |
//!
//! NaN is refused by `check` before anything is written: a server takes
//! none. Anything else, a struct, a union, a pointer, an optional or a
//! non-exhaustive enum, stops the build with the message of `checkType`,
//! which names the call and the place of the value.
//!
//! - `checkType(T, call, what, lists)` — the comptime check.
//! - `check(value)` — the check at run time: NaN.
//! - `count(value)` — how many arguments `value` writes.
//! - `write(w, value)` — writes them.
//! - `formatFloat(buffer, value)` — the text of a float, as `write` gives
//!   it.

const std = @import("std");
const Writer = @import("Writer.zig");

/// Whether `T` is a string: a slice of bytes, or a pointer to an array of
/// them, such as a string literal.
pub fn isString(comptime T: type) bool {
    const info = switch (@typeInfo(T)) {
        .pointer => |p| p,
        else => return false,
    };
    return switch (info.size) {
        .slice => info.child == u8,
        .one => switch (@typeInfo(info.child)) {
            .array => |array| array.child == u8,
            else => false,
        },
        else => false,
    };
}

/// Whether `T` is a list of strings: a slice of strings, or a pointer to
/// an array of them.
pub fn isStringList(comptime T: type) bool {
    const info = switch (@typeInfo(T)) {
        .pointer => |p| p,
        else => return false,
    };
    return switch (info.size) {
        .slice => isString(info.child),
        .one => switch (@typeInfo(info.child)) {
            .array => |array| isString(array.child),
            else => false,
        },
        else => false,
    };
}

/// Stops the build unless a value of `T` can be written as arguments.
/// `call` names the function, such as "redis.cmd.raw", and `what` the
/// place of the value, such as "args[2]" or "field 'age'"; `lists` says
/// whether a list of strings may stand there.
pub fn checkType(comptime T: type, comptime call: []const u8, comptime what: []const u8, comptime lists: bool) void {
    const prefix = call ++ ": " ++ what ++ " is " ++ @typeName(T);
    const kinds = "an argument is a string, an integer, a float, a bool or an enum";
    if (comptime isString(T)) return;
    if (comptime isStringList(T)) {
        if (lists) return;
        @compileError(prefix ++ ", a list of strings: it stands for one value here; keep a list in a key of its own");
    }
    switch (@typeInfo(T)) {
        .int, .comptime_int, .float, .comptime_float, .bool, .enum_literal => {},
        .@"enum" => |info| if (info.mode != .exhaustive) {
            @compileError(prefix ++ ", a non-exhaustive enum: a value without a tag has no name to write; make the enum exhaustive");
        },
        .optional => @compileError(prefix ++ ": an argument cannot be null; unwrap it, or leave it out where it is null"),
        .@"struct" => @compileError(prefix ++ ", a struct: " ++ kinds ++ "; pass its fields as arguments of their own"),
        .@"union" => @compileError(prefix ++ ", a union: " ++ kinds ++ "; pass the value of its variant"),
        .pointer => |info| if (info.size == .slice) {
            @compileError(prefix ++ ": " ++ kinds ++ ", and a list of them is a slice of strings; write other values as arguments of their own");
        } else {
            @compileError(prefix ++ ", a pointer: " ++ kinds ++ "; pass the value itself, or a string as []const u8");
        },
        else => @compileError(prefix ++ ": " ++ kinds),
    }
}

/// The check that only run time can make: NaN is InvalidArgument.
pub fn check(value: anytype) error{InvalidArgument}!void {
    switch (@typeInfo(@TypeOf(value))) {
        .float => if (std.math.isNan(value)) return error.InvalidArgument,
        .comptime_float => if (std.math.isNan(@as(f64, value))) return error.InvalidArgument,
        else => {},
    }
}

/// How many arguments `value` writes: one per string of a list, one for
/// anything else.
pub fn count(value: anytype) usize {
    return if (comptime isStringList(@TypeOf(value))) value.len else 1;
}

/// Writes `value` as bulk strings, by the table above. The caller has
/// checked its type with `checkType` and its value with `check`.
pub fn write(w: Writer, value: anytype) Writer.Error!void {
    const T = @TypeOf(value);
    comptime checkType(T, "redis.cmd", "an argument", true);
    if (comptime isString(T)) return w.bulk(value);
    if (comptime isStringList(T)) {
        for (value) |string| try w.bulk(string);
        return;
    }
    switch (@typeInfo(T)) {
        .comptime_int => return w.bulk(std.fmt.comptimePrint("{d}", .{value})),
        .int => {
            var buffer: [intTextLen(T)]u8 = undefined;
            return w.bulk(buffer[0..std.fmt.printInt(&buffer, value, 10, .lower, .{})]);
        },
        .float, .comptime_float => {
            var buffer: [float_buffer_len]u8 = undefined;
            return w.bulk(formatFloat(&buffer, value));
        },
        .bool => return w.bulk(if (value) "1" else "0"),
        .@"enum", .enum_literal => return w.bulk(@tagName(value)),
        // checkType above refuses every other type.
        else => unreachable,
    }
}

/// The most bytes the decimal text of an integer of type `T` takes.
fn intTextLen(comptime T: type) comptime_int {
    return @max(std.fmt.count("{d}", .{std.math.maxInt(T)}), std.fmt.count("{d}", .{std.math.minInt(T)}));
}

/// The size of the buffer of `formatFloat`: the scientific text of any
/// float fits it.
pub const float_buffer_len = 64;

/// The shortest text of `value` that reads back as the same float: its
/// shortest digits, in decimal or in scientific notation, whichever is
/// shorter (`12.5`, `1e300`, `5e-324`, `-0`); `inf`, `-inf` and `nan`. A
/// `comptime_float` is written as the f64 it becomes on the server.
pub fn formatFloat(buffer: *[float_buffer_len]u8, value: anytype) []const u8 {
    const v = if (@TypeOf(value) == comptime_float) @as(f64, value) else value;
    // Without a precision, scientific notation fits 53 bytes and never
    // fails; decimal notation fails with BufferTooSmall when it would be
    // longer than the buffer, and then scientific is shorter anyway.
    const scientific = std.fmt.float.render(buffer, v, .{ .mode = .scientific }) catch unreachable;
    var decimal_buffer: [float_buffer_len]u8 = undefined;
    const decimal = std.fmt.float.render(&decimal_buffer, v, .{ .mode = .decimal }) catch return scientific;
    if (decimal.len > scientific.len) return scientific;
    @memcpy(buffer[0..decimal.len], decimal);
    return buffer[0..decimal.len];
}
