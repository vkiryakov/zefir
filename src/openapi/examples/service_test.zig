//! The test of the service: its document against the file openapi.json of
//! the repository. `zig build test` fails when the API changed and the file
//! did not; `zig build openapi` runs it to write the file.

const std = @import("std");
const testing = std.testing;
const zefir = @import("zefir");
const http = zefir.http;
const Service = @import("Service.zig");
const TodoRepository = @import("TodoRepository.zig");
/// The path of openapi.json, next to build.zig, as the build gives it.
const openapi_json = @import("paths").openapi_json;

const repo: TodoRepository = .{ .todos = &.{.{ .id = 1, .title = "Buy milk", .done = false }} };

test "openapi.json matches the code" {
    var backend: http.testing.Backend = .init(testing.allocator);
    defer backend.deinit();
    var service: Service = .{ .todos = .{ .repo = &repo } };
    try service.start(testing.allocator, testing.io, backend.backend());
    defer service.deinit(testing.allocator, testing.io);
    // Compares the document with the file; with ZEFIR_OPENAPI_UPDATE=1 it
    // writes the file instead.
    try zefir.openapi.testing.expectFile(testing.io, service.docs.document, openapi_json);
}
