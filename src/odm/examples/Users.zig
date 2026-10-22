//! The users of a shop, as the application keeps them: a sign-up, which a
//! second one with the same e-mail cannot take, a look-up by e-mail, and a
//! new name. It sees an `odm.Collection(User)` only, so the same code runs
//! against mongod and, in users_test.zig, against
//! `odm.testing.FakeDriver`.

const std = @import("std");
const core = @import("core");
const odm = @import("odm");
const bson = @import("mongo-bson");
const User = @import("models.zig").User;
const Users = @This();

collection: odm.Collection(User),

/// What a sign-up form brings.
pub const SignUp = struct {
    email: []const u8,
    name: []const u8,
    address: User.Address,
};

pub const SignUpError = odm.Error || error{EmailTaken};

/// The users of the tenant of `session`.
pub fn init(session: *odm.Session) Users {
    return .{ .collection = session.collection(User) };
}

/// Makes the indexes of the users, so that a second sign-up with an
/// e-mail fails: as the service starts, and for each new tenant.
pub fn setUp(users: Users, io: std.Io, ctx: core.Context) odm.Error!void {
    try users.collection.ensureIndexes(io, ctx);
}

/// Signs a user up, and returns the id that odm made for it. An e-mail
/// that another user has is `error.EmailTaken`.
pub fn signUp(users: Users, io: std.Io, ctx: core.Context, form: SignUp, now: bson.DateTime) SignUpError!bson.ObjectId {
    const inserted = users.collection.insertOne(io, ctx, .{
        .email = form.email,
        .name = form.name,
        .address = form.address,
        .created_at = now,
    }) catch |err| switch (err) {
        // The unique index of the e-mail refused it: of the indexes of
        // User, only that one can, as a sign-up has no nickname.
        error.DuplicateKey => return error.EmailTaken,
        else => return err,
    };
    return inserted.id;
}

/// The user with `email`, or null; its strings live in `arena`.
pub fn byEmail(users: Users, io: std.Io, ctx: core.Context, arena: std.mem.Allocator, email: []const u8) odm.Error!?User {
    return users.collection.findOne(io, ctx, .{ .email = email }, .{}, arena);
}

/// Gives the user `id` a new name; false when there is no such user.
pub fn rename(users: Users, io: std.Io, ctx: core.Context, id: bson.ObjectId, name: []const u8) odm.Error!bool {
    const result = try users.collection.updateOne(io, ctx, .{ .id = id }, .{ .set = .{ .name = name } });
    return result.matched == 1;
}
