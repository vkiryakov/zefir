//! A handler of `mongo.testing.Script` that relays every command to a
//! mongod through a `mongo.Client` of its own and answers with mongod's
//! reply. With it, a client connected to `FakeServer` runs against a real
//! server, under the limits of the script's hello: a `maxWriteBatchSize`
//! of 3 splits its writes into many batches, each of which mongod
//! answers.
//!
//! A command goes on as the client under test wrote it, but for `$db`,
//! which the relay's client writes again, and the items of its section of
//! kind 1, which go in the body under the name of the section. A reply of
//! ok 0 goes back as it came; an exchange with mongod that fails closes
//! the connection of the client under test.

const std = @import("std");
const Io = std.Io;
const mongo = @import("mongo");
const bson = mongo.bson;
const Script = mongo.testing.Script;
const Relay = @This();

/// The client of the mongod, connected; the relay uses it from the tasks
/// of the FakeServer, and does not own it.
mongod: *mongo.Client,

pub fn handler(r: *Relay) Script.Handler {
    return .init(r);
}

pub fn answer(r: *Relay, io: Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
    const body = relayed(arena, request) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidBson => return .close_connection,
    };
    var failure: ?bson.OwnedDocument = null;
    const reply = r.mongod.runCommand(io, .of(.root), .{ .database = request.database, .body = body }, .{
        .allocator = arena,
        .failure_reply = &failure,
    }) catch |err| return switch (err) {
        // ok 0, code 50 among them: mongod's reply, as it came.
        error.CommandFailed, error.Timeout => if (failure) |reply| .{ .reply = reply.raw() } else .close_connection,
        error.OutOfMemory => error.OutOfMemory,
        // The task of the connection was canceled: the FakeServer stops.
        error.Interrupted, error.Cancelled => error.Canceled,
        else => .close_connection,
    };
    return .{ .reply = reply.raw() };
}

/// The body of `request` as it goes on, in `arena`: without `$db`, and
/// with the items of its section of kind 1 under the name of the section.
fn relayed(arena: std.mem.Allocator, request: *const Script.Request) bson.Builder.Error!bson.RawDocument {
    var b: bson.Builder = .init(arena);
    var it = request.body.iterator();
    while (try it.next()) |element| {
        if (std.mem.eql(u8, element.key, "$db")) continue;
        try b.putValue(element.key, element.value);
    }
    if (request.sequence) |sequence| {
        try b.beginArray(sequence.identifier);
        var items = sequence.documents();
        while (items.next()) |item| try b.putDocument("", item);
        try b.end();
    }
    return (try b.finish()).raw();
}
