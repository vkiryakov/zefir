//! For the tests of the collection API: a `mongo.testing.Script` that
//! `mongo.testing.FakeServer` serves on loopback, and a client connected
//! to it, so that every operation goes over the wire and its exact command
//! lands in the script's journal. Its parts point into it: start it in
//! place.
//!
//! ```zig
//! var write: Script.Write = .{};
//! var served: Served = undefined;
//! try served.start(io, write.handler(), .{ .max_write_batch_size = 3 });
//! defer served.stop(io);
//! const users = served.database("app", &ids).collection("users");
//! ```

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const mongo = @import("../root.zig");
const bson = @import("mongo-bson");
const Script = mongo.testing.Script;
const FakeServer = mongo.testing.FakeServer;
const Client = @import("../Client.zig");
const Served = @This();

script: Script,
listener: net.Server,
server: Io.Future(FakeServer.ServeError!void),
/// The client, connected to the server; `stop` closes and frees it.
driver: Client,
uri: [64]u8,

/// What the server says about itself in hello: the type of `Script.hello`.
pub const Hello = @FieldType(Script, "hello");

/// Serves `handler` with `hello` and connects the client. The handshake
/// is not in the journal: it starts empty.
pub fn start(s: *Served, io: Io, handler: Script.Handler, hello: Hello) !void {
    s.script = .init(testing.allocator, handler);
    s.script.hello = hello;
    errdefer s.script.deinit();
    s.listener = try FakeServer.listen(io);
    errdefer s.listener.deinit(io);
    s.server = try io.concurrent(FakeServer.serve, .{ io, &s.listener, &s.script });
    errdefer s.server.cancel(io) catch {};
    s.driver = try .init(testing.allocator, io, .{ .uri = try FakeServer.uri(&s.listener, &s.uri) });
    errdefer s.driver.deinit();
    try s.driver.connect(io, .root, null);
}

/// Closes and frees the client, then stops the server. The cursors of the
/// test are freed before.
pub fn stop(s: *Served, io: Io) void {
    s.driver.deinit();
    s.server.cancel(io) catch {};
    s.listener.deinit(io);
    s.script.deinit();
}

/// The client, connected to the server.
pub fn client(s: *Served) *Client {
    return &s.driver;
}

/// The database `name` of the client, whose inserts take their `_id`s
/// from `ids`.
pub fn database(s: *Served, name: []const u8, ids: *bson.ObjectId.Generator) mongo.Database {
    return .init(s.client(), name, ids);
}
