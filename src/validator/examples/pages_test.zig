//! The full code examples of the rule pages, compiled: each is declared here
//! exactly as its page shows it, and a test checks the values that the page
//! and the example's comments describe. The last test checks that every
//! example of a page, a block of code that declares `field_rules` or
//! `validateSelf`, appears verbatim in this file, so an example that changes
//! on its page or here alone fails it.

const std = @import("std");
const v = @import("validator");
const h = @import("vtest");
const testing = std.testing;

// ------------------------------------------------------------------ common.md

const Role = enum { admin, editor, viewer };

const Team = struct {
    name: []const u8,
    members: []const []const u8,
    motto: ?[]const u8 = null,
    lead: Role,
    accepted: bool,

    pub const field_rules = .{
        .name = .{ v.notEmpty, v.noneOf(.{ "admin", "root" }) },
        .members = .{ v.notEmpty, v.each(v.notEmpty) },
        .motto = v.notEmpty, // null skips the rule
        .lead = v.oneOf(.{ .admin, .editor }),
        .accepted = v.equals(true),
    };
};

test "the example of the common page checks a team" {
    comptime v.assertRules(Team);
    try h.expectValid(&Team{ .name = "core", .members = &.{"ann"}, .lead = .editor, .accepted = true });
    try h.expectAll(&Team{ .name = "root", .members = &.{ "ann", "" }, .motto = "", .lead = .viewer, .accepted = false }, &.{
        .{ .code = "validation.none_of", .field = "name" },
        .{ .code = "validation.not_empty", .field = "members[1]" },
        .{ .code = "validation.not_empty", .field = "motto" },
        .{ .code = "validation.one_of", .field = "lead" },
        .{ .code = "validation.equals", .field = "accepted" },
    });
}

// ------------------------------------------------------------------ numbers.md

const Payment = struct {
    amount_cents: u64,
    rate: f64,
    installments: []const u32,
    retries: u8,

    pub const field_rules = .{
        .amount_cents = .{ v.positive, v.divisibleBy(5) },
        .rate = v.range(0, 1), // NaN and infinities fail first, with validation.finite
        .installments = v.each(v.positive),
        .retries = v.max(5),
    };
};

test "the example of the numbers page checks a payment" {
    comptime v.assertRules(Payment);
    try h.expectValid(&Payment{ .amount_cents = 1500, .rate = 0.25, .installments = &.{ 500, 1000 }, .retries = 5 });
    try h.expectAll(&Payment{ .amount_cents = 1501, .rate = std.math.nan(f64), .installments = &.{ 500, 0 }, .retries = 6 }, &.{
        .{ .code = "validation.divisible_by", .field = "amount_cents" },
        .{ .code = "validation.finite", .field = "rate" },
        .{ .code = "validation.positive", .field = "installments[1]" },
        .{ .code = "validation.max", .field = "retries" },
    });
    try h.expectAt(&Payment{ .amount_cents = 5, .rate = 1.5, .installments = &.{}, .retries = 0 }, "validation.range", "must be from 0 to 1", "rate");
}

// ------------------------------------------------------------------ strings.md

const SignUp = struct {
    name: []const u8,
    login: []const u8,
    password: []const u8,
    pin: ?[]const u8 = null,
    tags: []const []const u8 = &.{},

    pub const field_rules = .{
        .name = .{ v.notBlank, v.maxLength(64) },
        .login = .{ v.length(3, 32), v.alphanumeric, v.lowercase },
        .password = .{ v.maxLength(128), v.strongPassword(.{ .min_length = 12 }) },
        .pin = .{ v.length(4, 4), v.digits }, // null skips the rules
        .tags = v.each(.{ v.notEmpty, v.notContains(" ") }),
    };
};

test "the example of the strings page checks a sign-up" {
    comptime v.assertRules(SignUp);
    try h.expectValid(&SignUp{ .name = "Ada Lovelace", .login = "ada", .password = "Correct-Horse-9", .tags = &.{"zig"} });
    try h.expectAll(&SignUp{ .name = " \t", .login = "Ada", .password = "password", .pin = "12a4", .tags = &.{ "go", "zig lang" } }, &.{
        .{ .code = "validation.not_blank", .field = "name" },
        .{ .code = "validation.lowercase", .field = "login" },
        .{ .code = "validation.strong_password", .field = "password" },
        .{ .code = "validation.digits", .field = "pin" },
        .{ .code = "validation.not_contains", .field = "tags[1]" },
    });
}

// ------------------------------------------------------------------ formats.md

const Server = struct {
    host: []const u8,
    port: []const u8,
    admin: ?[]const u8 = null,
    mirrors: []const []const u8 = &.{},
    lat: f64,

    pub const field_rules = .{
        .host = v.fqdn(.{ .require_tld = false }), // "localhost" passes
        .port = v.port,
        .admin = v.email, // null skips the rule
        .mirrors = .{ v.maxItems(5), v.each(v.httpUrl) },
        .lat = v.latitude, // a float field: NaN fails with validation.finite
    };
};

test "the example of the formats page checks a server" {
    comptime v.assertRules(Server);
    try h.expectValid(&Server{ .host = "localhost", .port = "8080", .mirrors = &.{"https://mirror.example.com/"}, .lat = 59.9 });
    try h.expectAll(&Server{ .host = "-bad", .port = "080", .admin = "ops@localhost", .mirrors = &.{"ftp://x"}, .lat = std.math.nan(f64) }, &.{
        .{ .code = "validation.fqdn", .field = "host" },
        .{ .code = "validation.port", .field = "port" },
        .{ .code = "validation.email", .field = "admin" },
        .{ .code = "validation.http_url", .field = "mirrors[0]" },
        .{ .code = "validation.finite", .field = "lat" },
    });
}

// ------------------------------------------------------------------ encodings.md

const Upload = struct {
    metadata: []const u8,
    content: []const u8,
    content_type: []const u8,
    language: ?[]const u8 = null,
    tags: []const []const u8,

    pub const field_rules = .{
        .metadata = v.json,
        .content = .{ v.notEmpty, v.base64 }, // "" is valid base64: require content first
        .content_type = v.mimeType,
        .language = v.locale, // null skips the rule
        .tags = v.each(v.hexColor),
    };
};

test "the example of the encodings page checks an upload" {
    comptime v.assertRules(Upload);
    try h.expectValid(&Upload{ .metadata = "{\"size\":3}", .content = "Zm9v", .content_type = "text/plain; charset=utf-8", .tags = &.{ "#fff", "#ff000080" } });
    try h.expectAll(&Upload{ .metadata = "3", .content = "", .content_type = "text", .language = "en_US", .tags = &.{ "#fff", "fff" } }, &.{
        .{ .code = "validation.json", .field = "metadata" },
        .{ .code = "validation.not_empty", .field = "content" },
        .{ .code = "validation.mime_type", .field = "content_type" },
        .{ .code = "validation.locale", .field = "language" },
        .{ .code = "validation.hex_color", .field = "tags[1]" },
    });
}

// ------------------------------------------------------------------ identifiers.md

const Payout = struct {
    request_id: []const u8,
    iban: []const u8,
    bic: ?[]const u8 = null,
    wallet: ?[]const u8 = null,
    receipt_digest: []const u8,
    isbns: []const []const u8,

    pub const field_rules = .{
        .request_id = v.uuid,
        .iban = v.iban, // upper case, no spaces: normalize before the check
        .bic = v.bic, // null skips the rule
        .wallet = v.btcAddress(.mainnet),
        .receipt_digest = v.hash(.sha256),
        .isbns = v.each(v.isbn),
    };
};

const Withdrawal = struct {
    network: v.BtcNetwork, // chosen by the user
    address: []const u8,

    pub fn validateSelf(self: *const Withdrawal) ?v.Violation {
        if (!v.isBtcAddress(self.address, self.network))
            return v.fail(@This(), .address, "withdrawals.bad_address", "must be a Bitcoin address of the chosen network");
        return null;
    }
};

test "the examples of the identifiers page check a payout and a withdrawal" {
    comptime v.assertRules(Payout);
    comptime v.assertRules(Withdrawal);
    const good: Payout = .{
        .request_id = "f81d4fae-7dec-11d0-a765-00a0c91e6bf6",
        .iban = "DE89370400440532013000",
        .receipt_digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        .isbns = &.{ "9780306406157", "080442957X" },
    };
    try h.expectValid(&good);
    var bad = good;
    bad.iban = "DE89 3704 0044 0532 0130 00";
    bad.bic = "deutdeff";
    bad.isbns = &.{ "9780306406157", "978-0-306-40615-7" };
    try h.expectAll(&bad, &.{
        .{ .code = "validation.iban", .field = "iban" },
        .{ .code = "validation.bic", .field = "bic" },
        .{ .code = "validation.isbn", .field = "isbns[1]" },
    });
    try h.expectValid(&Withdrawal{ .network = .testnet, .address = "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx" });
    try h.expectAt(&Withdrawal{ .network = .mainnet, .address = "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx" }, "withdrawals.bad_address", "must be a Bitcoin address of the chosen network", "address");
}

// ------------------------------------------------------------------ dates.md

const Booking = struct {
    check_in: []const u8,
    created_at: []const u8,
    reminder: ?[]const u8 = null,
    opening_hours: []const []const u8,

    pub const field_rules = .{
        .check_in = .{ v.date.withMessage("use YYYY-MM-DD"), v.minDate("2024-01-01") },
        .created_at = v.maxDate("2100-01-01T00:00:00Z"), // a date-time bound: the value needs an offset
        .reminder = v.rfc3339, // null skips the rule
        .opening_hours = v.each(v.militaryTime),
    };
};

test "the example of the dates page checks a booking" {
    comptime v.assertRules(Booking);
    try h.expectValid(&Booking{ .check_in = "2024-02-29", .created_at = "2024-01-01T10:00:00+02:00", .opening_hours = &.{ "09:00", "1800" } });
    try h.expectAll(&Booking{ .check_in = "29.02.2024", .created_at = "2024-01-01", .reminder = "2024-01-01T10:00", .opening_hours = &.{ "09:00", "24:00" } }, &.{
        .{ .code = "validation.date", .field = "check_in" },
        .{ .code = "validation.rfc3339", .field = "created_at" },
        .{ .code = "validation.rfc3339", .field = "reminder" },
        .{ .code = "validation.military_time", .field = "opening_hours[1]" },
    });
    try h.expectAt(&Booking{ .check_in = "2023-12-31", .created_at = "2024-01-01T10:00:00Z", .opening_hours = &.{} }, "validation.min_date", "must not be before 2024-01-01", "check_in");
    try h.expectAt(&Booking{ .check_in = "29.02.2024", .created_at = "2024-01-01T10:00:00Z", .opening_hours = &.{} }, "validation.date", "use YYYY-MM-DD", "check_in");
}

// ------------------------------------------------------------------ lists.md

const Order = struct {
    tags: []const []const u8,
    quantities: [3]u32,
    scores: []const ?f64,

    pub const field_rules = .{
        .tags = .{ v.maxItems(10), v.uniqueItems, v.each(v.notEmpty) }, // the list, then each item
        .quantities = v.each(v.positive),
        .scores = v.each(v.positive), // null items are skipped
    };
};

test "the example of the lists page checks an order" {
    comptime v.assertRules(Order);
    try h.expectValid(&Order{ .tags = &.{ "a", "b" }, .quantities = .{ 1, 2, 3 }, .scores = &.{ 1.5, null } });
    try h.expectAll(&Order{ .tags = &.{ "a", "a" }, .quantities = .{ 1, 0, 2 }, .scores = &.{ null, -1 } }, &.{
        .{ .code = "validation.unique_items", .field = "tags" },
        .{ .code = "validation.positive", .field = "quantities[1]" },
        .{ .code = "validation.positive", .field = "scores[1]" },
    });
    try h.expectAt(&Order{ .tags = &.{ "a", "" }, .quantities = .{ 1, 2, 3 }, .scores = &.{} }, "validation.not_empty", "must not be empty", "tags[1]");
}

// ------------------------------------------------------------------ the pages

/// The rule pages, each with at least one example.
const pages = .{ "common.md", "numbers.md", "strings.md", "formats.md", "encodings.md", "identifiers.md", "dates.md", "lists.md" };

test "every example of the rule pages is declared in this file as its page shows it" {
    const gpa = testing.allocator;
    // Git may check files out with CRLF on Windows.
    const own = try std.mem.replaceOwned(u8, gpa, @embedFile("pages_test.zig"), "\r\n", "\n");
    defer gpa.free(own);
    inline for (pages) |page| {
        const doc = try std.mem.replaceOwned(u8, gpa, @embedFile(page), "\r\n", "\n");
        defer gpa.free(doc);
        var examples: usize = 0;
        var rest: []const u8 = doc;
        while (std.mem.find(u8, rest, "```zig\n")) |start| {
            const body = rest[start + "```zig\n".len ..];
            const end = std.mem.find(u8, body, "\n```") orelse return error.TestUnclosedBlock;
            const block = body[0 .. end + 1];
            rest = body[end + "\n```".len ..];
            if (std.mem.find(u8, block, "field_rules") == null and std.mem.find(u8, block, "validateSelf") == null) continue;
            examples += 1;
            if (std.mem.find(u8, own, block) == null) {
                std.debug.print("{s} shows an example that pages_test.zig does not declare verbatim:\n{s}\n", .{ page, block });
                return error.TestExampleNotCompiled;
            }
        }
        if (examples == 0) {
            std.debug.print("{s} shows no example with field_rules or validateSelf\n", .{page});
            return error.TestPageWithoutExample;
        }
    }
}
