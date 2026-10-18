//! `mongo.Database`: a database of MongoDB as an application works with
//! it, the same on every driver. `collection` gives its collections, whose
//! operations insert, update, delete and find documents.
//!
//! ```zig
//! var ids: mongo.bson.ObjectId.Generator = .init(io); // one for the application
//! const db: mongo.Database = .init(driver.client(), "app", &ids);
//! const users = db.collection("users");
//! const ann = try users.insertOne(io, .of(ctx), .{ .email = "ann@example.com", .name = "Ann" }, .{ .allocator = arena });
//! ```
//!
//! A `Database` is a value without state of its own: a copy of the
//! driver's `mongo.Client`, the name, and a pointer to the generator of
//! the `_id`s that inserts give documents without one. Copy it, keep it in
//! repositories, use it from any task, as the client itself. The name,
//! the generator and the driver must outlive it; the name is usually a
//! literal. The client checks the name at every call: 1 to 63 bytes,
//! without `/\. "$`, a space or NUL.

const bson = @import("../bson.zig");
const Client = @import("../contract/Client.zig");
const Collection = @import("Collection.zig");
const Database = @This();

client: Client,
name: []const u8,
/// Where inserts take the `_id` of a document that has none.
ids: *bson.ObjectId.Generator,

pub fn init(client: Client, name: []const u8, ids: *bson.ObjectId.Generator) Database {
    return .{ .client = client, .name = name, .ids = ids };
}

/// The collection `name` of this database. The name is borrowed. Each
/// operation checks it before anything is sent: it is not empty and holds
/// neither `$` nor NUL.
pub fn collection(db: Database, name: []const u8) Collection {
    return .{ .db = db, .name = name };
}
