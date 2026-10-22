//! Builds the server for main and for the tests. The document is built
//! here too, from the type of the same options, so it cannot differ from
//! the server.

const std = @import("std");
const zefir = @import("zefir");
const http = zefir.http;
const AppErrors = @import("errors.zig").AppErrors;
const TodosController = @import("TodosController.zig");

const Service = @This();

todos: TodosController,
docs: zefir.openapi.Docs(.{}) = undefined, // GET /api/openapi.json and the page GET /api/docs
app_errors: AppErrors = .{},
server: http.Server = undefined,

pub fn start(s: *Service, gpa: std.mem.Allocator, io: std.Io, backend: http.Backend) !void {
    const options = .{
        .backend = backend,
        .prefix = "/api",
        .controllers = .{ &s.todos, &s.docs },
        .error_handler = &s.app_errors,
    };
    // The compiler builds the document from the type of options: the
    // controllers, their routes, the DTOs, the errors of the handlers and
    // mapError. `init` writes its JSON, once.
    s.docs = try .init(gpa, comptime zefir.openapi.document(@TypeOf(options), .{
        .info = .{ .title = "Todos API", .version = "1.0.0" },
    }));
    errdefer s.docs.deinit(gpa);
    s.server = try .init(gpa, options);
    errdefer s.server.deinit(io);
    try s.server.start(io);
}

pub fn deinit(s: *Service, gpa: std.mem.Allocator, io: std.Io) void {
    s.server.deinit(io);
    s.docs.deinit(gpa);
}
