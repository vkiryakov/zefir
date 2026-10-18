//! The batched writes of the driver, by the rules of `mongo.WriteRequest`:
//!
//! - The items go in sections of kind 1, `documents`, `updates` or
//!   `deletes`, in batches that fit the limits of the connection each one
//!   goes through: `maxWriteBatchSize` items, and a message of
//!   `maxMessageSizeBytes` at most. An item that no message holds even
//!   alone is `error.InvalidArgument` before any batch goes; one larger
//!   than `maxBsonObjectSize` within a message goes, and the server
//!   refuses it alone.
//! - Each batch takes a connection of the pool for its exchange and gives
//!   it back before the next. The write has one deadline: the `maxTimeMS`
//!   of each batch counts to it, and the token goes before each batch.
//! - The replies merge as the Bulk API specification merges them
//!   (`mongo.wire.batch.Merge`); an ordered write sends no batch after
//!   one with `writeErrors`. Code 50 among them, or in a
//!   `writeConcernError`, is `error.Timeout`.
//! - A write that stops at batch k > 1, after batches that the server
//!   answered, is `error.IncompleteWrite`: the error it stopped at is in
//!   `Diagnostics.reason`, the index of the first item of batch k in
//!   `Diagnostics.batch_offset`, and the merge of the batches before, with
//!   the reply of batch k when one came, in `partial`. A write that stops
//!   at its first batch returns the error itself.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const mongo = @import("mongo");
const wire = mongo.wire;
const opmsg = wire.opmsg;
const OperationContext = mongo.OperationContext;
const command_ = @import("command.zig");
const Runner = command_.Runner;

/// `write`: the items of `request` in batches, and their merged result,
/// from `options.allocator`.
pub fn run(r: Runner, io: Io, op: OperationContext, request: *const mongo.WriteRequest, options: mongo.WriteOptions) mongo.Error!mongo.WriteResult {
    const d = options.diagnostics;
    try r.pool.enter(io, d);
    defer r.pool.leave(io);
    const deadline = r.deadlineOf(io, op);
    // The messages of the write, with every field they carry, which take
    // room: maxTimeMS among them, whatever its value.
    const message: opmsg.Request = .{
        .request_id = 0,
        .body = request.body,
        .database = request.database,
        .ordered = request.ordered,
        .max_time_ms = if (deadline != null) 0 else null,
        .sequence = .{ .identifier = request.kind.items(), .documents = request.items },
    };
    var batches: ?wire.batch.Batches = null;
    var merge: wire.batch.Merge = .{};
    defer merge.deinit(options.allocator);
    while (true) {
        const offset = if (batches) |all| all.offset else 0;
        var taken = command_.take(r, io, op, deadline, request.body, d) catch |err|
            return merge.fail(options.allocator, err, .{ .offset = offset, .items = &.{} }, options);
        defer command_.give(r, io, &taken);
        const limits: wire.batch.Limits = .of(taken.connection().hello);
        if (batches == null) batches = try wire.batch.Batches.init(message, limits, d);
        const all = &batches.?;
        all.limits = limits;
        // mongo.Client lets no write without items through.
        const b = all.next() orelse break;
        const next = send(r, io, &taken, op, deadline, request, b, &merge, options) catch |err|
            return merge.fail(options.allocator, err, b, options);
        switch (next) {
            .more => if (all.offset == all.items.len) break,
            .done => break,
            .timeout => return merge.fail(options.allocator, error.Timeout, b, options),
        }
    }
    return merge.result(options.allocator);
}

/// Sends the batch `b` on the connection of `taken` and merges its reply,
/// which the client's memory holds meanwhile.
fn send(r: Runner, io: Io, taken: *command_.Taken, op: OperationContext, deadline: ?core.Deadline, request: *const mongo.WriteRequest, b: wire.batch.Batch, merge: *wire.batch.Merge, options: mongo.WriteOptions) mongo.Error!wire.batch.Merge.Next {
    const d = options.diagnostics;
    const reply = try command_.exchange(r, io, taken, op, deadline, .{
        .database = request.database,
        .body = request.body,
        .ordered = request.ordered,
        .sequence = .{ .identifier = request.kind.items(), .documents = b.items },
    }, r.gpa, d);
    defer reply.deinit();
    try wire.checkReply(reply.raw(), options.allocator, d, options.failure_reply);
    return merge.add(options.allocator, b, reply.raw(), request.ordered, d);
}
