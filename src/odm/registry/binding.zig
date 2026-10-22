//! A tenant of the registry: its binding to a connection and a database.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fingerprint = @import("../fingerprint.zig");
const Connection = @import("connection.zig").Connection;

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
};
