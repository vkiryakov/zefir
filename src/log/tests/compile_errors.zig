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

test "sensitive type as the fields" {
    const Key = struct {
        value: []const u8,
        pub const zefir_sensitive = true;
    };
    logger().info("m", Key{ .value = "x" });
}

test "type with its own logged form as the fields" {
    const Creds = struct {
        user: []const u8,
        pin: []const u8,
        pub fn logValue(c: @This()) []const u8 {
            return c.user;
        }
    };
    logger().info("m", Creds{ .user = "ada", .pin = "1234" });
}

test "format of another form" {
    const Other = struct {
        pub fn format(_: @This(), _: []const u8) void {}
    };
    logger().info("m", .{ .o = Other{} });
}

test "logValue with a mutable self" {
    const Mutable = struct {
        x: u8,
        pub fn logValue(m: *@This()) u8 {
            return m.x;
        }
    };
    logger().info("m", .{ .m = Mutable{ .x = 1 } });
}

test "logValue that returns an error union" {
    const Failing = struct {
        x: u8,
        pub fn logValue(f: @This()) anyerror!u8 {
            return f.x;
        }
    };
    logger().info("m", .{ .f = Failing{ .x = 1 } });
}

test "reserved name on the flat path through an array" {
    const Named = struct { name: []const u8 };
    logger().info("m", .{ .service = [_]Named{.{ .name = "x" }} });
}

test "subfield of the call site" {
    logger().info("m", .{ .@"src.function" = "x" });
}

fn someFunction() void {}

test "function value" {
    logger().info("m", .{ .f = someFunction });
}

test "many-item pointer to u16 with a sentinel" {
    var p: [*:0]const u16 = &[_:0]u16{1};
    _ = &p;
    logger().info("m", .{ .p = p });
}

test "packed union" {
    const P = packed union { a: u8, b: i8 };
    logger().info("m", .{ .p = P{ .a = 1 } });
}

test "optional void" {
    logger().info("m", .{ .x = @as(?void, {}) });
}
