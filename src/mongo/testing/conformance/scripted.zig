//! The checks of layer S of `mongo.testing.conformance`, each against a
//! scripted server: S1–S21 of the design of zefir-mongo.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const bson = @import("../../bson.zig");
const wire = @import("../../wire.zig");
const errors = @import("../../contract/errors.zig");
const requests = @import("../../contract/requests.zig");
const results = @import("../../contract/results.zig");
const capabilities = @import("../../contract/capabilities.zig");
const Client = @import("../../contract/Client.zig");
const Cursor = @import("../../contract/Cursor.zig");
const Script = @import("../Script.zig");
const Job = @import("Job.zig");

/// The database of the commands of layer S.
const database = "conformance";

/// The capabilities that revision 1 requires, and those it reserves.
const required = [_][]const u8{ "commands", "cursors", "aggregation", "batched_writes" };
const reserved = [_][]const u8{ "sessions", "transactions", "change_streams", "retryable_reads", "retryable_writes", "read_preference", "tailable_cursors", "bulk_write_command", "compression" };

pub fn s19(job: *Job) Job.Error!void {
    const io = job.io;
    var answering: Job.Answering = .{ .with = .{ .reply = Script.ok } };
    var stage: Job.Stage = undefined;
    const hello: wire.Hello = .{ .max_wire_version = 25, .max_bson_object_size = 4 * 1024 * 1024, .max_message_size_bytes = 8_000_000, .max_write_batch_size = 7 };
    const client = try job.scripted(&stage, answering.handler(), hello);
    defer job.end();

    const caps = client.capabilities();
    try job.expect(caps.revision >= 1 and caps.revision <= capabilities.contract_revision, "capabilities().revision is {d}; a driver of this zefir-mongo is of revision 1 to {d}", .{ caps.revision, capabilities.contract_revision });
    try job.expect(caps.name.len > 0, "capabilities().name is empty; name the driver, for logs and reports", .{});
    inline for (required) |name| {
        try job.expect(@field(caps, name), "capabilities()." ++ name ++ " is false; revision 1 requires it", .{});
    }
    inline for (reserved) |name| {
        try job.expect(!@field(caps, name), "capabilities()." ++ name ++ " is true; revision 1 reserves it, so a driver of revision 1 leaves it false", .{});
    }

    // After a command the driver has talked to the server for sure.
    const reply = try job.need(client.runCommand(io, job.within(10_000), .{ .database = database, .body = bson.literal(.{ .count = "s19" }) }, .{ .allocator = job.gpa }), "runCommand");
    reply.deinit();
    const again = client.capabilities();
    try job.expect(again.revision == caps.revision and std.mem.eql(u8, again.name, caps.name), "capabilities() changed from one call to the next: revision {d} \"{s}\", then {d} \"{s}\"", .{ caps.revision, caps.name, again.revision, again.name });
    inline for (required ++ reserved) |name| {
        try job.expect(@field(again, name) == @field(caps, name), "capabilities()." ++ name ++ " changed from one call to the next", .{});
    }
    if (again.server) |server| {
        try job.expect(server.kind == .standalone, "capabilities().server.kind is not standalone, and the server is a standalone mongod", .{});
        try job.expect(server.max_wire_version == hello.max_wire_version, "capabilities().server.max_wire_version is {d}; the server said {d} in hello", .{ server.max_wire_version, hello.max_wire_version });
        try job.expect(server.max_bson_object_size == hello.max_bson_object_size and server.max_message_size_bytes == hello.max_message_size_bytes and
            server.max_write_batch_size == hello.max_write_batch_size, "capabilities().server holds the limits {d}, {d} and {d}; the server said {d}, {d} and {d} in hello", .{
            server.max_bson_object_size, server.max_message_size_bytes, server.max_write_batch_size,
            hello.max_bson_object_size,  hello.max_message_size_bytes,  hello.max_write_batch_size,
        });
    }
}
