//! The profiles of the shop's customers, as the application keeps them: a
//! hash `user:<id>` for each customer, whose fields are those of
//! `Profile`. It sees a `*redis.Client` only, so the same code runs against
//! Redis and, in profiles_test.zig, against `redis.testing.FakeServer`.

const std = @import("std");
const redis = @import("redis");
const cmd = redis.cmd;
const Profiles = @This();

client: *redis.Client,

pub const Profile = struct {
    name: []const u8,
    age: u8,
    plan: enum { free, pro } = .free,
    /// How many times the customer came, as `visit` counts them.
    visits: i64 = 0,
};

pub fn init(client: *redis.Client) Profiles {
    return .{ .client = client };
}

/// Keeps `profile` as the profile of the customer `id`: a field of the
/// hash for each field of the struct.
pub fn save(profiles: Profiles, io: std.Io, op: redis.OperationContext, id: u64, profile: Profile) redis.Error!void {
    var buffer: [32]u8 = undefined;
    try profiles.client.run(io, op, cmd.hset(key(&buffer, id), profile), .{});
}

/// The profile of the customer `id`, its strings in `arena`; null when the
/// customer has none.
pub fn byId(profiles: Profiles, io: std.Io, op: redis.OperationContext, arena: std.mem.Allocator, id: u64) redis.Error!?Profile {
    var buffer: [32]u8 = undefined;
    return profiles.client.run(io, op, cmd.hgetall(Profile, key(&buffer, id)), .{ .allocator = arena });
}

/// Counts a visit of the customer `id`, and returns how many there were.
pub fn visit(profiles: Profiles, io: std.Io, op: redis.OperationContext, id: u64) redis.Error!i64 {
    var buffer: [32]u8 = undefined;
    return profiles.client.run(io, op, cmd.hincrby(key(&buffer, id), "visits", 1), .{});
}

/// "user:<id>", in `buffer`: "user:" and the 20 digits of the largest u64
/// fit.
fn key(buffer: *[32]u8, id: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "user:{d}", .{id}) catch unreachable;
}
