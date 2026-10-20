//! Calls of the collection API with documents of types it cannot take,
//! which must not compile, one test each. `zig build test-mongo` compiles
//! every test on its own and checks its error message, which names the
//! operation, the argument and the field; the list of messages is in
//! build.zig.

const std = @import("std");
const mongo = @import("mongo");

/// Never called at run time: these tests only have to fail to compile.
fn users() mongo.Collection {
    return undefined;
}

fn db() mongo.Database {
    return undefined;
}

fn io() std.Io {
    return undefined;
}

fn op() mongo.OperationContext {
    return .of(.root);
}

fn gpa() std.mem.Allocator {
    return undefined;
}

const Counter = struct { n: u64 };
const User = struct { name: []const u8 };
const Post = struct { owner: *const User };

test "insertOne of a number" {
    _ = try users().insertOne(io(), op(), @as(u32, 5), .{ .allocator = gpa() });
}

test "insertOne of a struct with a u64" {
    _ = try users().insertOne(io(), op(), Counter{ .n = 1 }, .{ .allocator = gpa() });
}

test "insertOne of a tuple" {
    _ = try users().insertOne(io(), op(), .{ 1, 2 }, .{ .allocator = gpa() });
}

test "insertMany of one document" {
    _ = try users().insertMany(io(), op(), User{ .name = "Ann" }, .{ .allocator = gpa() });
}

test "insertMany with a pointer in a document of a tuple" {
    const ann: User = .{ .name = "Ann" };
    _ = try users().insertMany(io(), op(), .{ .{ .a = 1 }, Post{ .owner = &ann } }, .{ .allocator = gpa() });
}

test "insertMany of a slice of numbers" {
    _ = try users().insertMany(io(), op(), @as([]const u32, &.{1}), .{ .allocator = gpa() });
}

test "updateOne with a filter that holds a u64" {
    _ = try users().updateOne(io(), op(), Counter{ .n = 1 }, .{ .@"$set" = .{ .n = 2 } }, .{ .allocator = gpa() });
}

test "updateOne with a u64 in the update" {
    _ = try users().updateOne(io(), op(), .{}, .{ .@"$set" = Counter{ .n = 2 } }, .{ .allocator = gpa() });
}

test "updateMany with a stage of a pipeline that is a number" {
    _ = try users().updateMany(io(), op(), .{}, .{ .{ .@"$set" = .{ .a = 1 } }, @as(u32, 1) }, .{ .allocator = gpa() });
}

test "replaceOne with a pipeline" {
    _ = try users().replaceOne(io(), op(), .{}, .{.{ .@"$set" = .{ .a = 1 } }}, .{ .allocator = gpa() });
}

test "deleteMany with a filter that is a string" {
    _ = try users().deleteMany(io(), op(), "all", .{ .allocator = gpa() });
}

test "findOneAndUpdate with a pointer in the filter" {
    const ann: User = .{ .name = "Ann" };
    _ = try users().findOneAndUpdate(io(), op(), Post{ .owner = &ann }, .{ .@"$set" = .{ .n = 1 } }, .{ .allocator = gpa() });
}

test "findOneAndReplace with a pipeline" {
    _ = try users().findOneAndReplace(io(), op(), .{}, &.{.{ .@"$set" = .{ .a = 1 } }}, .{ .allocator = gpa() });
}

test "findOneAndDelete with a filter that is a tuple" {
    _ = try users().findOneAndDelete(io(), op(), .{ 1, 2 }, .{ .allocator = gpa() });
}

test "find with a filter that holds a u64" {
    _ = try users().find(io(), op(), Counter{ .n = 1 }, .{ .allocator = gpa() });
}

test "findOne with a filter that is a tuple" {
    _ = try users().findOne(io(), op(), .{ 1, 2 }, .{ .allocator = gpa() });
}

test "aggregate of one document" {
    _ = try users().aggregate(io(), op(), User{ .name = "Ann" }, .{ .allocator = gpa() });
}

test "aggregate with a stage that is a number" {
    _ = try users().aggregate(io(), op(), .{ .{ .@"$match" = .{} }, @as(u32, 1) }, .{ .allocator = gpa() });
}

test "countDocuments with a pointer in the filter" {
    const ann: User = .{ .name = "Ann" };
    _ = try users().countDocuments(io(), op(), Post{ .owner = &ann }, .{ .allocator = gpa() });
}

test "distinct with a filter that is a string" {
    _ = try users().distinct(io(), op(), "name", "all", .{ .allocator = gpa() });
}

test "runCommand of a tuple" {
    _ = try db().runCommand(io(), op(), .{ "ping", 1 }, .{ .allocator = gpa() });
}

test "runCursorCommand with a u64 in the command" {
    _ = try db().runCursorCommand(io(), op(), .{ .find = "users", .limit = @as(u64, 1) }, .{ .allocator = gpa() });
}
