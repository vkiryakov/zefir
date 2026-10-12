//! Logger options. Every field has a default, and confy can read the
//! service, the level and the scope rules from the application's
//! configuration.

const std = @import("std");
const Level = @import("level.zig").Level;

pub const Options = struct {
    /// Service fields, written into every JSON record.
    service: Service = .{},
    /// The global threshold: records below it are not written.
    level: Level = .info,
    /// Initial levels of scopes; change them later with `setScopeLevel`.
    scopes: []const ScopeRule = &.{},
    format: Format = .json,
    /// How much of the call site, `.src = @src()`, records write per level.
    source: SourceOptions = .{},
    /// The longest record, '\n' included: at most 16384. Longer records are
    /// cut or dropped, see `oversize`.
    max_record_bytes: u32 = 4096,
    oversize: OversizePolicy = .truncate,
    output: Output = .stdout,
};

/// OpenTelemetry resource fields; empty ones are not written. All four
/// together may take at most 1 KiB.
pub const Service = struct {
    /// Written as `service.name`.
    name: ?[]const u8 = null,
    /// Written as `service.instance.id`.
    instance_id: ?[]const u8 = null,
    /// Written as `service.version`.
    version: ?[]const u8 = null,
    /// Written as `deployment.environment.name`.
    environment: ?[]const u8 = null,
};

/// The level of one scope and its subscopes: `zefir.rpc` covers `zefir.rpc`
/// and `zefir.rpc.server`, not `zefir.rpcx`. The longest matching prefix
/// wins.
pub const ScopeRule = struct {
    prefix: []const u8,
    level: Level,
};

pub const Format = enum {
    /// One JSON object per line.
    json,
    /// One line per record for people:
    /// `2026-10-10T21:08:00.123Z INFO  [users] User created user_id=42`.
    text,
};

pub const SourceMode = enum {
    /// Leave the call site out.
    none,
    /// `"source":{"file":"users.zig","line":84}`; in text `src=users.zig:84`.
    file_line,
    /// Also the column, the function and the module; in text
    /// `src=users.zig:84:5 src.function=create src.module=app`.
    full,
};

/// The call-site mode of each level; a level without its own uses
/// `default`. Only records that pass `.src = @src()` have a call site.
pub const SourceOptions = struct {
    default: SourceMode = .file_line,
    trace: ?SourceMode = null,
    debug: ?SourceMode = null,
    info: ?SourceMode = null,
    warn: ?SourceMode = null,
    err: ?SourceMode = null,

    /// The mode records at `level` use.
    pub fn mode(o: SourceOptions, level: Level) SourceMode {
        const own = switch (level) {
            .trace => o.trace,
            .debug => o.debug,
            .info => o.info,
            .warn => o.warn,
            .err => o.err,
        };
        return own orelse o.default;
    }
};

pub const OversizePolicy = enum {
    /// Cut the message, leave out the fields that do not fit, and end the
    /// record with `"truncated":true` (` truncated=true` in text).
    truncate,
    /// Drop the whole record and count it.
    drop,
};

pub const Output = union(enum) {
    /// The process's standard output.
    stdout,
    /// A writer the application owns, for tests and embedding. It must
    /// outlive the logger; each record is written and flushed in one go.
    /// The logger calls it from one thread at a time, so it need not be
    /// thread-safe, but it must not log through the same logger: that
    /// call would wait for itself.
    writer: *std.Io.Writer,
};

test "defaults: JSON to stdout at info, 4 KiB records, cut when longer" {
    const o: Options = .{};
    try std.testing.expectEqual(Level.info, o.level);
    try std.testing.expectEqual(Format.json, o.format);
    try std.testing.expectEqual(@as(u32, 4096), o.max_record_bytes);
    try std.testing.expectEqual(OversizePolicy.truncate, o.oversize);
    try std.testing.expect(o.output == .stdout);
    try std.testing.expectEqual(@as(usize, 0), o.scopes.len);
    try std.testing.expectEqual(@as(?[]const u8, null), o.service.name);
    try std.testing.expectEqual(SourceMode.file_line, o.source.mode(.info));
}

test "a level's own source mode outranks the default" {
    const s: SourceOptions = .{ .default = .none, .err = .full, .debug = .file_line };
    try std.testing.expectEqual(SourceMode.none, s.mode(.info));
    try std.testing.expectEqual(SourceMode.full, s.mode(.err));
    try std.testing.expectEqual(SourceMode.file_line, s.mode(.debug));
}
