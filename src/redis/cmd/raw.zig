//! `cmd.raw(T, args)`: a command that the catalog lacks, with its reply
//! read into `T` by the rules of the decoder. `args` is a tuple of values
//! by the rules of arguments, the name of the command first, such as
//! `.{ "ZADD", "leaders", 12.5, "ann" }`, or a slice of strings for a
//! command built at run time. A list of strings in the tuple stands for as
//! many arguments: `.{ "DEL", keys }`.
//!
//! The commands that change the state of their connection are refused
//! before anything goes out, with what to use instead: the connections of
//! the pool go from call to call, and the next call would inherit that
//! state. The name is matched in any case, CLIENT with its subcommand:
//! HELLO, AUTH, RESET, SELECT, QUIT, MULTI, EXEC, DISCARD, WATCH, UNWATCH,
//! SUBSCRIBE, PSUBSCRIBE, SSUBSCRIBE, UNSUBSCRIBE, PUNSUBSCRIBE,
//! SUNSUBSCRIBE, MONITOR, SYNC, PSYNC, REPLCONF, CLIENT REPLY, CLIENT
//! TRACKING, CLIENT CACHING, READONLY, READWRITE and ASKING.
//!
//! A blocking command through `raw` waits only as long as the deadline of
//! its call: its timeout is not taken from the deadline as for the
//! blocking commands of the catalog. Give it one shorter than what is left
//! of the deadline by 150 ms at least, for a quiet server answers a
//! timeout up to 100 ms late.

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

        /// No arguments, one that is NaN, or a command that changes the
        /// state of its connection is InvalidArgument.
        pub fn check(c: @This(), diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
            if (c.count() == 0) return invalid(diagnostics, call ++ ": no arguments: the first is the name of the command", .{});
            inline for (0..fields) |i| {
                args.check(c.args[i]) catch return invalid(diagnostics, call ++ ": args[{d}] is NaN, which a server does not take", .{i});
            }
            if (banned(c.word(0), c.word(1))) |ban| {
                return invalid(diagnostics, call ++ ": {s}{s}{s} {s}", .{ ban.name, if (ban.sub == null) "" else " ", ban.sub orelse "", ban.why });
            }
        }

        /// The argument number `i` as a word, a string or the name of an
        /// enum, for the name of the command and its subcommand; null for
        /// a number or a bool, or past the end.
        fn word(c: @This(), i: usize) ?[]const u8 {
            if (is_list) return if (i < c.args.len) c.args[i] else null;
            var at: usize = 0;
            inline for (0..fields) |f| {
                const arg = c.args[f];
                const Arg = @TypeOf(arg);
                if (comptime args.isStringList(Arg)) {
                    for (arg) |item| {
                        if (at == i) return item;
                        at += 1;
                    }
                } else {
                    if (at == i) return if (comptime args.isString(Arg)) arg else switch (@typeInfo(Arg)) {
                        .@"enum", .enum_literal => @tagName(arg),
                        else => null,
                    };
                    at += 1;
                }
            }
            return null;
        }

        pub fn write(c: @This(), w: resp.Writer) resp.Writer.Error!void {
            try w.arrayHeader(c.count());
            if (is_list) return args.write(w, c.args);
            inline for (0..fields) |i| try args.write(w, c.args[i]);
        }

        pub fn read(_: @This(), r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!T {
            return resp.decode(T, r, arena, diagnostics);
        }

        /// The first argument, the name of the command, when it is a
        /// string or an enum; "the command" otherwise.
        pub fn name(c: @This()) []const u8 {
            const unnamed = "the command";
            if (is_list) return if (c.args.len > 0) c.args[0] else unnamed;
            if (fields == 0) return unnamed;
            const First = @TypeOf(c.args[0]);
            if (comptime args.isString(First)) return c.args[0];
            if (comptime args.isStringList(First)) return if (c.args[0].len > 0) c.args[0][0] else unnamed;
            return switch (@typeInfo(First)) {
                .@"enum", .enum_literal => @tagName(c.args[0]),
                else => unnamed,
            };
        }

        fn count(c: @This()) usize {
            if (is_list) return c.args.len;
            var n: usize = 0;
            inline for (0..fields) |i| n += args.count(c.args[i]);
            return n;
        }
    };
}

/// A command that `raw` refuses: it changes the state of its connection.
const Ban = struct {
    name: []const u8,
    /// The subcommand, for CLIENT.
    sub: ?[]const u8 = null,
    /// What it does to the connection, and what to use instead.
    why: []const u8,
};

const handshake = "changes the protocol or the user of the connection, which later calls on it would inherit: the handshake of the client sets them, from the URL and the options";
const in_transaction = "would leave the connection inside a transaction: use conn.transaction";
const holds_keys = "holds keys on the connection: use redis.cmd.watch and redis.cmd.unwatch on a connection of client.acquire";
const pushes = "would turn the connection over to pushes: use client.subscribe";
const silent = "makes the connection stop answering commands; the client does not run it";
const tracking = "makes the server send pushes about the keys of a cache of the client; the client does not run it";
const cluster = "is a command of a cluster, and v0.1 talks to one standalone server; the client does not run it";

const bans = [_]Ban{
    .{ .name = "HELLO", .why = handshake },
    .{ .name = "AUTH", .why = handshake },
    .{ .name = "RESET", .why = handshake },
    .{ .name = "SELECT", .why = "would send the later calls on the connection to another database: put the database in the path of the URL" },
    .{ .name = "QUIT", .why = "closes the connection: use client.close" },
    .{ .name = "MULTI", .why = in_transaction },
    .{ .name = "EXEC", .why = in_transaction },
    .{ .name = "DISCARD", .why = in_transaction },
    .{ .name = "WATCH", .why = holds_keys },
    .{ .name = "UNWATCH", .why = holds_keys },
    .{ .name = "SUBSCRIBE", .why = pushes },
    .{ .name = "PSUBSCRIBE", .why = pushes },
    .{ .name = "SSUBSCRIBE", .why = pushes },
    .{ .name = "UNSUBSCRIBE", .why = pushes },
    .{ .name = "PUNSUBSCRIBE", .why = pushes },
    .{ .name = "SUNSUBSCRIBE", .why = pushes },
    .{ .name = "MONITOR", .why = silent },
    .{ .name = "SYNC", .why = silent },
    .{ .name = "PSYNC", .why = silent },
    .{ .name = "REPLCONF", .why = silent },
    .{ .name = "CLIENT", .sub = "REPLY", .why = "breaks the count of replies; the client does not run it" },
    .{ .name = "CLIENT", .sub = "TRACKING", .why = tracking },
    .{ .name = "CLIENT", .sub = "CACHING", .why = tracking },
    .{ .name = "READONLY", .why = cluster },
    .{ .name = "READWRITE", .why = cluster },
    .{ .name = "ASKING", .why = cluster },
};

/// The ban of the command `name` with the next word `sub`, in any case.
fn banned(name: ?[]const u8, sub: ?[]const u8) ?Ban {
    const command = name orelse return null;
    for (bans) |ban| {
        if (!std.ascii.eqlIgnoreCase(ban.name, command)) continue;
        const wanted = ban.sub orelse return ban;
        if (sub) |next| if (std.ascii.eqlIgnoreCase(wanted, next)) return ban;
    }
    return null;
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
