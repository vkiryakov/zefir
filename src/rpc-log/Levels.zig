//! `rpc_log.Levels`: the level of a record by the outcome of its call, a
//! field for a success and one for each code of a failure. By default:
//!
//! - `err` for the failures of the service itself: `unknown`,
//!   `unimplemented`, `internal`, `data_loss`;
//! - `warn` for what an operator watches: `deadline_exceeded`,
//!   `permission_denied`, `resource_exhausted`, `failed_precondition`,
//!   `aborted`, `out_of_range`, `unavailable`;
//! - `info` for a success and the rest, the answers a caller's request
//!   earns: `cancelled`, `invalid_argument`, `not_found`,
//!   `already_exists`, `unauthenticated`.
//!
//! Set the ones to change:
//!
//! ```zig
//! var access_log: rpc_log.AccessLog = .init(logger.scoped("rpc"), .{
//!     .levels = .{ .ok = .debug, .not_found = .warn },
//! });
//! ```

const std = @import("std");
const core = @import("core");
const Level = @import("log").Level;

const Levels = @This();

/// A success.
ok: Level = .info,
cancelled: Level = .info,
unknown: Level = .err,
invalid_argument: Level = .info,
deadline_exceeded: Level = .warn,
not_found: Level = .info,
already_exists: Level = .info,
permission_denied: Level = .warn,
/// A limit ran out: of the server, of the client, of the transport.
resource_exhausted: Level = .warn,
failed_precondition: Level = .warn,
aborted: Level = .warn,
out_of_range: Level = .warn,
/// No such method, or no codec or protocol version in common.
unimplemented: Level = .err,
/// A bug of the service, or an error its contract does not list.
internal: Level = .err,
/// The service or the link is down.
unavailable: Level = .warn,
data_loss: Level = .err,
unauthenticated: Level = .info,

/// The level of a call that ended with a failure of `code`, or with a
/// success when `code` is null.
pub fn of(levels: Levels, code: ?core.ErrorCode) Level {
    const failed = code orelse return levels.ok;
    return switch (failed) {
        inline else => |c| @field(levels, @tagName(c)),
    };
}

test "failures of the service itself are err; deadlines, refusals, limits and the link are warn; the rest info" {
    const levels: Levels = .{};
    try std.testing.expectEqual(Level.info, levels.of(null));
    for (std.enums.values(core.ErrorCode)) |code| {
        const expected: Level = switch (code) {
            .unknown, .unimplemented, .internal, .data_loss => .err,
            .deadline_exceeded, .permission_denied, .resource_exhausted, .failed_precondition, .aborted, .out_of_range, .unavailable => .warn,
            .cancelled, .invalid_argument, .not_found, .already_exists, .unauthenticated => .info,
        };
        try std.testing.expectEqual(expected, levels.of(code));
    }
}

test "each outcome has a field of its own, in the order of core.ErrorCode" {
    const names = @typeInfo(Levels).@"struct".field_names;
    const codes = @typeInfo(core.ErrorCode).@"enum".field_names;
    try std.testing.expectEqual(codes.len + 1, names.len);
    try std.testing.expectEqualStrings("ok", names[0]);
    for (codes, names[1..]) |code, name| try std.testing.expectEqualStrings(code, name);

    const levels: Levels = .{ .ok = .debug, .not_found = .err };
    try std.testing.expectEqual(Level.debug, levels.of(null));
    try std.testing.expectEqual(Level.err, levels.of(.not_found));
    try std.testing.expectEqual(Level.info, levels.of(.already_exists));
}
