//! `rpc.Context`: the context of one call on the server.

const std = @import("std");
const core = @import("core");
const model = @import("../model.zig");
const transport = @import("../transport.zig");
const rules = @import("../rules.zig");
const ServerTransport = @import("../ServerTransport.zig");

/// The context of one call on the server. The engine creates it for each
/// call; handlers and middleware get a borrowed pointer and must not keep it
/// after they return or hand it to background tasks.
pub const Context = opaque {};

/// What `rpc.Context` reads and writes: one per call, inside the engine's
/// call. Internal to the module.
pub const CallContext = struct {
    io: std.Io,
    /// The deadline of the call, its own token and the server's span.
    operation: core.Context,
    /// The arena of the call.
    arena: std.mem.Allocator,
    route: model.Route,
    request_id: [16]u8,
    /// The request's metadata without the reserved keys.
    metadata: []const model.Metadata.Entry,
    peer: transport.Peer,
    server_transport: ServerTransport,
    map_error: ?*const fn (err: anyerror) ?model.Failure,
    /// The limits of the response's metadata: those of a request.
    metadata_limits: rules.MetadataLimits,
    /// The reserved values of the request, for the engine.
    authorization: ?[]const u8 = null,
    correlation_id: ?[]const u8 = null,
    /// The metadata of the response, in the arena.
    response_metadata: std.ArrayList(model.Metadata.Entry) = .empty,
    /// The failure set with `fail`.
    recorded: ?model.Failure = null,
    /// The body of the recorded failure (the violations of `rpc.Server`).
    failure_body: []const u8 = "",
};
