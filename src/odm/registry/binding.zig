//! A tenant of the registry: its binding to a connection and a database,
//! and the mark of a provisioning in progress.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fingerprint = @import("../fingerprint.zig");
const Connection = @import("connection.zig").Connection;
const List = std.DoublyLinkedList;

/// What `tenant()` finds for a tenant id: a connection and a database, as
/// one provisioning published them, whole and at once. A binding does not
/// change once published: the next provisioning of the tenant puts a new
/// one in its place, under the registry's mutex. Sessions never point to
/// one: each holds a copy of the database name and a lease of a generation.
pub const Binding = struct {
    tenant_buf: [128]u8,
    tenant_len: u8,
    database_buf: [63]u8,
    database_len: u8,
    version: u64,
    /// Set at the publication. It cannot go while a tenant is bound to it.
    connection: *Connection,
    /// The fingerprint of the settings of a `.new` that named the
    /// connection; null for `.existing`.
    print: ?fingerprint.Fingerprint,

    /// A binding of `tenant_id` (at most 128 bytes) to the database `name`
    /// (at most 63), with copies of both; its connection comes at the
    /// publication.
    pub fn create(gpa: Allocator, tenant_id: []const u8, name: []const u8, version: u64, print: ?fingerprint.Fingerprint) Allocator.Error!*Binding {
        const b = try gpa.create(Binding);
        b.* = .{
            .tenant_buf = undefined,
            .tenant_len = @intCast(tenant_id.len),
            .database_buf = undefined,
            .database_len = @intCast(name.len),
            .version = version,
            .connection = undefined,
            .print = print,
        };
        @memcpy(b.tenant_buf[0..tenant_id.len], tenant_id);
        @memcpy(b.database_buf[0..name.len], name);
        return b;
    }

    /// The tenant id, the key of the binding in the registry's table.
    pub fn tenant(b: *const Binding) []const u8 {
        return b.tenant_buf[0..b.tenant_len];
    }

    pub fn database(b: *const Binding) []const u8 {
        return b.database_buf[0..b.database_len];
    }

    /// Whether a provisioning of the same version with these settings is
    /// the same event again: the same database, and the same connection
    /// named the same way, `.existing` with its id or `.new` with its id
    /// and the fingerprint of the same settings. Under the registry's
    /// mutex, which guards `connection`.
    pub fn sameAs(b: *const Binding, name: []const u8, id: []const u8, print: ?*const fingerprint.Fingerprint) bool {
        if (!std.mem.eql(u8, b.database(), name) or !std.mem.eql(u8, b.connection.id, id)) return false;
        const mine = if (b.print) |*p| p else return print == null;
        const other = print orelse return false;
        return fingerprint.eql(mine, other);
    }
};

/// A provisioning in progress, in the registry's list while it runs: the
/// next provisioning of the same tenant, and its removal, wait for it.
pub const Provisioning = struct {
    node: List.Node = .{},
    /// The request's: it lives as long as the call.
    tenant: []const u8,
    /// It holds a slot of the table of tenants for its publication.
    reserved: bool = false,

    pub fn of(node: *List.Node) *Provisioning {
        return @fieldParentPtr("node", node);
    }
};
