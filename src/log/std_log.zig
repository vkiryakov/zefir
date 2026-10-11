//! The bridge from `std.log`. In the root file:
//!
//! ```zig
//! pub const std_options: std.Options = .{ .logFn = zefir.log.stdLogFn };
//! ```
//!
//! then `logger.installStdLog()` after `init`. Until a logger is installed,
//! and after it is removed, std.log writes as `std.log.defaultLog` does.

const std = @import("std");
const Engine = @import("Engine.zig");
const Level = @import("level.zig").Level;

/// The engine std.log records go to.
var target: std.atomic.Value(?*Engine) = .init(null);
/// stdLogFn calls in progress, so removing the target can wait for them.
var in_flight: std.atomic.Value(u32) = .init(0);

/// The `logFn` for `std_options`. std.log's scope becomes the record's
/// scope (none for `.default`) and its formatted text the message; the
/// logger's levels apply after std's own compile-time filter.
pub fn stdLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = in_flight.fetchAdd(1, .seq_cst);
    defer _ = in_flight.fetchSub(1, .seq_cst);
    const engine = target.load(.seq_cst) orelse return std.log.defaultLog(message_level, scope, format, args);
    const level = comptime levelOf(message_level);
    const entry = if (scope == .default) &engine.scope_table.root else engine.scope_table.find(@tagName(scope));
    if (@backingInt(level) < @backingInt(entry.level.load(.monotonic))) return;
    engine.emitFormatted(level, entry, format, args);
}

fn levelOf(comptime level: std.log.Level) Level {
    return switch (level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
}

/// Sends std.log records to `engine` from now on.
pub fn install(engine: *Engine) void {
    target.store(engine, .seq_cst);
}

/// Sends std.log back to `std.log.defaultLog`, once the calls in progress
/// have finished. `Logger.deinit` does this for the logger it ends.
pub fn uninstall() void {
    target.store(null, .seq_cst);
    waitIdle();
}

/// `uninstall`, if `engine` is the one installed.
pub fn uninstallIf(engine: *Engine) void {
    if (target.cmpxchgStrong(engine, null, .seq_cst, .seq_cst) == null) waitIdle();
}

/// The installed engine, if any.
pub fn installed() ?*Engine {
    return target.load(.seq_cst);
}

/// A call that loaded the target before it was removed has added itself to
/// `in_flight` first (both are seq_cst), so this wait sees it.
fn waitIdle() void {
    while (in_flight.load(.seq_cst) != 0) std.atomic.spinLoopHint();
}

test "std.log levels map to records' levels by name" {
    try std.testing.expectEqual(Level.err, levelOf(.err));
    try std.testing.expectEqual(Level.warn, levelOf(.warn));
    try std.testing.expectEqual(Level.info, levelOf(.info));
    try std.testing.expectEqual(Level.debug, levelOf(.debug));
}
