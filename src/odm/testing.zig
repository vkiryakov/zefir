//! `odm.testing`: what the tests of odm, and of the code over it, need.

/// A driver without a network: plans and replies by connection string,
/// gates that hold calls, a journal of the calls and counts of the
/// clients.
pub const FakeDriver = @import("testing/FakeDriver.zig");
