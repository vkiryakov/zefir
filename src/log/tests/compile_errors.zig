//! Calls that must not compile, one test each. `zig build test` compiles
//! every test on its own and checks its error message; the list of
//! messages is in build.zig.

const log = @import("log");

/// Never called at run time: these tests only have to fail to compile.
fn logger() log.Logger {
    return undefined;
}

test "fields that are not a struct" {
    logger().info("m", 42);
}

test "positional fields" {
    logger().info("m", .{1});
}

test "reserved field name" {
    logger().info("m", .{ .level = 1 });
}

test "dotted service field" {
    logger().info("m", .{ .@"service.name" = "x" });
}

test "subfield of the source object" {
    logger().info("m", .{ .@"source.file" = "x" });
}

test "name with a space" {
    logger().info("m", .{ .@"user id" = 1 });
}

test "src of the wrong type" {
    logger().info("m", .{ .src = 42 });
}

test "error union value" {
    const result: anyerror!u8 = 1;
    logger().info("m", .{ .value = result });
}

test "void value" {
    logger().info("m", .{ .nothing = {} });
}

test "struct value" {
    const Point = struct { x: i32, y: i32 };
    logger().info("m", .{ .point = Point{ .x = 1, .y = 2 } });
}
