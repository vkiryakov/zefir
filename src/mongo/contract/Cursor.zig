//! `mongo.Cursor`: the documents of a command's result, batch by batch, as
//! `mongo.Client.openCursor` gives them. A driver implements it as a type
//! with the methods `next`, `close` and `deinit` and hands out
//! `mongo.Cursor.init(&cursor)`.
//!
//! ```zig
//! var cursor = try client.openCursor(io, .of(ctx), .{ .database = "app", .body = find }, .{ .batch_size = 100 });
//! defer cursor.deinit(io);
//! while (try cursor.next(io, .of(ctx))) |doc| try handle(doc);
//! ```
//!
//! The rules of a cursor, for every driver:
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
//!    send `killCursors` once, with a budget of the driver's options rather
//!    than of a context, and ignore the reply; cancelation of the task is
//!    held off meanwhile and stays for its next cancelation point.
//! 6. One task at a time uses a cursor, but it may be any task. Two at
//!    once panic in Debug.

const std = @import("std");
const bson = @import("../bson.zig");
const errors = @import("../errors.zig");
const requests = @import("../requests.zig");
const signature = @import("signature.zig");
const Error = errors.Error;
const OperationContext = requests.OperationContext;
const Cursor = @This();

ptr: *anyopaque,
vtable: *const VTable,

/// The cursor's functions behind the interface: one constant table per
/// cursor type, built by `init`.
pub const VTable = struct {
    next: *const fn (ptr: *anyopaque, io: std.Io, op: OperationContext) Error!?bson.RawDocument,
    close: *const fn (ptr: *anyopaque, io: std.Io) void,
    deinit: *const fn (ptr: *anyopaque, io: std.Io) void,
};

/// The next document, borrowed until the next call of this cursor; null
/// after the last one, and again at every later call.
pub fn next(c: Cursor, io: std.Io, op: OperationContext) Error!?bson.RawDocument {
    return c.vtable.next(c.ptr, io, op);
}

/// As `next`, but a copy in `allocator`, which the caller frees.
pub fn nextOwned(c: Cursor, io: std.Io, op: OperationContext, allocator: std.mem.Allocator) Error!?bson.OwnedDocument {
    const doc = (try c.next(io, op)) orelse return null;
    return try doc.dupe(allocator);
}

/// Ends the cursor on the server, when it is open there; idempotent.
pub fn close(c: Cursor, io: std.Io) void {
    c.vtable.close(c.ptr, io);
}

/// Closes the cursor, if it is open, and frees it; the handle is invalid
/// after it.
pub fn deinit(c: Cursor, io: std.Io) void {
    c.vtable.deinit(c.ptr, io);
}

const interface = "mongo.Cursor";

/// The interface of `impl: *T`, where `T` has the methods `next`, `close`
/// and `deinit`: the functions of `VTable` with `self: *T` in place of
/// `*anyopaque`. A missing method or another signature stops the build
/// with a message that names the signature to write.
pub fn init(impl: anytype) Cursor {
    const Ptr = @TypeOf(impl);
    const T = signature.expectPointer(interface, "cursor", Ptr);
    comptime signature.expectMethod(interface, T, "next", fn (Ptr, std.Io, OperationContext) Error!?bson.RawDocument, "pub fn next(self: *@This(), io: std.Io, op: mongo.OperationContext) mongo.Error!?mongo.bson.RawDocument");
    comptime signature.expectMethod(interface, T, "close", fn (Ptr, std.Io) void, "pub fn close(self: *@This(), io: std.Io) void");
    comptime signature.expectMethod(interface, T, "deinit", fn (Ptr, std.Io) void, "pub fn deinit(self: *@This(), io: std.Io) void");
    const gen = struct {
        fn nextFn(ptr: *anyopaque, io: std.Io, op: OperationContext) Error!?bson.RawDocument {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            return T.next(self, io, op);
        }
        fn closeFn(ptr: *anyopaque, io: std.Io) void {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            T.close(self, io);
        }
        fn deinitFn(ptr: *anyopaque, io: std.Io) void {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            T.deinit(self, io);
        }
        const vtable: VTable = .{ .next = nextFn, .close = closeFn, .deinit = deinitFn };
    };
    return .{ .ptr = impl, .vtable = &gen.vtable };
}
