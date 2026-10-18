//! The arguments of the contract's calls: the caller's context, the
//! command or the write, and the options. They are structs, so that a
//! later revision adds a field with a default without breaking callers or
//! drivers.

const std = @import("std");
const core = @import("core");
const bson = @import("bson.zig");
const errors = @import("errors.zig");
const results = @import("results.zig");

/// The caller's context of one operation.
pub const OperationContext = struct {
    /// The deadline, the cancellation token and the W3C trace of the
    /// caller. A driver turns the deadline into `maxTimeMS` and waits no
    /// longer than it; it checks the token before every send.
    ctx: core.Context,
    /// For the driver's logs and spans; never sent to the server.
    tracing: Tracing = .{},

    pub fn of(ctx: core.Context) OperationContext {
        return .{ .ctx = ctx };
    }
};

pub const Tracing = struct {
    /// The caller's operation, such as "users.findOne".
    operation: ?[]const u8 = null,
};

/// A command for `runCommand` or `openCursor`.
pub const Command = struct {
    /// The database it runs in, sent as `$db`.
    database: []const u8,
    /// The command: its first key is its name, as in `{ping: 1}`. Sent as
    /// it is, with `$db` (and `maxTimeMS` under a deadline) added by the
    /// driver. Borrowed until the call returns.
    body: bson.RawDocument,
};

pub const CommandOptions = struct {
    /// The memory of the reply; the driver takes from it only during the
    /// call.
    allocator: std.mem.Allocator,
    diagnostics: ?*errors.Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, the whole reply of
    /// the server goes here, from `allocator`; the caller frees it.
    failure_reply: ?*?bson.OwnedDocument = null,
};

/// The kind of a batched write: the command it is and the section its
/// items go in.
pub const WriteKind = enum {
    insert,
    update,
    delete,

    /// The name of the command, the first key of the body: "insert".
    pub fn command(kind: WriteKind) []const u8 {
        return @tagName(kind);
    }

    /// The identifier of the section of kind 1 that carries the items:
    /// "documents", "updates", "deletes".
    pub fn items(kind: WriteKind) []const u8 {
        return switch (kind) {
            .insert => "documents",
            .update => "updates",
            .delete => "deletes",
        };
    }
};

/// A batched write: its items go in batches that fit the server's limits.
pub const WriteRequest = struct {
    database: []const u8,
    kind: WriteKind,
    /// The command without its items, such as `{insert: "users"}`, with
    /// `writeConcern`, `comment`, `let` or `bypassDocumentValidation` when
    /// needed. The driver adds `ordered`, `$db` and `maxTimeMS`.
    body: bson.RawDocument,
    /// Documents for insert, `{q, u, upsert?, multi?, …}` for update,
    /// `{q, limit}` for delete. Sent as they are: the driver makes no `_id`.
    items: []const bson.RawDocument,
    /// Whether the server stops at the first item it refuses, and the
    /// driver sends no batch after it.
    ordered: bool = true,
};

pub const WriteOptions = struct {
    /// The memory of the result; the driver takes from it only during the
    /// call.
    allocator: std.mem.Allocator,
    diagnostics: ?*errors.Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, the whole reply of
    /// the server goes here, from `allocator`; the caller frees it.
    failure_reply: ?*?bson.OwnedDocument = null,
    /// When the write fails after batches that the server answered, their
    /// merged result goes here, from `allocator`: free it with `deinit`.
    partial: ?*results.WriteResult = null,
};

pub const CursorOptions = struct {
    /// The `batchSize` of each `getMore`; null leaves it to the server.
    batch_size: ?u32 = null,
    /// The `comment` of each `getMore`; the driver copies it.
    comment: ?bson.Value = null,
    diagnostics: ?*errors.Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, the whole reply of
    /// the server goes here, from the driver's allocator; free it with
    /// `deinit`.
    failure_reply: ?*?bson.OwnedDocument = null,
};
