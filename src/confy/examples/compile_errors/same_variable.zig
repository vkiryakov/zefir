//! Must not compile: `db_port` and `db.port` both map to the variable
//! DB_PORT. README.md shows the struct and the message.

const std = @import("std");
const confy = @import("confy");

const Config = struct {
    db_port: u16,
    db: struct { port: u16 }, // compile error: both fields map to DB_PORT
};

test {
    var config: Config = undefined;
    try confy.load(std.testing.allocator, &config, .{ .io = std.testing.io, .sources = &.{} });
}
