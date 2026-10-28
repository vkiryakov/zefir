//! The payload of a run as JSON: what `Client.schedule` writes into a
//! record, and what the worker and `Record.payloadAs` read back.

const std = @import("std");
const Allocator = std.mem.Allocator;
const job_type = @import("Job.zig");
const PayloadOf = job_type.PayloadOf;

/// Why a payload does not read as the job's `Payload`.
pub const DecodeError = std.json.ParseError(std.json.Scanner);

/// The JSON of `value` in `arena`, by `std.json.Stringify` with its default
/// options; `{}` for a job without `Payload`. Check `validUtf8(value)`
/// first: a string that is not UTF-8 is written as an array of numbers.
pub fn encode(comptime J: type, arena: Allocator, value: PayloadOf(J)) error{OutOfMemory}![]const u8 {
    if (comptime !job_type.hasPayload(J)) return "{}";
    return std.json.Stringify.valueAlloc(arena, value, .{});
}

/// Whether every string in `value`, a slice or an array of bytes at any
/// depth, is UTF-8. `std.json.Stringify` writes one that is not as an array
/// of numbers, which reads back, but is no string to anyone else. A type
/// with its own `jsonStringify` writes itself and is not looked into.
pub fn validUtf8(value: anytype) bool {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => if (@hasDecl(T, "jsonStringify")) return true,
        else => {},
    }
    switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.field_names) |name| {
            if (!validUtf8(@field(value, name))) return false;
        },
        .optional => if (value) |inner| return validUtf8(inner),
        .@"union" => |u| if (u.tag_type != null) switch (value) {
            inline else => |inner| return validUtf8(inner),
        },
        .array => return validUtf8(@as([]const std.meta.Elem(T), &value)),
        .pointer => |p| switch (p.size) {
            .one => return validUtf8(value.*),
            .slice => {
                if (p.child == u8) return std.unicode.utf8ValidateSlice(value);
                for (value) |item| if (!validUtf8(item)) return false;
            },
            .many => if (p.sentinel() != null) return validUtf8(std.mem.span(value)),
            .c => {},
        },
        else => {},
    }
    return true;
}

/// The payload of `J` read from `json`, with every string in `arena`. A
/// field the type does not know is skipped and a missing one takes its
/// default, so the records of an older or a newer version still read. A
/// job without `Payload` reads any object.
pub fn decode(comptime J: type, arena: Allocator, json: []const u8) DecodeError!PayloadOf(J) {
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };
    if (comptime !job_type.hasPayload(J)) {
        _ = try std.json.parseFromSliceLeaky(struct {}, arena, json, options);
        return;
    }
    return std.json.parseFromSliceLeaky(J.Payload, arena, json, options);
}
