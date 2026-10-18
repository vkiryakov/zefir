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
