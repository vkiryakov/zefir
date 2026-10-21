//! `cmd.raw(T, args)`: a command that the catalog lacks, with its reply
//! read into `T` by the rules of the decoder. `args` is a tuple of values
//! by the rules of arguments, the name of the command first, such as
//! `.{ "ZADD", "leaders", 12.5, "ann" }`, or a slice of strings for a
//! command built at run time. A list of strings in the tuple stands for as
//! many arguments: `.{ "DEL", keys }`.

const std = @import("std");
const resp = @import("../resp.zig");
const Diagnostics = @import("../errors.zig").Diagnostics;

const args = resp.args;
const call = "redis.cmd.raw";

/// The command of `arguments`, whose reply reads into `T`.
pub fn raw(comptime T: type, arguments: anytype) Raw(T, @TypeOf(arguments)) {
    return .{ .args = arguments };
}

/// The type of `cmd.raw(T, args)` for arguments of type `Args`.
pub fn Raw(comptime T: type, comptime Args: type) type {
    comptime {
        resp.checkReply(T, call);
        checkArgs(Args);
    }
    const is_list = args.isStringList(Args);
    const fields = if (is_list) 0 else @typeInfo(Args).@"struct".field_types.len;
    return struct {
        args: Args,

        pub const Reply = T;

        /// No arguments, or one that is NaN, is InvalidArgument.
        pub fn check(c: @This(), diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
            if (c.count() == 0) return invalid(diagnostics, call ++ ": no arguments: the first is the name of the command", .{});
            inline for (0..fields) |i| {
                args.check(c.args[i]) catch return invalid(diagnostics, call ++ ": args[{d}] is NaN, which a server does not take", .{i});
            }
        }

        pub fn write(c: @This(), w: resp.Writer) resp.Writer.Error!void {
            try w.arrayHeader(c.count());
            if (is_list) return args.write(w, c.args);
            inline for (0..fields) |i| try args.write(w, c.args[i]);
        }

        pub fn read(_: @This(), r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!T {
            return resp.decode(T, r, arena, diagnostics);
        }

        fn count(c: @This()) usize {
            if (is_list) return c.args.len;
            var n: usize = 0;
            inline for (0..fields) |i| n += args.count(c.args[i]);
            return n;
        }
    };
}

/// Stops the build unless `Args` is a tuple of arguments or a slice of
/// strings.
fn checkArgs(comptime Args: type) void {
    if (args.isStringList(Args)) return;
    const is_tuple = switch (@typeInfo(Args)) {
        .@"struct" => |info| info.is_tuple,
        else => false,
    };
    if (!is_tuple) @compileError(call ++ ": the arguments are a tuple, such as .{ \"GET\", key }, or a slice of strings; got " ++ @typeName(Args));
    for (@typeInfo(Args).@"struct".field_types, 0..) |F, i| {
        args.checkType(F, call, std.fmt.comptimePrint("args[{d}]", .{i}), true);
    }
}

fn invalid(diagnostics: ?*Diagnostics, comptime fmt: []const u8, values: anytype) error{InvalidArgument} {
    if (diagnostics) |d| d.set(null, null, fmt, values);
    return error.InvalidArgument;
}
