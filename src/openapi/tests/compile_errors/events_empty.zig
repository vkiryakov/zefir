//! Must not compile: a stream of the document whose .events has no
//! variants, so no event to show.
const zefir = @import("zefir");
const http = zefir.http;

const NoEvents = union(enum) {};

const LiveController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/live",
        .methods = .{ .events = http.sse.get("/events", .{ .events = NoEvents }) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{ .routes = .{ .events = .{ .summary = "Live updates" } } };

    pub fn events(_: *LiveController, _: *http.sse.Context) !void {}
};

var live: LiveController = .{};

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .controllers = .{&live} }), .{ .info = .{ .title = "Live API", .version = "1.0.0" } });
}
