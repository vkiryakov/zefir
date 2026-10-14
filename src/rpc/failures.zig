//! The failures of the engine itself, with static strings, and how an error
//! of a handler becomes a failure. Internal to the module.

const model = @import("model.zig");
const Failure = model.Failure;

/// No method serves the route.
pub const unknown_method: Failure = .{ .code = .unimplemented, .app_code = "rpc.unknown_method", .message = "Unknown method" };
/// The body is not in a codec the server speaks ("json" in v1).
pub const unsupported_codec: Failure = .{ .code = .unimplemented, .app_code = "rpc.unsupported_codec", .message = "Unsupported codec" };
/// A metadata key or value against the rules, a repeated reserved key, a
/// `zefir-*` key the engine does not know.
pub const invalid_metadata: Failure = .{ .code = .invalid_argument, .app_code = "rpc.invalid_metadata", .message = "Invalid metadata" };
/// More metadata than `max_metadata_entries` or `max_metadata_bytes`.
pub const metadata_too_large: Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Metadata too large" };
/// A negative budget from the transport.
pub const invalid_timeout: Failure = .{ .code = .invalid_argument, .app_code = "rpc.invalid_argument", .message = "Invalid timeout" };
/// No budget left, or the deadline passed.
pub const deadline_exceeded: Failure = .{ .code = .deadline_exceeded, .app_code = "rpc.deadline_exceeded", .message = "Deadline exceeded" };
/// No place for one more call.
pub const overloaded: Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Server overloaded" };
/// A body over `max_request_bytes`.
pub const request_too_large: Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Request too large" };
/// Over the memory of one call or of all calls.
pub const out_of_memory: Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Out of memory" };
/// No task for the call.
pub const no_task: Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "No task for the call" };
/// The server stops and the call did not start.
pub const stopping: Failure = .{ .code = .unavailable, .app_code = "rpc.unavailable", .message = "Server is stopping" };
