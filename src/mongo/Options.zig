//! The options of `Client.init`. Only `uri` has no default:
//!
//! ```zig
//! var client: mongo.Client = try .init(gpa, io, .{
//!     .uri = "mongodb://orders@db.internal:27017/orders?appName=orders",
//!     .password = config.mongo.password.expose(), // a confy.Secret
//! });
//! ```
//!
//! `init` checks them and keeps its own copy, so the strings may be freed
//! once the client is created.

const std = @import("std");
const Duration = std.Io.Duration;
const mongo = @import("root.zig");

/// The connection string; `mongo.Client.Uri` lists what it may hold.
uri: []const u8,
/// The password of the user that `uri` names, when the string does not
/// hold it: a secret kept out of the connection string.
password: ?[]const u8 = null,
/// How long `close` lets the operations in flight finish before it cuts
/// them.
close_timeout: Duration = .fromSeconds(5),
/// The budget of the `killCursors` that closing a cursor sends.
cursor_close_timeout: Duration = .fromSeconds(1),
/// Why `init` refused the options; it never shows the password.
diagnostics: ?*mongo.Diagnostics = null,
