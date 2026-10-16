//! The users of the examples, kept in memory: the application's own code,
//! which knows nothing of RPC. Like a repository on a real database, each
//! method takes the call's `core.Context`, the `std.Io` it waits on, and an
//! allocator for what it returns.

const std = @import("std");
const core = @import("core");
const api = @import("users-api");

const UserRepository = @This();

gpa: std.mem.Allocator,
/// Handlers run in tasks of their own, many at once: the mutex guards the
/// list, and waits through `std.Io` like everything a handler does.
mutex: std.Io.Mutex = .init,
users: std.ArrayList(api.User) = .empty,
next_id: u64 = 1,

/// The errors of the contract, and those of a call that runs out of time
/// or is canceled.
pub const Error = error{ UserNotFound, EmailTaken, OutOfMemory } || std.Io.Cancelable || core.ContextError;

pub fn init(gpa: std.mem.Allocator) UserRepository {
    return .{ .gpa = gpa };
}

pub fn deinit(repo: *UserRepository) void {
    for (repo.users.items) |user| repo.free(user);
    repo.users.deinit(repo.gpa);
}

/// Stores a new user; the user returned lives in `arena`.
pub fn insert(repo: *UserRepository, ctx: core.Context, io: std.Io, arena: std.mem.Allocator, name: []const u8, email: []const u8) Error!api.User {
    // A call that is out of time or canceled stops before the work.
    try ctx.check(std.Io.Clock.awake.now(io));
    try repo.mutex.lock(io);
    defer repo.mutex.unlock(io);
    for (repo.users.items) |user| {
        if (std.ascii.eqlIgnoreCase(user.email, email)) return error.EmailTaken;
    }
    const created = try copy(arena, .{ .id = repo.next_id, .name = name, .email = email });
    const stored = try copy(repo.gpa, created);
    errdefer repo.free(stored);
    try repo.users.append(repo.gpa, stored);
    repo.next_id += 1;
    return created;
}

/// The user `id`, copied into `arena`: once the mutex is released, another
/// call may delete the stored one.
pub fn find(repo: *UserRepository, ctx: core.Context, io: std.Io, arena: std.mem.Allocator, id: u64) Error!api.User {
    try ctx.check(std.Io.Clock.awake.now(io));
    try repo.mutex.lock(io);
    defer repo.mutex.unlock(io);
    for (repo.users.items) |user| {
        if (user.id == id) return copy(arena, user);
    }
    return error.UserNotFound;
}

/// A page of the users, in the order they were created.
pub fn list(repo: *UserRepository, ctx: core.Context, io: std.Io, arena: std.mem.Allocator, offset: u32, limit: u32) Error!api.ListUsersResponse {
    try ctx.check(std.Io.Clock.awake.now(io));
    try repo.mutex.lock(io);
    defer repo.mutex.unlock(io);
    const all = repo.users.items;
    const first = @min(offset, all.len);
    const page = all[first..@min(first + limit, all.len)];
    const users = try arena.alloc(api.User, page.len);
    for (page, users) |user, *out| out.* = try copy(arena, user);
    return .{ .users = users, .total = all.len };
}

pub fn remove(repo: *UserRepository, ctx: core.Context, io: std.Io, id: u64) Error!void {
    try ctx.check(std.Io.Clock.awake.now(io));
    try repo.mutex.lock(io);
    defer repo.mutex.unlock(io);
    for (repo.users.items, 0..) |user, i| {
        if (user.id == id) {
            repo.free(repo.users.orderedRemove(i));
            return;
        }
    }
    return error.UserNotFound;
}

/// How many users there are.
pub fn count(repo: *UserRepository, io: std.Io) std.Io.Cancelable!usize {
    try repo.mutex.lock(io);
    defer repo.mutex.unlock(io);
    return repo.users.items.len;
}

fn copy(allocator: std.mem.Allocator, user: api.User) error{OutOfMemory}!api.User {
    const name = try allocator.dupe(u8, user.name);
    errdefer allocator.free(name);
    return .{ .id = user.id, .name = name, .email = try allocator.dupe(u8, user.email) };
}

fn free(repo: *UserRepository, user: api.User) void {
    repo.gpa.free(user.name);
    repo.gpa.free(user.email);
}
