//! Must not compile: an array is not a field type of confy. README.md
//! shows the message.

const std = @import("std");
const confy = @import("confy");

const Config = struct {
    address: [4]u8, // compile error: fields of type [4]u8 are not supported
};

test {
    var config: Config = undefined;
    try confy.load(std.testing.allocator, &config, .{ .io = std.testing.io, .sources = &.{} });
}
