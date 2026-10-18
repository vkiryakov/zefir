//! `mongo.Client`: the contract between zefir and a MongoDB driver. A
//! driver is a type with the methods `runCommand`, `openCursor`, `write`
//! and `capabilities`; it hands out `mongo.Client.init(&driver)`, a
//! pointer and a table of functions. Code that works with MongoDB, the
//! collection API among it, sees only this interface, so swapping the
//! driver changes only the place where the application builds it.
//!
//! ```zig
//! pub fn client(self: *MyDriver) mongo.Client {
//!     return .init(self);
//! }
//! ```
//!
//! The rules of the calls, for every driver that works with zefir:
//!
//! 1. Concurrency. Any number of tasks and threads call a client at once;
//!    the driver guards what they share with `std.Io` primitives, since a
//!    lock of the OS would stop a whole thread of an event loop. A cursor
//!    serves one task at a time.
//! 2. `io` is the instance the driver was created with, and every wait
//!    goes through it. In Debug the driver checks it by `io.vtable`.
//! 3. Deadline. With less than 1 ms, or less than a round trip, left
//!    before sending, the call is `error.DeadlineExceeded`. Otherwise the
//!    driver adds `maxTimeMS` (to every command but `getMore` and
//!    `killCursors`) and waits for the reply no longer than the deadline;
//!    after sending, the error is `error.Timeout`. Without a deadline no
//!    `maxTimeMS` goes out, and only the driver's own timeouts bound the
//!    wait.
//! 4. Cancellation. The token is no alarm: the driver checks it before
//!    each send, and this wrapper before the call and after the reply.
//!    Canceling the task ends a wait: `error.Cancelled` before sending,
//!    `error.Interrupted` after, and the driver calls `io.recancel()`
//!    before it returns, so the task keeps its cancelation. A cancelation
//!    or a timeout in the middle of an exchange closes that connection.
//! 5. Memory. The request and its slices are borrowed until the call
//!    returns. The reply, the write result, `failure_reply` and `partial`
//!    come from `options.allocator`, during the call only. After it the
//!    driver holds no reference to the caller's memory.
//! 6. Errors. Only `mongo.Error`. `ok: 0` is `CommandFailed`, code 50
//!    anywhere is `Timeout`, a write stopped at batch k > 1 is
//!    `IncompleteWrite`. `writeErrors` and `writeConcernError` are soft:
//!    they are in the `WriteResult`. `WriteFailed` is the collection API's.
//! 7. The driver adds `$db` to every command, `maxTimeMS` by rule 3, and
//!    `ordered` to writes; nothing else in revision 1.
//! 8. No retries: a driver sends each command and each batch at most once.
//! 9. Writes follow `mongo.WriteRequest`: batches by the limits of the
//!    connection they go through, items in a section of kind 1, replies
//!    merged as the Bulk API spec merges them (`mongo.wire.batch` does it
//!    all). Cursors follow `mongo.Cursor`.
//! 10. `init`, `connect`, `close` and `deinit` belong to the driver's own
//!    type: only the application that built it calls them.
//!
//! The functions below check, for every driver, before it sees a call:
//! the request (a database name of 1–63 bytes without `/\. "$` or NUL; a
//! command whose first key names it and does not start with `$`; none of
//! the driver's fields in it, nor `maxTimeMS` under a deadline; a write
//! named after its kind, without `documents`, `updates`, `deletes` and
//! `ordered`, with items), which is `error.InvalidArgument`; then the
//! context, `error.DeadlineExceeded` before `error.Cancelled`. After the
//! driver's reply they check the token again: canceled meanwhile, the call
//! is `error.Interrupted`, its reply freed, its cursor closed, its write
//! result in `partial`. `Cursor.next` has no such check: a batch of
//! `getMore` has moved the cursor on the server already. Each call starts
//! the caller's `Diagnostics` afresh.

const std = @import("std");
const bson = @import("../bson.zig");
const errors = @import("../errors.zig");
const requests = @import("../requests.zig");
const results = @import("../results.zig");
const capabilities_ = @import("capabilities.zig");
const signature = @import("signature.zig");
const rules = @import("rules.zig");
const Cursor = @import("Cursor.zig");
const Error = errors.Error;
const OperationContext = requests.OperationContext;
const Command = requests.Command;
const CommandOptions = requests.CommandOptions;
const CursorOptions = requests.CursorOptions;
const WriteRequest = requests.WriteRequest;
const WriteOptions = requests.WriteOptions;
const WriteResult = results.WriteResult;
const Capabilities = capabilities_.Capabilities;
const Client = @This();

ptr: *anyopaque,
vtable: *const VTable,

/// The driver's functions behind the interface: one constant table per
/// driver type, built by `init`. Entries of later revisions come with
/// defaults.
pub const VTable = struct {
    runCommand: *const fn (ptr: *anyopaque, io: std.Io, op: OperationContext, command: *const Command, options: CommandOptions) Error!bson.OwnedDocument,
    openCursor: *const fn (ptr: *anyopaque, io: std.Io, op: OperationContext, command: *const Command, options: CursorOptions) Error!Cursor,
    write: *const fn (ptr: *anyopaque, io: std.Io, op: OperationContext, request: *const WriteRequest, options: WriteOptions) Error!WriteResult,
    capabilities: *const fn (ptr: *anyopaque) Capabilities,
};

/// Runs `command` and returns the server's reply, from
/// `options.allocator`.
pub fn runCommand(c: Client, io: std.Io, op: OperationContext, command: Command, options: CommandOptions) Error!bson.OwnedDocument {
    if (options.diagnostics) |d| d.* = .{};
    try rules.checkCommand(&command, op, options.diagnostics);
    try rules.checkContext(io, op, options.diagnostics);
    // Revision 1 has no fields of a later revision to gate: such a field,
    // set for a driver that did not declare it, will be Unsupported here.
    const reply = try c.vtable.runCommand(c.ptr, io, op, &command, options);
    if (op.ctx.isCancelled()) {
        reply.deinit();
        return rules.interrupted(options.diagnostics);
    }
    return reply;
}

/// Runs a command that answers with a cursor, such as `find` or
/// `aggregate`, and returns the cursor; `deinit` it.
pub fn openCursor(c: Client, io: std.Io, op: OperationContext, command: Command, options: CursorOptions) Error!Cursor {
    if (options.diagnostics) |d| d.* = .{};
    try rules.checkCommand(&command, op, options.diagnostics);
    try rules.checkContext(io, op, options.diagnostics);
    const cursor = try c.vtable.openCursor(c.ptr, io, op, &command, options);
    if (op.ctx.isCancelled()) {
        // deinit sends killCursors when the cursor is open on the server.
        cursor.deinit(io);
        return rules.interrupted(options.diagnostics);
    }
    return cursor;
}

/// Sends the items of `request` in batches and returns their merged
/// result, from `options.allocator`.
pub fn write(c: Client, io: std.Io, op: OperationContext, request: WriteRequest, options: WriteOptions) Error!WriteResult {
    if (options.diagnostics) |d| d.* = .{};
    try rules.checkWrite(&request, op, options.diagnostics);
    try rules.checkContext(io, op, options.diagnostics);
    var result = try c.vtable.write(c.ptr, io, op, &request, options);
    if (op.ctx.isCancelled()) {
        if (options.partial) |partial| partial.* = result else result.deinit(options.allocator);
        return rules.interrupted(options.diagnostics);
    }
    return result;
}

/// What the driver can do. Thread-safe; `server` may change.
pub fn capabilities(c: Client) Capabilities {
    return c.vtable.capabilities(c.ptr);
}

const interface = "mongo.Client";

/// The interface of `impl: *T`, where `T` has the methods `runCommand`,
/// `openCursor`, `write` and `capabilities`: the functions of `VTable`
/// with `self: *T` in place of `*anyopaque`. A missing method or another
/// signature stops the build with a message that names the signature to
/// write.
pub fn init(impl: anytype) Client {
    const Ptr = @TypeOf(impl);
    const T = signature.expectPointer(interface, "driver", Ptr);
    comptime signature.expectMethod(interface, T, "runCommand", fn (Ptr, std.Io, OperationContext, *const Command, CommandOptions) Error!bson.OwnedDocument, "pub fn runCommand(self: *@This(), io: std.Io, op: mongo.OperationContext, command: *const mongo.Command, options: mongo.CommandOptions) mongo.Error!mongo.bson.OwnedDocument");
    comptime signature.expectMethod(interface, T, "openCursor", fn (Ptr, std.Io, OperationContext, *const Command, CursorOptions) Error!Cursor, "pub fn openCursor(self: *@This(), io: std.Io, op: mongo.OperationContext, command: *const mongo.Command, options: mongo.CursorOptions) mongo.Error!mongo.Cursor");
    comptime signature.expectMethod(interface, T, "write", fn (Ptr, std.Io, OperationContext, *const WriteRequest, WriteOptions) Error!WriteResult, "pub fn write(self: *@This(), io: std.Io, op: mongo.OperationContext, request: *const mongo.WriteRequest, options: mongo.WriteOptions) mongo.Error!mongo.WriteResult");
    comptime signature.expectMethod(interface, T, "capabilities", fn (Ptr) Capabilities, "pub fn capabilities(self: *@This()) mongo.Capabilities");
    const gen = struct {
        fn runCommandFn(ptr: *anyopaque, io: std.Io, op: OperationContext, command: *const Command, options: CommandOptions) Error!bson.OwnedDocument {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            return T.runCommand(self, io, op, command, options);
        }
        fn openCursorFn(ptr: *anyopaque, io: std.Io, op: OperationContext, command: *const Command, options: CursorOptions) Error!Cursor {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            return T.openCursor(self, io, op, command, options);
        }
        fn writeFn(ptr: *anyopaque, io: std.Io, op: OperationContext, request: *const WriteRequest, options: WriteOptions) Error!WriteResult {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            return T.write(self, io, op, request, options);
        }
        fn capabilitiesFn(ptr: *anyopaque) Capabilities {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            return T.capabilities(self);
        }
        const vtable: VTable = .{
            .runCommand = runCommandFn,
            .openCursor = openCursorFn,
            .write = writeFn,
            .capabilities = capabilitiesFn,
        };
    };
    return .{ .ptr = impl, .vtable = &gen.vtable };
}
