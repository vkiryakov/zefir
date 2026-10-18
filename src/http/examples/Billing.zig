//! The billing of the example app, a stand-in for a client of another
//! service: a real one asks it over the network, and its answer takes a
//! while. Here every user is on the free plan.

const std = @import("std");
const core = @import("core");

const Billing = @This();

/// The plan of every user here.
free: Plan = .{ .name = "free", .max_todos = 3 },

/// What a user's plan allows.
pub const Plan = struct { name: []const u8, max_todos: u32 };

pub const Error = std.Io.Cancelable || core.ContextError;

/// The plan of `user`, after a wait like that of a call over the network.
pub fn planOf(billing: *Billing, ctx: core.Context, io: std.Io, user: []const u8) Error!Plan {
    _ = user;
    try ctx.check(std.Io.Clock.awake.now(io));
    try io.sleep(.fromMilliseconds(5), .awake);
    return billing.free;
}
