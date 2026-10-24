//! The users of the shop, as the application keeps them in the collection
//! "users": a sign-up, which a second one with the same e-mail cannot
//! take, and a look-up by e-mail. It sees a `mongo.Database` only, so the
//! same code runs against mongod and, in users_test.zig, against a
//! scripted server.

const std = @import("std");
const mongo = @import("mongo");
const bson = @import("mongo-bson");
const Users = @This();

collection: mongo.Collection,

pub const User = struct {
    /// null: the insert makes an ObjectId.
    _id: ?bson.ObjectId = null,
    email: []const u8,
    name: []const u8,
};

pub const SignUpError = mongo.Error || error{EmailTaken};
pub const LookUpError = mongo.Error || bson.DecodeError;

pub fn init(db: mongo.Database) Users {
    return .{ .collection = db.collection("users") };
}

/// Makes the e-mail of a user unique, so that a second sign-up with it
/// fails: once, as the service starts. An index that is there already is
/// no error.
pub fn setUp(users: Users, io: std.Io, op: mongo.OperationContext, arena: std.mem.Allocator) mongo.Error!void {
    _ = try users.collection.createIndexes(io, op, &.{.{ .keys = bson.literal(.{ .email = 1 }), .unique = true }}, .{ .allocator = arena });
}

/// Signs `user` up, and returns the `_id` that the insert made for it. An
/// e-mail that another user has is `error.EmailTaken`.
pub fn signUp(users: Users, io: std.Io, op: mongo.OperationContext, arena: std.mem.Allocator, user: User) SignUpError!bson.ObjectId {
    var diagnostics: mongo.Diagnostics = .{};
    const inserted = users.collection.insertOne(io, op, user, .{ .allocator = arena, .diagnostics = &diagnostics }) catch |err| {
        // 11000 (DuplicateKey): the unique index refused the e-mail.
        if (err == error.WriteFailed and diagnostics.server != null and diagnostics.server.?.code == 11000) return error.EmailTaken;
        return err;
    };
    return inserted.inserted_id.object_id;
}

/// The user with `email`, or null; its strings live in `arena`.
pub fn byEmail(users: Users, io: std.Io, op: mongo.OperationContext, arena: std.mem.Allocator, email: []const u8) LookUpError!?User {
    const doc = try users.collection.findOne(io, op, .{ .email = email }, .{ .allocator = arena }) orelse return null;
    return try bson.decode(User, arena, doc.raw(), .{});
}
