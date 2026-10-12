const std = @import("std");
const v = @import("validator");

const Booking = struct {
    start_day: u32,
    end_day: u32,
    guests: u8,

    pub const field_rules = .{ .guests = v.positive };

    pub fn validateSelf(self: *const Booking) ?v.Violation {
        if (self.end_day < self.start_day)
            return v.fail(@This(), .end_day, "bookings.end_before_start", "must not be before the start day");
        if (self.end_day - self.start_day > 30)
            return v.fail(@This(), null, "bookings.too_long", "must not be longer than 30 days");
        return null;
    }
};

const Trip = struct {
    bookings: []const Booking,

    pub const field_rules = .{ .bookings = v.notEmpty };
};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const trip: Trip = .{
        .bookings = &.{
            .{ .start_day = 1, .end_day = 40, .guests = 2 }, // too long: the booking itself
            .{ .start_day = 5, .end_day = 3, .guests = 2 }, // ends before it starts: end_day
            .{ .start_day = 9, .end_day = 7, .guests = 0 }, // guests fails, so validateSelf does not run
        },
    };

    const report = try v.checkAll(init.gpa, &trip);
    defer report.deinit();
    for (report.violations) |violation| {
        try out.print("{s}: {s} ({s})\n", .{ violation.field orelse "(root)", violation.message, violation.code });
    }
}
