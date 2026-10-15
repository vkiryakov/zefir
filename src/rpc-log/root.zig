//! zefir-rpc-log — access logs of zefir-rpc on zefir-log: middleware that
//! writes one record per call, `AccessLog` on the server and
//! `ClientAccessLog` on the client. A module of its own, so that zefir-rpc
//! does not depend on zefir-log.
//!
//! ```zig
//! var access_log: rpc_log.AccessLog = .init(logger.scoped("rpc"), .{});
//! var server = try rpc.Server.init(gpa, .{ …, .middleware = .{ &access_log, &limiter } });
//!
//! var client_log: rpc_log.ClientAccessLog = .init(logger.scoped("rpc.client"), .{});
//! var client = try rpc.Client.init(gpa, .{ …, .middleware = .{&client_log} });
//! ```
//!
//! A record of the server, one JSON line (wrapped here):
//!
//! ```json
//! {"timestamp":"2026-10-15T09:41:07.415Z","level":"info","message":"RPC call served","scope":"rpc",
//!  "trace_id":"0af7651916cd43dd8448eb211c80319c","span_id":"53995c3f42cd8ad8",
//!  "rpc":{"service":"users","version":1,"method":"getUser","request_id":"6f1e0c9a3b7d4e2f8a5c1d0b9e8f7a6c",
//!  "code":"not_found","app_code":"users.not_found","duration_ms":0.42,"transport":"nats"}}
//! ```
//!
//! Under `rpc` every record holds the route (`service`, `version`,
//! `method`), the request id in hex, `code` ("ok" or the code of the
//! failure) with `app_code` for a failure, how long the call took in
//! milliseconds, and the name of the transport. The server's record adds
//! the `peer` when the transport knows one and, when its options ask, the
//! caller's `subject` and the listed `metadata`; the client's record adds
//! `error`, the name of the error that ended a call without a response.
//! The trace and span ids come from the call's `core.Context`.
//!
//! A record never holds a body, credentials (`authorization` never
//! reaches middleware as metadata), metadata outside the listed keys, or
//! the identity beyond its subject. A success and the failures of the
//! application are logged at `info`; `internal`, `unavailable` and
//! `resource_exhausted`, the failures of the service itself and of its
//! limits, at `warn`; `Levels` changes any of them.

const std = @import("std");

/// The access log of a server: one record per call that reaches the chain
/// of middleware.
pub const AccessLog = @import("AccessLog.zig");
/// The access log of a client: one record per call the client sends.
pub const ClientAccessLog = @import("ClientAccessLog.zig");
/// The level of a record by the outcome of its call.
pub const Levels = @import("Levels.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("Levels.zig");
    _ = @import("record.zig");
    _ = @import("AccessLog.zig");
    _ = @import("ClientAccessLog.zig");
    _ = @import("access_log_tests.zig");
}
