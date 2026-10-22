//! A golden application of zefir-openapi: the rules of the validator in
//! the document, a rule or more of each family (common, numbers, strings,
//! formats, encodings, identifiers, dates, lists, custom) and the
//! transforms. `?T` fields with rules that become `const`, `enum` and
//! `not`, which must still take `null`; `each` with transforms; patterns
//! with characters beyond ASCII; a check of fields together. The server has
//! the default error handler. Its document is
//! src/openapi/tests/golden/rules-3.1.json and -3.2.json.
//!
//! Application code: zefir ships no DTO or controller.
const std = @import("std");
const zefir = @import("zefir");
const http = zefir.http;
const v = zefir.validator;

pub const Request = @import("request.zig").Request;

pub const Role = enum { admin, user, guest };

fn isOdd(n: u32) bool {
    return n % 2 == 1;
}

/// A profile to make: the rules of every family.
pub const ProfileRequest = struct {
    // common
    role: Role = .user,
    nickname: ?[]const u8 = null,
    country: ?[]const u8 = null,
    agreed: ?[]const u8 = null,
    motto: ?[]const u8 = null,
    // numbers
    age: u8,
    score: i32 = 0,
    rating: f64 = 0,
    step: u32 = 5,
    // strings
    name: []const u8,
    handle: []const u8,
    bio: []const u8 = "",
    wide: ?[]const u8 = null,
    password: []const u8,
    // formats
    email: []const u8,
    website: ?[]const u8 = null,
    home: ?[]const u8 = null,
    remember: ?[]const u8 = null,
    // encodings
    avatar: ?[]const u8 = null,
    color: []const u8 = "#000000",
    // identifiers
    id: []const u8,
    iban: ?[]const u8 = null,
    // dates
    born: []const u8,
    member_since: ?[]const u8 = null,
    // lists
    tags: []const []const u8 = &.{},
    languages: []const []const u8 = &.{},
    // custom
    lucky: u32 = 7,

    pub const field_rules = .{
        .role = v.oneOf(.{ .admin, .user }),
        .nickname = v.noneOf(.{ "root", "admin" }),
        .country = v.oneOf(.{ "DE", "FR", "GB" }),
        .agreed = v.equals("yes"),
        .motto = v.notContains("http"),
        .age = v.range(18, 130),
        .score = .{ v.min(-100), v.max(100) },
        .rating = .{ v.finite, v.nonNegative },
        .step = .{ v.positive, v.divisibleBy(5) },
        .name = .{ v.trim, v.notBlank, v.maxLength(50) },
        .handle = .{ v.toLower, v.alphanumeric, v.length(3, 20) },
        .bio = .{ v.utf8, v.maxBytes(500) },
        .wide = v.fullWidth,
        .password = v.strongPassword(.{}),
        .email = .{ v.trim, v.email },
        .website = v.httpUrl,
        .home = v.ip,
        .remember = v.booleanString,
        .avatar = v.base64,
        .color = v.hexColor,
        .id = v.uuid,
        .iban = v.iban,
        .born = v.date,
        .member_since = .{ v.rename("memberSince"), v.minDate("2020-01-01") },
        .tags = .{ v.maxItems(5), v.uniqueItems, v.each(.{ v.trim, v.toLower, v.notBlank, v.maxLength(20) }) },
        .languages = v.each(v.oneOf(.{ "en", "de", "ru" })),
        .lucky = v.custom("profiles.lucky", "must be odd", isOdd),
    };

    /// A guest has no handle of the staff.
    pub fn validateSelf(self: *const ProfileRequest) ?v.Violation {
        if (self.role == .guest and std.mem.startsWith(u8, self.handle, "staff")) return v.fail(ProfileRequest, .handle, "profiles.guest_staff", "must not start with staff for a guest");
        return null;
    }

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .description = "A profile to make.",
        .fields = .{
            .name = .{ .description = "The name others see.", .example = "Ada" },
            .wide = .{ .description = "The name in full-width letters." },
            .lucky = .{ .description = "A number of luck." },
        },
    };
};

/// A profile as the API shows it: its rules are a contract too.
pub const ProfileView = struct {
    id: []const u8,
    handle: []const u8,
    email: []const u8,
    tags: []const []const u8,

    pub const field_rules = .{
        .id = v.uuid,
        .handle = .{ v.alphanumeric, v.length(3, 20) },
        .email = v.email,
        .tags = v.each(v.maxLength(20)),
    };
};

pub const HandlePath = struct {
    handle: []const u8,

    pub const field_rules = .{ .handle = .{ v.toLower, v.alphanumeric, v.length(3, 20) } };
};

pub const ListQuery = struct {
    role: ?Role = null,
    page: u32 = 1,
    sort: ?[]const u8 = null,

    pub const field_rules = .{
        .role = v.oneOf(.{ .admin, .user }),
        .page = v.range(1, 100),
        .sort = v.equals("name"),
    };
};

pub const ProfilesController = struct {
    const Create = http.post("", .{ .body = ProfileRequest, .responses = .{ .created = .{} } });
    const Get = http.get("/{handle}", .{ .path = HandlePath });
    const List = http.get("", .{ .query = ListQuery });

    pub const http_routes = http.routes(.{
        .prefix = "/v1/profiles",
        .methods = .{ .create = Create, .get = Get, .list = List },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{
        .tag = "Profiles",
        .routes = .{
            .create = .{ .summary = "Make a profile" },
            .get = .{ .summary = "Get a profile" },
            .list = .{ .summary = "List profiles" },
        },
    };

    pub fn create(_: *ProfilesController, ctx: *http.Context) !http.Json(ProfileView) {
        const in = try ctx.input(Create);
        return .{ .value = .{ .id = in.body.id, .handle = in.body.handle, .email = in.body.email, .tags = in.body.tags }, .status = 201 };
    }

    pub fn get(_: *ProfilesController, ctx: *http.Context) !http.Json(ProfileView) {
        const in = try ctx.input(Get);
        return .{ .value = .{ .id = "0b6b0c3a-6f1d-4c3e-9a63-1c3f0f1b2a4d", .handle = in.path.handle, .email = "ada@example.com", .tags = &.{} } };
    }

    pub fn list(_: *ProfilesController, ctx: *http.Context) !http.Json([]const ProfileView) {
        _ = try ctx.input(List);
        return .{ .value = &.{} };
    }
};

/// Builds the server and its documents, for the tests.
pub const Service = struct {
    profiles: ProfilesController = .{},
    docs_3_1: zefir.openapi.Document = undefined,
    docs_3_2: zefir.openapi.Document = undefined,
    server: http.Server = undefined,

    pub fn start(s: *Service, gpa: std.mem.Allocator, io: std.Io, backend: http.Backend) !void {
        const parts = .{
            .controllers = .{&s.profiles},
        };
        const info: zefir.openapi.DocumentOptions.Info = .{ .title = "Profiles API", .version = "1.0.0" };
        s.docs_3_1 = comptime zefir.openapi.document(@TypeOf(parts), .{ .info = info, .prefix = "/api" });
        s.docs_3_2 = comptime zefir.openapi.document(@TypeOf(parts), .{ .info = info, .version = .@"3.2", .prefix = "/api" });
        s.server = try .init(gpa, parts, .{ .listen = .{ .backend = backend }, .prefix = "/api" });
        errdefer s.server.deinit(io);
        try s.server.start(io);
    }

    pub fn deinit(s: *Service, io: std.Io) void {
        s.server.deinit(io);
    }
};

const json: [2][]const u8 = .{ "content-type", "application/json" };
/// The fields a profile needs, its name and handle aside.
const rest = "\"age\":30,\"password\":\"Str0ng!pass\",\"email\":\"ada@example.com\",\"id\":\"0b6b0c3a-6f1d-4c3e-9a63-1c3f0f1b2a4d\",\"born\":\"1990-12-10\"";
const required = "\"name\":\"Ada\",\"handle\":\"Ada\"," ++ rest;

pub const requests = [_]Request{
    .{ .method = .POST, .target = "/api/v1/profiles", .headers = &.{json}, .body = "{" ++ required ++ "}", .status = 201 },
    // The optional fields with const, enum and not rules take null.
    .{ .method = .POST, .target = "/api/v1/profiles", .headers = &.{json}, .status = 201, .body = "{" ++ required ++
        ",\"nickname\":null,\"country\":null,\"agreed\":null,\"motto\":null,\"wide\":null,\"memberSince\":null}" },
    .{ .method = .POST, .target = "/api/v1/profiles", .headers = &.{json}, .status = 201, .body = "{" ++ required ++
        ",\"role\":\"admin\",\"nickname\":\"ada\",\"country\":\"GB\",\"agreed\":\"yes\",\"motto\":\"Count on it\",\"score\":-5,\"rating\":4.5,\"step\":10," ++
        "\"bio\":\"Mathematician\",\"wide\":\"ＡＤＡ\",\"website\":\"https://ada.example.com\",\"home\":\"192.0.2.1\",\"remember\":\"true\"," ++
        "\"avatar\":\"QWRh\",\"color\":\"#ff8800\",\"iban\":\"GB82WEST12345698765432\",\"memberSince\":\"2021-05-01\"," ++
        "\"tags\":[\" Math \",\"poetry\"],\"languages\":[\"en\"],\"lucky\":3}" },
    .{ .method = .POST, .target = "/api/v1/profiles", .headers = &.{json}, .body = "{\"name\":\"   \",\"handle\":\"Ada\"," ++ rest ++ "}", .status = 422 },
    .{ .method = .POST, .target = "/api/v1/profiles", .headers = &.{json}, .body = "{" ++ required ++ ",\"agreed\":\"no\",\"lucky\":4}", .status = 422 },
    .{ .method = .POST, .target = "/api/v1/profiles", .headers = &.{json}, .body = "{\"name\":\"Ann\",\"handle\":\"staffann\",\"role\":\"guest\"," ++ rest ++ "}", .status = 422 },
    .{ .method = .POST, .target = "/api/v1/profiles", .headers = &.{json}, .body = "{\"age\":", .status = 400 },
    .{ .method = .GET, .target = "/api/v1/profiles/Ada", .status = 200 },
    .{ .method = .GET, .target = "/api/v1/profiles/a", .status = 422 },
    .{ .method = .GET, .target = "/api/v1/profiles?role=admin&page=2&sort=name", .status = 200 },
    .{ .method = .GET, .target = "/api/v1/profiles?page=0", .status = 422 },
};
