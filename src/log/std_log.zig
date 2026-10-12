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
/// stdLogFn calls in progress that may use an engine, counted in two
/// generations: removing an engine starts a new generation and waits for
/// the calls of the old one only, so steady std.log traffic cannot hold
/// the removal up.
var in_flight: [2]std.atomic.Value(u32) = .{ .init(0), .init(0) };
var generation: std.atomic.Value(u32) = .init(0);
/// Removals flip the generation one at a time.
var removing: std.atomic.Mutex = .unlocked;

/// The `logFn` for `std_options`. std.log's scope becomes the record's
/// scope (none for `.default`) and its formatted text the message; the
/// logger's levels apply after std's own compile-time filter. The
/// arguments are formatted by std.fmt, not walked by the logger, so
/// redaction does not reach inside them.
pub fn stdLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const counter = enter();
    const engine = target.load(.seq_cst) orelse {
        // Leave first: a call into std's own log holds no engine.
        _ = counter.fetchSub(1, .seq_cst);
        return std.log.defaultLog(message_level, scope, format, args);
    };
    defer _ = counter.fetchSub(1, .seq_cst);
    const level = comptime levelOf(message_level);
    const entry = if (scope == .default) &engine.scope_table.root else engine.scope_table.find(@tagName(scope));
    if (@backingInt(level) < @backingInt(entry.level.load(.monotonic))) return;
    engine.emitFormatted(level, entry, format, args);
}

/// Counts the call in the current generation, and returns its counter.
fn enter() *std.atomic.Value(u32) {
    while (true) {
        if (count(generation.load(.seq_cst))) |counter| return counter;
    }
}

/// Counts the call in generation `g`, read before; null, and not counted,
/// when a removal has flipped `g` since.
fn count(g: u32) ?*std.atomic.Value(u32) {
    const counter = &in_flight[g & 1];
    _ = counter.fetchAdd(1, .seq_cst);
    // Counted before any removal that flips `g`: that removal waits.
    if (generation.load(.seq_cst) == g) return counter;
    _ = counter.fetchSub(1, .seq_cst);
    return null;
}

fn levelOf(comptime level: std.log.Level) Level {
    return switch (level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
}

/// Sends std.log records to `engine` from now on, in place of the engine
/// installed before.
pub fn install(engine: *Engine) void {
    target.store(engine, .seq_cst);
}

/// Sends std.log back to `std.log.defaultLog`, once the calls that may be
/// using the removed engine have finished. Must not be called from inside
/// a log call.
pub fn uninstall() void {
    target.store(null, .seq_cst);
    waitForCalls();
}

/// For `Logger.deinit`: removes `engine` if it is installed, and waits for
/// the calls that may still be inside it, also when std.log had already
/// moved on to another engine.
pub fn uninstallIf(engine: *Engine) void {
    _ = target.cmpxchgStrong(engine, null, .seq_cst, .seq_cst);
    waitForCalls();
}

/// The installed engine, if any.
pub fn installed() ?*Engine {
    return target.load(.seq_cst);
}

/// Waits for the calls counted before now. A call that went on to use a
/// removed engine loaded the target before the removal, so it entered
/// before this flip and is counted in the old generation (all seq_cst);
/// calls that enter later count in the new one and are not waited for.
fn waitForCalls() void {
    while (!removing.tryLock()) std.atomic.spinLoopHint();
    defer removing.unlock();
    const old = generation.fetchAdd(1, .seq_cst) & 1;
    while (in_flight[old].load(.seq_cst) != 0) std.Thread.yield() catch {};
}

test "a call that read the generation before a removal flipped it counts in the new one" {
    const stale = generation.load(.seq_cst);
    waitForCalls(); // a removal, of another engine, flips the generation
    const late = count(stale);
    if (late) |counted| _ = counted.fetchSub(1, .seq_cst); // keeps the counters right when this fails
    try std.testing.expect(late == null);
    try std.testing.expectEqual(@as(u32, 0), in_flight[stale & 1].load(.seq_cst));
    const counter = enter();
    defer _ = counter.fetchSub(1, .seq_cst);
    try std.testing.expect(counter == &in_flight[generation.load(.seq_cst) & 1]);
}

test "std.log levels map to records' levels by name" {
    try std.testing.expectEqual(Level.err, levelOf(.err));
    try std.testing.expectEqual(Level.warn, levelOf(.warn));
    try std.testing.expectEqual(Level.info, levelOf(.info));
    try std.testing.expectEqual(Level.debug, levelOf(.debug));
}
