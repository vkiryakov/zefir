const std = @import("std");
const log = @import("log");
const v = @import("validator");

const Room = enum { single, double, family };

const Booking = struct {
    room: Room,
    guests: u8,
    check_in: []const u8,
    check_out: []const u8,

    pub const field_rules = .{
        .guests = v.positive,
        .check_in = v.date,
        .check_out = v.date,
    };

    pub fn validateSelf(self: *const Booking) ?v.Violation {
        // It runs only when every field passed: both dates are YYYY-MM-DD, so
        // they compare as strings.
        if (!std.mem.lessThan(u8, self.check_in, self.check_out))
            return v.fail(@This(), .check_out, "bookings.check_out_too_early", "must be after the check-in date");
        const beds: u8 = switch (self.room) {
            .single => 1,
            .double => 2,
            .family => 4,
        };
        if (self.guests > beds)
            return v.fail(@This(), null, "bookings.too_many_guests", "must have a bed for every guest");
        return null;
    }
};

const Trip = struct {
    bookings: []const Booking,

    pub const field_rules = .{ .bookings = .{ v.notEmpty, v.maxItems(10) } };
};

pub fn main(init: std.process.Init) !void {
    const logger: log.Logger = try .init(init.gpa, init.io, .{
        .service = .{ .name = "booking-service" },
        .format = .text,
    });
    defer logger.deinit();

    const trip: Trip = .{
        .bookings = &.{
            // three guests, two beds: the booking itself
            .{ .room = .double, .guests = 3, .check_in = "2026-07-01", .check_out = "2026-07-05" },
            // checks out before it checks in: check_out
            .{ .room = .single, .guests = 1, .check_in = "2026-07-05", .check_out = "2026-07-03" },
            // guests fails, so validateSelf does not run
            .{ .room = .family, .guests = 0, .check_in = "2026-07-09", .check_out = "2026-07-09" },
        },
    };

    const report = try v.checkAll(init.gpa, &trip);
    defer report.deinit();
    for (report.violations) |violation| {
        logger.warn("Invalid trip", .{ .field = violation.field, .code = violation.code, .reason = violation.message });
    }
}
