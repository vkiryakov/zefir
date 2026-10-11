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

test "value of a type that has no loggable form" {
    logger().info("m", .{ .x = undefined });
}

test "untagged union" {
    const U = union { a: u8, b: u16 };
    logger().info("m", .{ .u = U{ .a = 1 } });
}

test "many-item pointer" {
    var p: [*]const u8 = "x";
    _ = &p;
    logger().info("m", .{ .p = p });
}

test "C pointer" {
    var p: [*c]const u8 = null;
    _ = &p;
    logger().info("m", .{ .p = p });
}

test "pointer to an opaque type" {
    var p: *anyopaque = undefined;
    _ = &p;
    logger().info("m", .{ .p = p });
}

test "function pointer" {
    const f: *const fn () void = struct {
        fn f() void {}
    }.f;
    logger().info("m", .{ .f = f });
}

test "reserved name on the flat path" {
    logger().info("m", .{ .service = .{ .name = "x" } });
}

test "nested name with a space" {
    const S = struct { @"a b": u8 };
    logger().info("m", .{ .s = S{ .@"a b" = 1 } });
}

test "nested error union" {
    const result: anyerror!u8 = 1;
    logger().info("m", .{ .cfg = .{ .r = result } });
}

test "sensitive marker of the wrong type" {
    const T = struct {
        x: u8,
        pub const zefir_sensitive = 1;
    };
    logger().info("m", .{ .t = T{ .x = 1 } });
}

test "logValue that returns its own type" {
    const L = struct {
        x: u8,
        pub fn logValue(l: @This()) @This() {
            return l;
        }
    };
    logger().info("m", .{ .l = L{ .x = 1 } });
}
