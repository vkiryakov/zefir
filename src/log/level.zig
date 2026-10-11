//! Record severity.

const std = @import("std");

/// Record severity, from the most verbose to the most severe. A handle
/// writes a record when its level is at or above the handle's threshold.
pub const Level = enum(u8) {
    trace,
    debug,
    info,
    warn,
    err,

    /// The name records use: `.err` is written as "error", as other JSON
    /// loggers do.
    pub fn asText(level: Level) []const u8 {
        return switch (level) {
            .trace => "trace",
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
    }

    /// The level column of the text format, five characters wide.
    pub fn label(level: Level) *const [5]u8 {
        return switch (level) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO ",
            .warn => "WARN ",
            .err => "ERROR",
        };
    }
};

test "records name .err \"error\" and keep the other names" {
    try std.testing.expectEqualStrings("trace", Level.trace.asText());
    try std.testing.expectEqualStrings("warn", Level.warn.asText());
    try std.testing.expectEqualStrings("error", Level.err.asText());
}

test "levels grow from trace to err" {
    const order = [_]Level{ .trace, .debug, .info, .warn, .err };
    for (order[0 .. order.len - 1], order[1..]) |lower, higher| {
        try std.testing.expect(@backingInt(lower) < @backingInt(higher));
    }
}

test "text labels are five characters wide" {
    try std.testing.expectEqualStrings("INFO ", Level.info.label());
    try std.testing.expectEqualStrings("ERROR", Level.err.label());
    try std.testing.expectEqualStrings("TRACE", Level.trace.label());
}
