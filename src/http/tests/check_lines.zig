//! The lines of the Debug check (src/http/check.zig) that the guides of
//! zefir-http and zefir-openapi show, each with the request that makes it.
//! A test of check.zig sends each request to a server of the guides'
//! TodosV1Controller, whose routes make the mistakes the guides tell of,
//! and expects the check to log the line as it is here; the readme tests of
//! both guides expect every line of the check they show to be one of these.
//! A line that the check writes otherwise fails that test, and a guide that
//! shows a line otherwise fails its readme test. build.zig gives this file
//! to the readme tests as `http-check-lines`.

const std = @import("std");

/// A request to the server of the test, and the line of the check for it.
pub const Line = struct { method: std.http.Method, target: []const u8, text: []const u8 };

pub const lines = [_]Line{
    // `list` reads its query as ListQuery, while its route declares
    // ListTodosQuery.
    .{
        .method = .GET,
        .target = "/api/v1/todos",
        .text = "zefir.http: GET /api/v1/todos (TodosV1Controller.list) reads the query as ListQuery, but declares .query = ListTodosQuery",
    },
    // `create` answers 202, which its .responses do not list.
    .{
        .method = .POST,
        .target = "/api/v1/todos",
        .text = "zefir.http: POST /api/v1/todos (TodosV1Controller.create) answered 202, which it does not declare in .responses",
    },
    // A middleware that limits the streams of a user answers 429 itself on
    // the stream of events, without the 429 in an openapi of its own.
    .{
        .method = .GET,
        .target = "/api/v1/todos/events",
        .text = "zefir.http: GET /api/v1/todos/events (TodosV1Controller.events) answered 429, which it does not declare: an SSE route answers with its stream, 204 and what mapError gives its errors; declare it in the .responses of the openapi of the middleware that answers, or keep the handler and the error handler to those",
    },
};
