#!/usr/bin/env python3
"""Writes app.zig, the synthetic application of the openapi probe.

    gen_app.py <routes> <app.zig>

The application is what design 1.2 of zefir-openapi calls typical, written
as an application of zefir-openapi writes it: its routes are those of REST
resources, five each (list, create, get, update, delete), six resources to
a controller of thirty routes. Every route declares its input (.path,
.query, .body) and reads it with ctx.input; create declares its 201 in
.responses. The DTOs have 4 to 8 fields with field_rules (v.rename,
ranges, lengths, formats, lists), and every DTO, controller and
middleware declares its texts in a typed `pub const openapi`
(zefir.openapi.Doc, ControllerDoc, MiddlewareDoc): security schemes, the
requirement and roles. The middleware runs on three levels, and the error
handler maps twenty errors of the application. `Service.start` builds the
server with http.Server.init and, for the variant it is given, the
document from the type of the same options with zefir.openapi.document.

Python rather than Zig, so that its output can be checked with
`zig ast-check` without building anything.
"""

import sys

ROUTES_PER_CONTROLLER = 30
KINDS = ["list", "create", "get", "update", "delete"]
RESOURCES_PER_CONTROLLER = ROUTES_PER_CONTROLLER // len(KINDS)

# The errors of the application: name, status, code, message.
APP_ERRORS = [
    ("NotFound", 404, "not_found", "The item does not exist."),
    ("AlreadyExists", 409, "already_exists", "An item with this name exists."),
    ("Conflict", 409, "conflict", "The item changed meanwhile."),
    ("LimitReached", 429, "limit_reached", "Too many items."),
    ("AccountSuspended", 403, "account_suspended", "The account is suspended."),
    ("NotOwner", 403, "not_owner", "Only the owner may do this."),
    ("QuotaExceeded", 429, "quota_exceeded", "The quota of the month is used up."),
    ("PaymentRequired", 402, "payment_required", "The plan does not include this."),
    ("Gone", 410, "gone", "The item was deleted."),
    ("Locked", 423, "locked", "The item is locked."),
    ("PreconditionFailed", 412, "precondition_failed", "The item does not match If-Match."),
    ("TooEarly", 425, "too_early", "Try again later."),
    ("InvalidState", 409, "invalid_state", "The item cannot do this now."),
    ("DependencyFailed", 424, "dependency_failed", "A step before this one failed."),
    ("StaleVersion", 409, "stale_version", "The version is not the latest."),
    ("ReadOnly", 403, "read_only", "The item is read-only."),
    ("Archived", 410, "archived", "The item is archived."),
    ("Banned", 403, "banned", "The user is banned."),
    ("Expired", 410, "expired", "The offer expired."),
    ("UpstreamDown", 503, "upstream_down", "A service it needs is down."),
]

# Fields of the bodies that create an item: name, type with its default,
# entry of field_rules (None for none), description.
CREATE_POOL = [
    ("display_name", "[]const u8", '.{ v.rename("displayName"), v.trim, v.length(1, 80) }', "The name shown to other users."),
    ("age", "u8", "v.range(18, 130)", "The age of the owner, in years."),
    ("website", "?[]const u8 = null", "v.httpUrl", "A web page about it."),
    ("price_cents", "u64", '.{ v.rename("priceCents"), v.positive }', "The price, in cents."),
    ("currency", '[]const u8 = "EUR"', 'v.oneOf(.{ "EUR", "USD", "GBP" })', "The currency of the price."),
    ("tags", "[]const []const u8 = &.{}", ".{ v.maxItems(10), v.each(.{ v.trim, v.maxLength(20) }) }", "Labels to find it by."),
    ("priority", "Priority = .normal", None, "How urgent it is."),
    ("address", "Address", None, "Where it is."),
    ("external_id", "?[]const u8 = null", '.{ v.rename("externalId"), v.uuid }', "Its id in another system."),
    ("due_date", "?[]const u8 = null", '.{ v.rename("dueDate"), v.date }', "When it is due."),
    ("quantity", "u32 = 1", "v.range(1, 1000)", "How many of it."),
    ("weight_kg", "?f64 = null", '.{ v.rename("weightKg"), v.positive }', "Its weight, in kilograms."),
]

# Fields of the items the API answers with: name, type, entry, description,
# a value for the sample.
ITEM_POOL = [
    ("email", "[]const u8", "v.email", "The email of the owner.", '"ada@example.com"'),
    ("priority", "Priority", None, "How urgent it is.", ".normal"),
    ("address", "Address", None, "Where it is.", "sample_address"),
    ("tags", "[]const []const u8", "v.maxItems(10)", "Labels to find it by.", "&.{}"),
    ("score", "u32", "v.max(1000)", "Its score, from 0 to 1000.", "1"),
    ("note", "?[]const u8", "v.maxLength(500)", "A note of the owner.", "null"),
    ("price_cents", "u64", 'v.rename("priceCents")', "The price, in cents.", "100"),
    ("website", "?[]const u8", "v.httpUrl", "A web page about it.", "null"),
    ("updated_at", "?[]const u8", '.{ v.rename("updatedAt"), v.rfc3339 }', "When it last changed.", "null"),
]


def dto(name, fields, description, unknown=None):
    """A struct of fields (name, type, entry, description) with its
    field_rules and its typed `pub const openapi`."""
    out = [f"pub const {name} = struct {{"]
    for field, decl, _, _ in fields:
        out.append(f"    {field}: {decl},")
    out.append("")
    entries = [(field, entry) for field, _, entry, _ in fields if entry is not None]
    if entries:
        out.append("    pub const field_rules = .{")
        for field, entry in entries:
            out.append(f"        .{field} = {entry},")
        out.append("    };")
    if unknown is not None:
        out.append(f"    pub const unknown_fields = .{unknown};")
    out.append("    pub const openapi: oa.Doc(@This()) = .{")
    out.append(f'        .description = "{description}",')
    out.append("        .fields = .{")
    for field, _, _, text in fields:
        out.append(f'            .{field} = .{{ .description = "{text}" }},')
    out.append("        },")
    out.append("    };")
    out.append("};")
    out.append("")
    return out


def pick(pool, start, count):
    return [pool[(start + i) % len(pool)] for i in range(count)]


def resource_types(c, k, rid):
    """The DTOs of resource k of controller c, rid its number in the app."""
    tag = f"{c}_{k}"
    out = []
    out += dto(
        f"ListQuery{tag}",
        [
            ("page", "u32 = 1", "v.range(1, 10000)", "The page, from 1."),
            ("per_page", "u32 = 20", '.{ v.rename("perPage"), v.range(1, 100) }', "Items per page."),
            ("q", "?[]const u8 = null", ".{ v.trim, v.maxLength(100) }", "Words to search for."),
            ("sort", "SortOrder = .asc", None, "The order of the items."),
            ("status", "?Status = null", None, "Only items of this status."),
            ("tags", "[]const []const u8 = &.{}", "v.maxItems(5)", "Only items with these labels."),
        ],
        f"The query of the list of resource {tag}.",
    )
    create = [
        ("name", "[]const u8", ".{ v.trim, v.notBlank, v.maxLength(100) }", "The name of the item."),
        ("email", "[]const u8", ".{ v.trim, v.toLower, v.email }", "The email of the owner."),
    ] + pick(CREATE_POOL, rid * 5, 6)
    out += dto(f"Create{tag}", create, f"A new item of resource {tag}.")
    out += dto(
        f"Update{tag}",
        [
            ("name", "?[]const u8 = null", ".{ v.trim, v.notBlank, v.maxLength(100) }", "A new name."),
            ("email", "?[]const u8 = null", ".{ v.trim, v.toLower, v.email }", "A new email of the owner."),
            ("priority", "?Priority = null", None, "A new priority."),
            ("tags", "[]const []const u8 = &.{}", "v.maxItems(10)", "The labels, all of them."),
            ("version", "u32", "v.positive", "The version this change is based on."),
        ],
        f"A change of an item of resource {tag}.",
    )
    item_extra = pick(ITEM_POOL, rid * 4, 4)
    item = [
        ("id", "u64", None, "The id of the item."),
        ("name", "[]const u8", "v.maxLength(100)", "The name of the item."),
        ("status", "Status", None, "Where the item is in its life."),
        ("created_at", "[]const u8", '.{ v.rename("createdAt"), v.rfc3339 }', "When it was created."),
    ] + [(f, d, e, t) for f, d, e, t, _ in item_extra]
    out += dto(f"Item{tag}", item, f"An item of resource {tag}, as the API shows it.")
    out += dto(
        f"Summary{tag}",
        [
            ("id", "u64", None, "The id of the item."),
            ("name", "[]const u8", None, "The name of the item."),
            ("status", "Status", None, "Where the item is in its life."),
            ("created_at", "[]const u8", 'v.rename("createdAt")', "When it was created."),
        ],
        f"An item of resource {tag} in a list.",
    )
    out.append(f"fn sampleItem{tag}(name: []const u8) Item{tag} {{")
    out.append("    return .{")
    out.append("        .id = 1,")
    out.append("        .name = name,")
    out.append("        .status = .active,")
    out.append('        .created_at = "2026-10-21T12:00:00Z",')
    for field, _, _, _, sample in item_extra:
        out.append(f"        .{field} = {sample},")
    out.append("    };")
    out.append("}")
    out.append("")
    return out


def route_name(kind, k):
    return f"{kind.capitalize()}{k}"


def route_decl(c, k, kind):
    """The named route of kind `kind` of resource k of controller c."""
    tag = f"{c}_{k}"
    name = route_name(kind, k)
    if kind == "list":
        return f'    const {name} = http.get("/res{k}", .{{ .query = ListQuery{tag} }});'
    if kind == "create":
        return f'    const {name} = http.post("/res{k}", .{{ .body = Create{tag}, .responses = .{{ .created = .{{}} }} }});'
    if kind == "get":
        return f'    const {name} = http.get("/res{k}/{{id}}", .{{ .path = IdPath{c} }});'
    if kind == "update":
        return f'    const {name} = http.put("/res{k}/{{id}}", .{{ .path = IdPath{c}, .body = Update{tag}, .middleware = .{{requireOwner}} }});'
    return f'    const {name} = http.delete("/res{k}/{{id}}", .{{ .path = IdPath{c}, .middleware = .{{requireOwner}} }});'


def handler(c, k, kind, extra):
    tag = f"{c}_{k}"
    me = f"_: *Controller{c}, ctx: *http.Context"
    route = route_name(kind, k)
    if kind == "list":
        return [
            f"    pub fn list{k}({me}) !http.Json(Page(Summary{tag})) {{",
            f"        const in = try ctx.input({route});",
            f'        if (ctx.request.header("x-fail") != null) return error.{extra};',
            "        return .{ .value = .{ .items = &.{}, .total = 0, .page = in.query.page, .per_page = in.query.per_page } };",
            "    }",
        ]
    if kind == "create":
        return [
            f"    pub fn create{k}({me}) !http.Json(Item{tag}) {{",
            f"        const in = try ctx.input({route});",
            '        if (ctx.request.header("x-fail")) |reason| {',
            "            if (reason.len == 1) return error.AlreadyExists;",
            f"            return error.{extra};",
            "        }",
            f"        return .{{ .value = sampleItem{tag}(in.body.name), .status = 201 }};",
            "    }",
        ]
    if kind == "get":
        return [
            f"    pub fn get{k}({me}) !http.Json(Item{tag}) {{",
            f"        const in = try ctx.input({route});",
            "        if (in.path.id == 404) return error.NotFound;",
            f'        if (ctx.request.header("x-fail") != null) return error.{extra};',
            f'        return .{{ .value = sampleItem{tag}("item") }};',
            "    }",
        ]
    if kind == "update":
        return [
            f"    pub fn update{k}({me}) !http.Json(Item{tag}) {{",
            f"        const in = try ctx.input({route});",
            "        if (in.path.id == 404) return error.NotFound;",
            "        if (in.body.version == 1) return error.StaleVersion;",
            f'        if (ctx.request.header("x-fail") != null) return error.{extra};',
            f'        return .{{ .value = sampleItem{tag}(in.body.name orelse "item") }};',
            "    }",
        ]
    return [
        f"    pub fn delete{k}({me}) !void {{",
        f"        const in = try ctx.input({route});",
        "        if (in.path.id == 404) return error.NotFound;",
        '        if (ctx.request.header("x-fail") != null) return error.Locked;',
        f'        if (ctx.request.header("x-gone") != null) return error.{extra};',
        "    }",
    ]


def route_doc(c, k, kind):
    tag = f"{c}_{k}"
    method = f"{kind}{k}"
    if kind == "list":
        return f'            .{method} = .{{ .summary = "List the items of resource {tag}" }},'
    if kind == "create":
        return f'            .{method} = .{{ .summary = "Create an item of resource {tag}", .responses = .{{ .created = .{{ .description = "The item made." }} }} }},'
    if kind == "get":
        return f'            .{method} = .{{ .summary = "Get an item of resource {tag}" }},'
    if kind == "update":
        return f'            .{method} = .{{ .summary = "Change an item of resource {tag}" }},'
    return f'            .{method} = .{{ .summary = "Delete an item of resource {tag}" }},'


def controller(c, routes, first_route):
    """Controller c with `routes` routes; first_route is the number of its
    first route in the app, which picks the extra error of each."""
    resources = (routes + len(KINDS) - 1) // len(KINDS)
    out = [f"pub const IdPath{c} = struct {{", "    id: u64,", ""]
    out.append("    pub const field_rules = .{ .id = v.positive };")
    out.append("    pub const openapi: oa.Doc(@This()) = .{")
    out.append('        .fields = .{ .id = .{ .description = "The id of the item.", .example = 1 } },')
    out.append("    };")
    out.append("};")
    out.append("")
    for k in range(resources):
        out += resource_types(c, k, c * RESOURCES_PER_CONTROLLER + k)
    kinds = [(r // len(KINDS), KINDS[r % len(KINDS)]) for r in range(routes)]
    out.append(f"pub const Controller{c} = struct {{")
    out.append("    calls: u32 = 0,")
    out.append("")
    for k, kind in kinds:
        out.append(route_decl(c, k, kind))
    out.append("")
    out.append("    pub const http_routes = http.routes(.{")
    out.append(f'        .prefix = "/v1/c{c}",')
    out.append(f'        .middleware = .{{permission("c{c}")}},')
    out.append("        .methods = .{")
    for k, kind in kinds:
        out.append(f"            .{kind}{k} = {route_name(kind, k)},")
    out.append("        },")
    out.append("    });")
    out.append("")
    out.append("    pub const openapi: oa.ControllerDoc(@This()) = .{")
    out.append(f'        .tag = "C{c}",')
    out.append(f'        .description = "The resources of part {c}.",')
    out.append("        .routes = .{")
    for k, kind in kinds:
        out.append(route_doc(c, k, kind))
    out.append("        },")
    out.append("    };")
    for r, (k, kind) in enumerate(kinds):
        extra = APP_ERRORS[((first_route + r) * 7) % len(APP_ERRORS)][0]
        out.append("")
        out += handler(c, k, kind, extra)
    out.append("};")
    out.append("")
    return out


def app(routes):
    controllers = (routes + ROUTES_PER_CONTROLLER - 1) // ROUTES_PER_CONTROLLER
    out = [
        "//! Generated by tests/openapi-probe/gen_app.py: the synthetic application of",
        f"//! the openapi probe, {routes} routes in {controllers} controllers.",
        "const std = @import(\"std\");",
        "const http = @import(\"http\");",
        "const v = @import(\"validator\");",
        "const oa = @import(\"openapi\");",
        "",
    ]
    out += dto(
        "ApiError",
        [
            ("code", "[]const u8", None, "A stable code, such as not_found."),
            ("message", "[]const u8", None, "What happened, for people."),
            ("trace_id", "?[]const u8 = null", 'v.rename("traceId")', "The trace of the request."),
        ],
        "The body of every error.",
    )
    out.append("pub const AppErrors = struct {")
    out.append("    pub fn mapError(err: anyerror) http.ErrorResponse(ApiError) {")
    out.append("        return switch (err) {")
    for name, status, code, message in APP_ERRORS:
        out.append(f'            error.{name} => .{{ .status = {status}, .body = .{{ .code = "{code}", .message = "{message}" }} }},')
    out.append("            else => .fallback(err, .{ .code = http.defaultCode(err), .message = http.defaultTitle(err) }),")
    out.append("        };")
    out.append("    }")
    out.append("};")
    out.append("")
    out.append("pub const Priority = enum { low, normal, high, urgent };")
    out.append("pub const Status = enum { draft, active, archived };")
    out.append("pub const SortOrder = enum { asc, desc };")
    out.append("")
    out += dto(
        "Address",
        [
            ("street", "[]const u8", "v.maxLength(200)", "The street and the number."),
            ("city", "[]const u8", "v.maxLength(100)", "The city."),
            ("postal_code", "[]const u8", '.{ v.rename("postalCode"), v.length(3, 10) }', "The postal code."),
            ("country", "[]const u8", "v.length(2, 2)", "The country, ISO 3166-1 alpha-2."),
        ],
        "A postal address.",
    )
    out.append('const sample_address: Address = .{ .street = "Main St 1", .city = "Berlin", .postal_code = "10115", .country = "DE" };')
    out.append("")
    out.append("pub fn Page(comptime T: type) type {")
    out.append("    return struct {")
    out.append("        items: []const T,")
    out.append("        total: u64,")
    out.append("        page: u32,")
    out.append("        per_page: u32,")
    out.append("")
    out.append('        pub const field_rules = .{ .per_page = v.rename("perPage") };')
    out.append("        pub const openapi: oa.Doc(@This()) = .{")
    out.append('            .description = "A page of results.",')
    out.append("            .fields = .{")
    out.append('                .items = .{ .description = "The results on this page." },')
    out.append('                .total = .{ .description = "The results on all pages." },')
    out.append('                .page = .{ .description = "The number of this page, from 1." },')
    out.append('                .per_page = .{ .description = "Results per page." },')
    out.append("            },")
    out.append("        };")
    out.append("    };")
    out.append("}")
    out.append("")
    out += [
        "/// Knows the client by a bearer token or the cookie of a session, and",
        "/// requires one of them.",
        "const requireAuth = struct {",
        "    pub const openapi: oa.MiddlewareDoc = .{",
        "        .security_schemes = &.{",
        '            .{ .name = "bearer", .kind = .{ .http = .{ .scheme = "bearer" } } },',
        '            .{ .name = "session", .kind = .{ .api_key = .{ .in = .cookie, .param = "session" } } },',
        "        },",
        "        .security = .any,",
        "    };",
        "",
        "    pub fn run(ctx: *http.Context) !http.MiddlewareResult {",
        '        if (ctx.request.header("authorization") == null) return error.Unauthenticated;',
        "        return .next;",
        "    }",
        "};",
        "",
        "fn rateLimit(ctx: *http.Context) !http.MiddlewareResult {",
        '    if (ctx.request.header("x-rate") != null) return error.RateLimited;',
        '    if (ctx.request.header("x-banned") != null) return error.Banned;',
        "    return .next;",
        "}",
        "",
        "fn requireOwner(ctx: *http.Context) !http.MiddlewareResult {",
        '    if (ctx.request.header("x-owner") == null) return error.NotOwner;',
        "    return .next;",
        "}",
        "",
        "fn permission(comptime area: []const u8) type {",
        "    return struct {",
        '        pub const name = "permission(" ++ area ++ ")";',
        "        pub const openapi: oa.MiddlewareDoc = .{ .roles = &.{area} };",
        "",
        "        pub fn run(ctx: *http.Context) !http.MiddlewareResult {",
        '            if (ctx.request.header("x-denied") != null) return error.PermissionDenied;',
        '            if (ctx.request.header("x-suspended") != null) return error.AccountSuspended;',
        "            return .next;",
        "        }",
        "    };",
        "}",
        "",
    ]
    for c in range(controllers):
        first = c * ROUTES_PER_CONTROLLER
        out += controller(c, min(ROUTES_PER_CONTROLLER, routes - first), first)
    out.append("pub const Service = struct {")
    for c in range(controllers):
        out.append(f"    c{c}: Controller{c} = .{{}},")
    out.append("    app_errors: AppErrors = .{},")
    out.append("    server: http.Server = undefined,")
    out.append("")
    out.append("    /// Builds the server, and the document of `Variant` from the type of the")
    out.append("    /// same options, as design 1.2 has Service.start do.")
    out.append("    pub fn start(s: *Service, gpa: std.mem.Allocator, backend: http.Backend, comptime Variant: type) !Variant.Result {")
    out.append("        const options = .{")
    out.append("            .backend = backend,")
    out.append('            .prefix = "/api",')
    refs = ", ".join(f"&s.c{c}" for c in range(controllers))
    out.append(f"            .controllers = .{{{refs}}}," if controllers == 1 else f"            .controllers = .{{ {refs} }},")
    out.append("            .middleware = .{ requireAuth, rateLimit },")
    out.append("            .error_handler = &s.app_errors,")
    out.append("        };")
    out.append("        const document = Variant.document(@TypeOf(options));")
    out.append("        s.server = try .init(gpa, options);")
    out.append("        return document;")
    out.append("    }")
    out.append("};")
    return "\n".join(out) + "\n"


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: gen_app.py <routes> <app.zig>\n")
        sys.exit(2)
    routes = int(sys.argv[1])
    if routes < 2:
        sys.stderr.write("gen_app.py: at least 2 routes (a list and a create)\n")
        sys.exit(2)
    with open(sys.argv[2], "w", encoding="utf-8") as f:
        f.write(app(routes))


if __name__ == "__main__":
    main()
