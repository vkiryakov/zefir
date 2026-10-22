//! The server of the todo service, built in one place for `main` and for
//! the tests: the objects of the service, the server, and its OpenAPI
//! document, which the compiler builds from the type of the same parts,
//! so that the document cannot differ from the server it describes. What
//! differs between `main` and a test comes in the fields without a
//! default: the users and their tokens, the origins of CORS, the directory
//! of the page, and the logger.

const std = @import("std");
const http = @import("http");
const log = @import("log");
const zefir = @import("zefir");
const auth = @import("auth.zig");
const Cors = @import("cors.zig").Cors;
const dto = @import("dto.zig");
const errors = @import("errors.zig");
const mw = @import("middleware.zig");
const Billing = @import("Billing.zig");
const HealthController = @import("HealthController.zig");
const SessionController = @import("SessionController.zig");
const TodoRepository = @import("TodoRepository.zig");
const TodosV1Controller = @import("TodosV1Controller.zig");

const Service = @This();

/// The users and their tokens, from the settings; borrowed.
users: []const auth.TokenAuth.User,
/// The origins whose pages may call the API; borrowed.
origins: []const []const u8,
/// The directory of the page and its files.
public_dir: []const u8,
/// The access log writes its records here.
logger: log.Logger,

// What `start` builds and the server borrows: it lives in the service, so
// the service stays where it is until `deinit`.
repo: TodoRepository = undefined,
billing: Billing = .{},
live: http.sse.Manager(dto.LiveEvent) = undefined,
token_auth: auth.TokenAuth = undefined,
cors: Cors = undefined,
access_log: mw.AccessLog = undefined,
plans: mw.PlanLookup = undefined,
app_errors: errors.AppErrors = .{},
todos_v1: TodosV1Controller = undefined,
sessions: SessionController = undefined,
health: HealthController = .{},
/// GET /api/openapi.json, the document, and GET /api/docs, a page of it.
docs: zefir.openapi.Docs(.{}) = undefined,
server: http.Server = undefined,

pub fn start(s: *Service, gpa: std.mem.Allocator, io: std.Io, backend: http.Backend) !void {
    // What the handlers use. It outlives the server: `deinit` stops the
    // server first.
    s.repo = .init(gpa);
    errdefer s.repo.deinit();
    s.live = .init(gpa, .{});
    errdefer s.live.deinit(io);
    // The objects of the middleware and the controllers, each with
    // pointers to what it uses.
    s.token_auth = .{ .users = s.users };
    s.cors = .{ .origins = s.origins };
    s.access_log = .{ .logger = s.logger.scoped("access") };
    s.plans = .{ .billing = &s.billing, .repo = &s.repo };
    s.todos_v1 = .{ .repo = &s.repo, .live = &s.live, .plans = &s.plans };
    s.sessions = .{ .token_auth = &s.token_auth, .live = &s.live };

    const parts = .{
        .controllers = .{ &s.todos_v1, &s.sessions, &s.health, &s.docs },
        // Every request runs these, in this order, before its route is chosen.
        .middleware = .{ mw.requestId, &s.access_log, http.onResponse(mw.securityHeaders), &s.cors, &s.token_auth },
        .error_handler = &s.app_errors,
    };
    // Before the routes of the controllers: /api/v1/todos, /api/health.
    const prefix = "/api";
    // The compiler builds the document from the type of the parts: each
    // route with its input, its responses and its errors, and the security
    // of its middleware. `init` writes its JSON, once.
    s.docs = try .init(gpa, comptime zefir.openapi.document(@TypeOf(parts), .{
        .info = .{
            .title = "Todos API",
            .version = "1.0.0",
            .description = "The todos of each user: made, changed, deleted, exported as CSV and followed live.",
        },
        // The server's prefix, in the servers of the document.
        .prefix = prefix,
        // The health check of the load balancer is no part of the API.
        .exclude = &.{HealthController},
    }));
    errdefer s.docs.deinit(gpa);
    s.server = try .init(gpa, parts, .{
        .listen = .{ .backend = backend },
        .prefix = prefix,
        // The page and its files; a path without a file gets index.html, so
        // that the page's own router reads the path.
        .static = &.{http.static("/", .{ .root = s.public_dir, .spa_fallback = "index.html" })},
    });
    errdefer s.server.deinit(io);
    try s.server.start(io);
}

/// Stops the server first: what it borrowed goes after it.
pub fn deinit(s: *Service, gpa: std.mem.Allocator, io: std.Io) void {
    s.server.deinit(io);
    s.docs.deinit(gpa);
    s.live.deinit(io);
    s.repo.deinit();
}
