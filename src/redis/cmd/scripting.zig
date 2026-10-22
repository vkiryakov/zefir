//! The script commands of `redis.cmd`: EVAL of a text, and the script of a
//! `redis.Script` by its SHA1.
//!
//! The keys of a script are a slice of strings, its KEYS, and its
//! arguments, its ARGV, a tuple of values by the rules of arguments or a
//! slice of strings; either may be empty. What the script returns reads
//! into `T` as the server converts it: a number is an integer, its
//! fraction dropped; a table is an array; `false` is null and `true` 1; an
//! error, `{err = …}` or `redis.error_reply`, is a ServerError with its
//! code. A script that fails halfway keeps what it wrote before.
//!
//! ```zig
//! const left = try client.run(io, op, redis.cmd.evalScript(i64, &take_ticket, &.{"tickets:concert"}, .{}), .{});
//! ```

const std = @import("std");
const resp = @import("../resp.zig");
const command = @import("command.zig");
const Script = @import("../Script.zig");
const Diagnostics = @import("../errors.zig").Diagnostics;

const args = resp.args;
const Keys = []const []const u8;

/// EVAL `source` `numkeys` `keys`… `args`…: runs the script of the text
/// `source`, sent with the call, and reads what it returns into `T`.
pub fn eval(comptime T: type, source: []const u8, keys: Keys, arguments: anytype) Eval(T, command.Values(@TypeOf(arguments), "redis.cmd.eval", "args")) {
    return .{ .source = source, .keys = keys, .args = command.values(arguments, "redis.cmd.eval", "args") };
}

pub fn Eval(comptime T: type, comptime A: type) type {
    const call = "redis.cmd.eval";
    comptime resp.checkReply(T, call);
    return struct {
        source: []const u8,
        keys: Keys,
        args: A,

        const Self = @This();

        pub const Reply = T;

        pub fn check(c: Self, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
            return checkArgs(c.args, call, diagnostics);
        }

        pub fn write(c: Self, w: resp.Writer) resp.Writer.Error!void {
            return writeScript(w, "EVAL", c.source, c.keys, c.args);
        }

        pub fn read(_: Self, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!T {
            return resp.decode(T, r, arena, diagnostics);
        }

        pub fn name(_: Self) []const u8 {
            return "EVAL";
        }
    };
}

/// The script of `script`, as `eval` runs a text. Alone in `run`, it goes
/// out as EVALSHA `sha1` `numkeys` `keys`… `args`…; a server that lacks
/// the script answers NOSCRIPT, having run nothing, and its text follows
/// as EVAL on the same connection. In a pipeline and a transaction it goes
/// out as EVAL at once: a second try there would come after the commands
/// behind it, or after EXEC.
pub fn evalScript(comptime T: type, script: *const Script, keys: Keys, arguments: anytype) EvalScript(T, command.Values(@TypeOf(arguments), "redis.cmd.evalScript", "args")) {
    return .{ .script = script, .keys = keys, .args = command.values(arguments, "redis.cmd.evalScript", "args") };
}

pub fn EvalScript(comptime T: type, comptime A: type) type {
    const call = "redis.cmd.evalScript";
    comptime resp.checkReply(T, call);
    return struct {
        script: *const Script,
        keys: Keys,
        args: A,

        const Self = @This();

        pub const Reply = T;

        pub fn check(c: Self, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
            return checkArgs(c.args, call, diagnostics);
        }

        /// EVAL with the text of the script.
        pub fn write(c: Self, w: resp.Writer) resp.Writer.Error!void {
            return writeScript(w, "EVAL", c.script.source, c.keys, c.args);
        }

        /// EVALSHA with its SHA1.
        pub fn writeSha(c: Self, w: resp.Writer) resp.Writer.Error!void {
            return writeScript(w, "EVALSHA", &c.script.sha1, c.keys, c.args);
        }

        pub fn read(_: Self, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!T {
            return resp.decode(T, r, arena, diagnostics);
        }

        pub fn name(_: Self) []const u8 {
            return "EVALSHA";
        }
    };
}

/// An argument that is NaN is InvalidArgument.
fn checkArgs(arguments: anytype, comptime call: []const u8, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
    if (comptime @TypeOf(arguments) != []const []const u8) {
        inline for (0..@typeInfo(@TypeOf(arguments)).@"struct".field_types.len) |i| {
            args.check(arguments[i]) catch return command.invalid(diagnostics, call ++ ": args[{d}] is NaN, which a server does not take", .{i});
        }
    }
}

fn writeScript(w: resp.Writer, word: []const u8, script: []const u8, keys: Keys, arguments: anytype) resp.Writer.Error!void {
    const strings = comptime @TypeOf(arguments) == []const []const u8;
    var n: usize = 3 + keys.len;
    if (strings) {
        n += arguments.len;
    } else inline for (0..@typeInfo(@TypeOf(arguments)).@"struct".field_types.len) |i| {
        n += args.count(arguments[i]);
    }
    try w.arrayHeader(n);
    try w.bulk(word);
    try w.bulk(script);
    try args.write(w, keys.len);
    for (keys) |key| try w.bulk(key);
    if (strings) {
        for (arguments) |argument| try w.bulk(argument);
    } else inline for (0..@typeInfo(@TypeOf(arguments)).@"struct".field_types.len) |i| {
        try args.write(w, arguments[i]);
    }
}
