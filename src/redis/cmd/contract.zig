//! The contract of a command type: what the value that a function of
//! `redis.cmd` returns declares, so that the client can run it. It is
//! internal to the module and may change; a command that the catalog lacks
//! is made with `cmd.raw`, not with a type of one's own.
//!
//! A command type `C` is a struct. Its value holds what the command
//! borrows, slices of keys and values and numbers, and no state: it may be
//! built ahead and run many times while its slices live. `C` declares:
//!
//! - `pub const Reply: type` — what running it returns. The decoder reads
//!   the reply into it, so `C` checks it with `resp.checkReply`, whose
//!   message names the function of `cmd`.
//! - `pub fn check(c: C, diagnostics: ?*Diagnostics) error{InvalidArgument}!void`
//!   — the rules that only run time sees: an empty list, a duration under
//!   1 ms, NaN. The client checks every command of a call before it sends
//!   anything; the reason goes to the diagnostics.
//! - `pub fn write(c: C, w: resp.Writer) resp.Writer.Error!void` — the
//!   command as an array of bulk strings, into the buffer of the
//!   connection: the same bytes each time.
//! - `pub fn read(c: C, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!Reply`
//!   — its reply, by the rules of `resp.decode`: after ServerError and
//!   UnexpectedReply the reply is read to its end.
//! - `pub fn name(c: C) []const u8` — the name of the command, such as
//!   "GET", for the client's texts about it; never a value.
//!
//! Declarations that tell the client more about a command come with the
//! commands that need them: the scope of a command that keeps state on
//! its connection (WATCH), where a blocking command takes its timeout and
//! in which units, the cursor of a SCAN command.

/// The type of the reply of the command type `C`; a compile error that
/// starts with `call` when `C` is not one.
pub fn ReplyOf(comptime C: type, comptime call: []const u8) type {
    comptime {
        const is_command = @typeInfo(C) == .@"struct" and @hasDecl(C, "Reply") and
            @hasDecl(C, "check") and @hasDecl(C, "write") and @hasDecl(C, "read") and @hasDecl(C, "name");
        if (!is_command) @compileError(call ++ ": " ++ @typeName(C) ++ " is not a command: make one with redis.cmd, such as redis.cmd.get([]const u8, key)");
        return C.Reply;
    }
}
