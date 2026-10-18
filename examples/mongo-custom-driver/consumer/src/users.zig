//! The application of the example: a small repository of users on
//! `mongo.Collection`. It knows zefir-mongo and no driver: users_test.zig
//! runs it on `mongo.testing.FakeDriver`, and with `-Dlive-uri` on
//! minidriver against a live mongod, without a change here. Swapping the
//! driver changes only the place that builds it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mongo = @import("zefir-mongo");
const bson = mongo.bson;

pub const User = struct {
    /// Null for a new user: the insert makes one.
    _id: ?bson.ObjectId = null,
    email: []const u8,
    name: []const u8,
    age: i32,
};

/// The users of an application, in the collection "users" of its
/// database, one per email.
pub const Users = struct {
    collection: mongo.Collection,

    pub fn init(db: mongo.Database) Users {
        return .{ .collection = db.collection("users") };
    }

    /// Makes the unique index on `email`; making it again is no error.
    pub fn setUp(u: Users, io: Io, op: mongo.OperationContext, gpa: Allocator) mongo.Error!void {
        const names = try u.collection.createIndexes(io, op, &.{.{ .keys = bson.literal(.{ .email = 1 }), .unique = true }}, .{ .allocator = gpa });
        for (names) |name| gpa.free(name);
        gpa.free(names);
    }

    pub const RegisterError = mongo.Error || error{EmailTaken};

    /// Adds `user` and returns its `_id`. Another user with the same email
    /// is `error.EmailTaken`: the unique index refuses it.
    pub fn register(u: Users, io: Io, op: mongo.OperationContext, gpa: Allocator, user: User) RegisterError!bson.ObjectId {
        var diagnostics: mongo.Diagnostics = .{};
        var result = u.collection.insertOne(io, op, user, .{ .allocator = gpa, .diagnostics = &diagnostics }) catch |err| {
            // 11000 is DuplicateKey.
            if (err == error.WriteFailed and diagnostics.server != null and diagnostics.server.?.code == 11000) return error.EmailTaken;
            return err;
        };
        defer result.deinit(gpa);
        return result.inserted_id.object_id;
    }

    pub const FindError = mongo.Error || bson.DecodeError;

    /// The user with `email`, its strings in `arena`; null when there is
    /// none.
    pub fn byEmail(u: Users, io: Io, op: mongo.OperationContext, arena: Allocator, email: []const u8) FindError!?User {
        const doc = (try u.collection.findOne(io, op, .{ .email = email }, .{ .allocator = arena })) orelse return null;
        return try bson.decode(User, arena, doc.raw(), .{});
    }

    /// Renames the user with `email`; false when there is none.
    pub fn rename(u: Users, io: Io, op: mongo.OperationContext, gpa: Allocator, email: []const u8, name: []const u8) mongo.Error!bool {
        var result = try u.collection.updateOne(io, op, .{ .email = email }, .{ .@"$set" = .{ .name = name } }, .{ .allocator = gpa });
        defer result.deinit(gpa);
        return result.matched == 1;
    }

    /// Deletes the user with `email`; false when there is none.
    pub fn remove(u: Users, io: Io, op: mongo.OperationContext, gpa: Allocator, email: []const u8) mongo.Error!bool {
        var result = try u.collection.deleteOne(io, op, .{ .email = email }, .{ .allocator = gpa });
        defer result.deinit(gpa);
        return result.deleted == 1;
    }

    /// How many users there are.
    pub fn count(u: Users, io: Io, op: mongo.OperationContext, gpa: Allocator) mongo.Error!u64 {
        return u.collection.countDocuments(io, op, .{}, .{ .allocator = gpa });
    }
};
