//! zefir-http for tests: `http.testing.Backend`, the
//! server's backend in memory, which serves the same server and the same
//! controllers without sockets.
const std = @import("std");
const backend = @import("testing/Backend.zig");
const Server = @import("Server.zig");
const plan = @import("plan.zig");

pub const Backend = backend;
pub const Request = backend.Request;
pub const Response = backend.Response;
pub const RequestError = backend.RequestError;
pub const Stream = backend.Stream;
pub const OpenError = backend.OpenError;

/// The requests of `server` at work now, those `.max_in_flight` counts: 0
/// once every request has ended, whatever its outcome.
pub fn inFlight(server: *const Server) u32 {
    return server.internal.in_flight.load(.acquire);
}

/// The SSE streams of `server` open now, those `.max_streams` counts: 0
/// once every stream has ended, however it ended.
pub fn openStreams(server: *const Server) u32 {
    return server.internal.streams.load(.acquire);
}

/// The chain of the route `method` `pattern` of a server built from
/// parts of type `Parts`, as the names of its elements in the order every
/// phase runs them: the server's middleware, then the controller's, then
/// the method's, sets unfolded. `pattern` is the route's without the
/// server's prefix: "/v1/todos/{id}". At compile time, for tests:
///
/// ```zig
/// const names = comptime http.testing.chainNames(@TypeOf(parts), .DELETE, "/v1/todos/{id}");
/// ```
pub fn chainNames(comptime Parts: type, comptime method: std.http.Method, comptime pattern: []const u8) []const []const u8 {
    comptime {
        const p = plan.of(Parts);
        for (p.routes) |r| {
            if (r.method != method or !std.mem.eql(u8, r.pattern, pattern)) continue;
            var names: [p.global.len + r.chain.len][]const u8 = undefined;
            for (p.global ++ r.chain, &names) |e, *name| name.* = e.name;
            const final = names;
            return &final;
        }
        @compileError("zefir.http: http.testing.chainNames: no route " ++ @tagName(method) ++ " " ++ pattern);
    }
}

test {
    _ = backend;
}
