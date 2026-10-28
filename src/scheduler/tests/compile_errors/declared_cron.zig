//! Must not compile: a cron expression in a declaration, through an
//! optional field, as the `.repeat` of a job declares one; the 31st
//! never comes in the months it names.
const scheduler = @import("scheduler");

const Declaration = struct {
    name: []const u8,
    repeat: ?scheduler.Schedule = null,
};

pub const declared: Declaration = .{ .name = "report", .repeat = .cron("0 0 31 4,6,9,11 *") };

test {
    _ = declared;
}
