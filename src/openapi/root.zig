//! zefir-openapi: the OpenAPI document of a zefir-http server, which the
//! compiler builds from the same types the server works with: the routes of
//! its controllers and what they declare, the DTOs and their `field_rules`,
//! the errors of every route as the error handler's `mapError` answers
//! them, and the middleware of each chain. It reads the server through
//! `http.describe` and the rules through `v.schemaOf`.
//!
//! What the compiler cannot see, the texts of the document, the types
//! declare next to their code, each in a typed `pub const openapi`: a
//! mistake in it is an ordinary error of Zig at the line of the
//! application.
//!
//! ```zig
//! pub const CreateTodoRequest = struct {
//!     title: []const u8,
//!     due_date: ?[]const u8 = null,
//!
//!     pub const openapi: zefir.openapi.Doc(@This()) = .{
//!         .description = "A new todo of the signed-in user.",
//!         .example = .{ .title = "Buy milk", .due_date = "2026-10-30" },
//!         .fields = .{ .title = .{ .description = "What to do." } },
//!     };
//! };
//!
//! // A controller: its tag, and an entry for each method of its routes.
//! pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{
//!     .tag = "Todos",
//!     .routes = .{ .get = .{ .summary = "Get a todo" } },
//! };
//!
//! // A middleware: how a client signs in, and what it reads and answers.
//! pub const openapi: zefir.openapi.MiddlewareDoc = .{
//!     .security_schemes = &.{.{ .name = "bearer", .kind = .{ .http = .{ .scheme = "bearer" } } }},
//! };
//! ```
//!
//! Constraints (`maxLength`, `minimum`, `required`, ...) are never written
//! here: the document takes them from the types and their `field_rules`.
const declarations = @import("openapi.zig");
const document_file = @import("document.zig");

/// The document of a server, built at compile time:
/// `zefir.openapi.document(@TypeOf(options), .{ .info = ... })`.
pub const document = document_file.document;
pub const Document = document_file.Document;
/// `expectFile`: the document of an application's test against its file.
pub const testing = @import("testing.zig");

pub const Doc = declarations.Doc;
pub const FieldDoc = declarations.FieldDoc;
pub const Example = declarations.Example;
pub const ControllerDoc = declarations.ControllerDoc;
pub const RouteDoc = declarations.RouteDoc;
pub const ResponseDoc = declarations.ResponseDoc;
pub const MiddlewareDoc = declarations.MiddlewareDoc;
pub const DocumentOptions = declarations.DocumentOptions;

test {
    @import("std").testing.refAllDecls(@This());
    _ = declarations;
    _ = @import("json.zig");
    _ = @import("example.zig");
    _ = @import("schema.zig");
    _ = document_file;
}
