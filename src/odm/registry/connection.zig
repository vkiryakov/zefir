//! A connection of the registry: its record, its states, the last failure
//! of its connects, and the warnings that the registry logs about it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const errors = @import("../errors.zig");
const fingerprint = @import("../fingerprint.zig");
const Generation = @import("generation.zig").Generation;
const DriverError = errors.DriverError;
const List = std.DoublyLinkedList;

/// Where a connection is.
pub const ConnectionState = enum {
    /// Its settings are taken and its client opened, without the network.
    registered,
    /// A connect is in progress.
    connecting,
    /// Its current generation is connected: sessions go to it.
    active,
    /// The latest connect failed; the client stays, and a connect may come
    /// again.
    failed,
    /// `removeConnection` is draining it: its id finds it no more.
    removing,
};

/// The error of the latest failed connect or replacement of a connection,
/// with the driver's text, which never holds a password.
pub const Failure = struct {
    err: DriverError,
    message_buf: [256]u8,
    message_len: u16,

    /// The driver's text, UTF-8, at most 256 bytes.
    pub fn message(f: *const Failure) []const u8 {
        return f.message_buf[0..f.message_len];
    }

    /// `err` with `text`, which is UTF-8: a longer one is cut before the
    /// first character that does not fit whole.
    pub fn init(err: DriverError, text: []const u8) Failure {
        var f: Failure = .{ .err = err, .message_buf = undefined, .message_len = 0 };
        var len = @min(text.len, f.message_buf.len);
        if (len < text.len) {
            while (len > 0 and text[len] & 0xC0 == 0x80) len -= 1;
        }
        @memcpy(f.message_buf[0..len], text[0..len]);
        f.message_len = @intCast(len);
        return f;
    }
};

/// The record of a connection, in the registry's list while its id finds
/// it. The registry's mutex guards every field but `id`, which does not
/// change.
pub const Connection = struct {
    node: List.Node = .{},
    /// The registry's copy.
    id: []const u8,
    /// Of the settings of the current generation.
    fingerprint: fingerprint.Fingerprint,
    state: ConnectionState = .registered,
    /// One operation at a time holds it: `connect`, `replaceConnection`,
    /// `removeConnection` or a provisioning that connects it. The others
    /// wait on the registry's condition, and look the id up again.
    busy: bool = false,
    /// Null once the shutdown closed it.
    current: ?*Generation,
    last_failure: ?Failure = null,
    /// The tenants bound to it: while there are any, it cannot go.
    tenants: usize = 0,

    pub fn of(node: *List.Node) *Connection {
        return @fieldParentPtr("node", node);
    }

    /// A record of `id` (copied) with the fingerprint of its settings.
    pub fn create(gpa: Allocator, id: []const u8, print: fingerprint.Fingerprint) Allocator.Error!*Connection {
        const c = try gpa.create(Connection);
        errdefer gpa.destroy(c);
        c.* = .{ .id = try gpa.dupe(u8, id), .fingerprint = print, .current = null };
        return c;
    }

    pub fn destroy(c: *Connection, gpa: Allocator) void {
        gpa.free(c.id);
        gpa.destroy(c);
    }
};

/// The warnings of the registry, which it logs to `std.log.scoped(.odm)`
/// out of its lock. None holds a tenant id, a database, a connection
/// string or a password: an id of a connection is of a safe set of bytes.
pub const Warning = union(enum) {
    /// A drain ran out, and the generation was closed with leases left.
    forced: struct { id: []const u8, generation: u64, leases: usize, after: Io.Duration },
    /// A connect of `connect`, `replaceConnection` or a provisioning failed.
    connect_failed: struct { id: []const u8, err: DriverError, message: []const u8 },
    /// The deadline of `shutdown` came before the leases did.
    shutdown_forced: struct { leases: usize },

    pub fn format(w: Warning, out: *Io.Writer) Io.Writer.Error!void {
        switch (w) {
            .forced => |x| try out.print("connection {s}: generation {d} closed by force with {d} leases left after {f}", .{ x.id, x.generation, x.leases, x.after }),
            .connect_failed => |x| try out.print("connection {s}: connect failed: {t}: {s}", .{ x.id, x.err, x.message }),
            .shutdown_forced => |x| try out.print("shutdown: {d} leases left at the deadline; their generations were closed by force", .{x.leases}),
        }
    }

    /// Logs the warning; never under the registry's lock.
    pub fn log(w: Warning) void {
        std.log.scoped(.odm).warn("{f}", .{w});
    }
};
