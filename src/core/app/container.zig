//! zefir.App(Root): the container type of one application.
const std = @import("std");
const Options = @import("../app.zig").Options;

pub fn App(comptime Root: type) type {
    return struct {
        internal: Internal,

        pub const Internal = struct {
            gpa: std.mem.Allocator,
            io: std.Io,
            options: Options,
        };

        pub fn init(gpa: std.mem.Allocator, io: std.Io, values: anytype, options: Options) anyerror!@This() {
            _ = Root;
            _ = values;
            return .{ .internal = .{ .gpa = gpa, .io = io, .options = options } };
        }

        pub fn deinit(app: *@This()) void {
            app.* = undefined;
        }
    };
}
