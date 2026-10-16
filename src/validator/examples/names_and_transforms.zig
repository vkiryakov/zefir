const std = @import("std");
const log = @import("log");
const v = @import("validator");

/// Drops the spaces, dashes, dots and parentheses that people type between
/// the digits of a phone number: "+44 (20) 7946-0958" becomes
/// "+442079460958". Anything else stays, for the rule after it to judge.
fn normalizePhone(allocator: std.mem.Allocator, phone: []const u8) std.mem.Allocator.Error![]const u8 {
    const separators = " -.()";
    if (std.mem.findAny(u8, phone, separators) == null) return phone; // nothing to drop, nothing allocated
    const out = try allocator.alloc(u8, phone.len);
    var len: usize = 0;
    for (phone) |c| {
        if (std.mem.findScalar(u8, separators, c) != null) continue;
        out[len] = c;
        len += 1;
    }
    return out[0..len];
}

/// A phone number in E.164 form: "+" and 8 to 15 digits.
fn isE164(phone: []const u8) bool {
    if (phone.len < 9 or phone.len > 16 or phone[0] != '+') return false;
    for (phone[1..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

const Speaker = struct {
    display_name: []const u8,
    email: []const u8,
    country: []const u8,
    phone: ?[]const u8 = null,

    // Per field, in this order: the outside name, the transforms, the rules.
    pub const field_rules = .{
        .display_name = .{ v.rename("displayName"), v.trim, v.notBlank, v.maxLength(60) },
        .email = .{ v.trim, v.toLower, v.email },
        .country = .{ v.trim, v.toUpper, v.length(2, 2), v.alpha },
        .phone = .{ // null skips it all
            v.transformWith(normalizePhone),
            v.custom("talks.phone_e164", "must be a phone number such as +442079460958", isE164),
        },
    };
};

const TalkProposal = struct {
    title: []const u8,
    duration_minutes: u16,
    tags: []const []const u8,
    speakers: []const Speaker, // every speaker gets the names and transforms of Speaker

    pub const field_rules = .{
        .title = .{ v.trim, v.length(10, 80) },
        .duration_minutes = .{ v.rename("durationMinutes"), v.oneOf(.{ 25, 50 }) },
        .tags = .{ v.maxItems(5), v.uniqueItems, v.each(.{ v.trim, v.toLower, v.notEmpty }) },
        .speakers = .{ v.notEmpty, v.maxItems(3) },
    };
};

pub fn main(init: std.process.Init) !void {
    const logger: log.Logger = try .init(init.gpa, init.io, .{
        .service = .{ .name = "talks-service" },
        .format = .text,
    });
    defer logger.deinit();

    // A proposal as a decoder read it from the form: found by the outside
    // names (durationMinutes, displayName), with the values as people typed them.
    var proposal: TalkProposal = .{
        .title = "  Comptime for the rest of us ",
        .duration_minutes = 30,
        .tags = &.{ " Zig ", "comptime", "ZIG" },
        .speakers = &.{
            .{ .display_name = " Ada Lovelace", .email = " Ada@Example.COM ", .country = "gb", .phone = "+44 (20) 7946-0958" },
            .{ .display_name = " \t", .email = "grace@example.org", .country = "US " },
        },
    };
    const before = proposal; // the strings and lists it points to stay as they are

    // What the transforms allocate lives in an arena, freed with the request.
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    try v.transform(arena.allocator(), &proposal); // 1. the transforms

    logger.info("Normalized", .{ .field = "title", .before = before.title, .after = proposal.title });
    logger.info("Normalized", .{ .field = "tags", .before = before.tags, .after = proposal.tags });
    logger.info("Normalized", .{ .field = "speakers[0].email", .before = before.speakers[0].email, .after = proposal.speakers[0].email });
    logger.info("Normalized", .{ .field = "speakers[0].country", .before = before.speakers[0].country, .after = proposal.speakers[0].country });
    logger.info("Normalized", .{ .field = "speakers[0].phone", .before = before.speakers[0].phone, .after = proposal.speakers[0].phone });

    const report = try v.checkAll(init.gpa, &proposal); // 2. the rules, on the normalized value
    defer report.deinit();
    for (report.violations) |violation| {
        logger.warn("Invalid proposal", .{ .field = violation.field, .code = violation.code, .reason = violation.message });
    }
}
