//! A logger handle: two pointers, copied by value and shared freely
//! between threads. `init` creates the engine every handle points to;
//! `scoped` derives handles that write a scope.

const std = @import("std");
const Engine = @import("Engine.zig");
const options = @import("options.zig");
const scopes = @import("scopes.zig");
const testing = std.testing;

const Logger = @This();

engine: *Engine,
scope: *const scopes.Entry,

pub const InitError = Engine.InitError;

/// Creates the engine: the only allocations the logger makes. The options
/// may be freed once `init` returns; the logger copies what it keeps. Call
/// `deinit` once, after the last record, on any handle of this logger: all
/// of them become invalid. Use one logger per process for stdout: two
/// loggers on one stdout do not coordinate their writes.
pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: options.Options) InitError!Logger {
    const engine = try Engine.create(gpa, io, opts);
    return .{ .engine = engine, .scope = &engine.scope_table.root };
}

pub fn deinit(self: Logger) void {
    self.engine.destroy();
}

/// Counters since `init`, readable from any thread.
pub fn stats(self: Logger) Engine.Stats {
    return self.engine.stats();
}

test "init and deinit leave nothing behind; the first handle has no scope" {
    const logger: Logger = try .init(testing.allocator, testing.io, .{});
    defer logger.deinit();
    try testing.expectEqualStrings("", logger.scope.name());
    try testing.expectEqual(@as(u64, 0), logger.stats().accepted);
}
