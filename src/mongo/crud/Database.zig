//! `mongo.Database`: a database of MongoDB as an application works with
//! it, over `mongo.Client`. `collection` gives its collections, whose
//! operations insert, update, delete and find documents; its own list its
//! collections, drop it, and run any command in it.
//!
//! ```zig
//! var ids: mongo.bson.ObjectId.Generator = .init(io); // one for the application
//! const db: mongo.Database = .init(&client, "app", &ids);
//! const users = db.collection("users");
//! const ann = try users.insertOne(io, .of(ctx), .{ .email = "ann@example.com", .name = "Ann" }, .{ .allocator = arena });
//! ```
//!
//! A `Database` is a value without state of its own: a pointer to the
//! client, which stays where `connect` ran, the name, and a pointer to the
//! generator of the `_id`s that inserts give documents without one. Copy
//! it, keep it in repositories, use it from any task, as the client
//! itself. The name, the generator and the client must outlive it; the
//! name is usually a literal. The client checks the name at every call: 1
//! to 63 bytes, without `/\. "$`, a space or NUL.

const std = @import("std");
const Io = std.Io;
const bson = @import("../bson.zig");
const errors = @import("../errors.zig");
const requests = @import("../requests.zig");
const Client = @import("../Client.zig");
const Cursor = @import("../Cursor.zig");
const Collection = @import("Collection.zig");
const document = @import("document.zig");
const commands = @import("command.zig");
const options_ = @import("options.zig");
const Error = errors.Error;
const OperationContext = requests.OperationContext;
const Writer = commands.Writer;
const Database = @This();

client: *Client,
name: []const u8,
/// Where inserts take the `_id` of a document that has none.
ids: *bson.ObjectId.Generator,

pub const ListCollectionsOptions = options_.ListCollectionsOptions;
pub const DropOptions = options_.DropOptions;
pub const RunCursorCommandOptions = options_.RunCursorCommandOptions;

pub fn init(client: *Client, name: []const u8, ids: *bson.ObjectId.Generator) Database {
    return .{ .client = client, .name = name, .ids = ids };
}

/// The collection `name` of this database. The name is borrowed. Each
/// operation checks it before anything is sent: it is not empty and holds
/// neither `$` nor NUL.
pub fn collection(db: Database, name: []const u8) Collection {
    return .{ .db = db, .name = name };
}

/// The collections and views of the database, each a document with its
/// `name`, `type`, `options` and `info`, or with `name` and `type` only
/// when `name_only`: `listCollections`, whose cursor gives them.
pub fn listCollections(db: Database, io: Io, op: OperationContext, options: ListCollectionsOptions) Error!Cursor {
    if (options.diagnostics) |d| d.* = .{};
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    var w: Writer = .init(scratch.allocator(), options.diagnostics);
    try w.int32("listCollections", 1);
    if (options.filter) |filter| try w.document("filter", filter, "the filter");
    if (options.name_only) try w.boolean("nameOnly", true);
    if (options.authorized_collections) try w.boolean("authorizedCollections", true);
    try w.cursor(options.batch_size);
    if (options.comment) |value| try w.value("comment", value, "the comment");
    return db.client.openCursor(io, op, .{ .database = db.name, .body = try w.finish() }, .{
        .batch_size = options.batch_size,
        // The comment goes with the command only: the enumerate
        // collections spec keeps it out of getMore.
        .diagnostics = options.diagnostics,
        .failure_reply = options.failure_reply,
    });
}

/// Drops the database with all its collections: `dropDatabase`. A
/// database that is not there is no error: the server answers ok.
pub fn drop(db: Database, io: Io, op: OperationContext, options: DropOptions) Error!void {
    if (options.diagnostics) |d| d.* = .{};
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    var w: Writer = .init(scratch.allocator(), options.diagnostics);
    try w.int32("dropDatabase", 1);
    if (options.comment) |value| try w.value("comment", value, "the comment");
    const reply = try db.client.runCommand(io, op, .{ .database = db.name, .body = try w.finish() }, .{
        .allocator = options.allocator,
        .diagnostics = options.diagnostics,
        .failure_reply = options.failure_reply,
    });
    reply.deinit();
}

/// Runs `command`, a document of the three forms whose first key names
/// it, as it is, with the database's `$db`, and returns the server's
/// reply from `options.allocator`; `deinit` it. Only the rules of
/// `mongo.Client` bind it: none of the fields that the client writes,
/// such as `$db`, and no `maxTimeMS` under a deadline.
///
/// ```zig
/// const stats = try db.runCommand(io, op, .{ .collStats = "users" }, .{ .allocator = arena });
/// ```
pub fn runCommand(db: Database, io: Io, op: OperationContext, command: anytype, options: requests.CommandOptions) Error!bson.OwnedDocument {
    comptime document.expectDatabaseDocument("runCommand", "command", @TypeOf(command));
    if (options.diagnostics) |d| d.* = .{};
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    const body = try commands.argument(scratch.allocator(), command, "the command", options.diagnostics);
    return db.client.runCommand(io, op, .{ .database = db.name, .body = body }, options);
}

/// Runs `command`, which answers with a cursor, as `runCommand` runs a
/// command, and returns the cursor; `deinit` it. For a `find` or an
/// `aggregate` with options that the collection API leaves out:
///
/// ```zig
/// var docs = try db.runCursorCommand(io, op, .{ .find = "events", .filter = .{}, .noCursorTimeout = true }, .{ .allocator = arena });
/// defer docs.deinit(io);
/// ```
pub fn runCursorCommand(db: Database, io: Io, op: OperationContext, command: anytype, options: RunCursorCommandOptions) Error!Cursor {
    comptime document.expectDatabaseDocument("runCursorCommand", "command", @TypeOf(command));
    if (options.diagnostics) |d| d.* = .{};
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    const body = try commands.argument(scratch.allocator(), command, "the command", options.diagnostics);
    return db.client.openCursor(io, op, .{ .database = db.name, .body = body }, .{
        .batch_size = options.batch_size,
        .diagnostics = options.diagnostics,
        .failure_reply = options.failure_reply,
    });
}
