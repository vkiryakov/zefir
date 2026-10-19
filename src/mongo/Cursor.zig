//! `mongo.Cursor`: the documents of a command's result, batch by batch, as
//! `mongo.Client.openCursor` gives them, and the operations of the
//! collection API that read, such as `find`. It is a handle: the client
//! keeps the state of the cursor, and a copy of the handle is the same
//! cursor.
//!
//! ```zig
//! var cursor = try client.openCursor(io, .of(ctx), .{ .database = "app", .body = find }, .{ .batch_size = 100 });
//! defer cursor.deinit(io);
//! while (try cursor.next(io, .of(ctx))) |doc| try handle(doc);
//! ```
//!
//! The rules of a cursor:
//!
//! 1. The first batch is `cursor.firstBatch` of the reply. A reply without
//!    `cursor` is `error.ProtocolViolation`: the command may have run.
//! 2. `getMore` goes to the cursor's `ns` (its `$db` is the part before
//!    the first dot, its `collection` the rest), with `batchSize` and
//!    `comment` of `mongo.CursorOptions` and without `maxTimeMS`. The id
//!    and `ns` follow each reply.
//! 3. The documents of the current batch come out even after the deadline:
//!    the context is checked only before a `getMore`.
//! 4. An error before a `getMore` was sent (deadline, token, pool) leaves
//!    the cursor as it was: the next `next` with a new context goes on. An
//!    error of the exchange itself, `CursorNotFound` (43) among them, ends
//!    the cursor: `next` gives `error.Closed` from then on.
//! 5. `close` is idempotent. With an id other than 0, `close` and `deinit`
//!    send `killCursors` once, with a budget of the client's options
//!    (`cursor_close_timeout`) rather than of a context, and ignore the
//!    reply; cancelation of the task is held off meanwhile and stays for
//!    its next cancelation point.
//! 6. One task at a time uses a cursor, but it may be any task. Two at
//!    once panic in safe builds (Debug, ReleaseSafe).

const std = @import("std");
const Io = std.Io;
const bson = @import("bson.zig");
const errors = @import("errors.zig");
const requests = @import("requests.zig");
const engine = @import("engine/cursor.zig");
const Error = errors.Error;
const OperationContext = requests.OperationContext;
const Cursor = @This();

/// The state of the cursor, which the client keeps. Null for a cursor
/// without documents and without a cursor on the server, as `listIndexes`
/// gives for a collection that is not there.
state: ?*engine.Cursor,

/// The next document, borrowed until the next call of this cursor; null
/// after the last one, and again at every later call.
pub fn next(c: Cursor, io: Io, op: OperationContext) Error!?bson.RawDocument {
    const state = c.state orelse return null;
    return state.next(io, op);
}

/// As `next`, but a copy in `allocator`, which the caller frees. Out of
/// memory, the cursor stays before the document: the next call gives it.
pub fn nextOwned(c: Cursor, io: Io, op: OperationContext, allocator: std.mem.Allocator) Error!?bson.OwnedDocument {
    const state = c.state orelse return null;
    return state.nextOwned(io, op, allocator);
}

/// Ends the cursor on the server, when it is open there; idempotent.
pub fn close(c: Cursor, io: Io) void {
    if (c.state) |state| state.close(io);
}

/// Closes the cursor, if it is open, and frees it; the handle is invalid
/// after it.
pub fn deinit(c: Cursor, io: Io) void {
    if (c.state) |state| state.deinit(io);
}
