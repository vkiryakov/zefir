const std = @import("std");
const log = @import("log");
const v = @import("validator");

const Plan = enum { free, pro, team };

const SignUp = struct {
    email: []const u8,
    plan: Plan,
    seats: u32,
    budget_eur: f64,
    accepted_terms: bool,
    referrer_id: ?u64 = null,

    // The rules of the fields. The validator finds them by this name, so the
    // struct must declare them as `pub const field_rules`.
    pub const field_rules = .{
        .email = v.email,
        .plan = v.oneOf(.{ .pro, .team }), // paid plans only
        .seats = v.range(1, 500),
        .budget_eur = v.min(10.0),
        .accepted_terms = v.equals(true),
        .referrer_id = v.positive, // null skips the rule
    };
};

pub fn main(init: std.process.Init) !void {
    const logger: log.Logger = try .init(init.gpa, init.io, .{
        .service = .{ .name = "user-service" },
        .format = .text,
    });
    defer logger.deinit();

    // The value to check, for example a decoded request body.
    const request: SignUp = .{
        .email = "ada@example.com",
        .plan = .team,
        .seats = 0,
        .budget_eur = 250.0,
        .accepted_terms = true,
    };

    // v.check allocates no memory, so it needs room from you to write the path
    // of the field that failed, such as "seats"; violation.field points into it.
    var path_buf: [256]u8 = undefined;
    if (v.check(&request, &path_buf)) |violation| {
        logger.warn("Invalid sign-up", .{ .field = violation.field, .code = violation.code, .reason = violation.message });
    }
}
