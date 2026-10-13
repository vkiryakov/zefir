//! Transport-neutral error classification.
//!
//! Zig error sets stay the way code reports errors. `ErrorCode` only names
//! the class of a failure, so a transport (RPC, HTTP, a job queue) can map
//! it to its own status. The codes are the canonical set shared by gRPC
//! (`google.rpc.Code`), Connect and Twirp, without their numeric values.

const std = @import("std");

/// Returned by `Context.check`.
///
/// `error.Cancelled` is not `std.Io`'s `error.Canceled`: `Cancelled` repeats
/// on every check while the token stays cancelled, `Canceled` is returned
/// once by a cancelation point and follows `std.Io.recancel` rules. An
/// adapter that gets `error.Canceled` from `std.Io` decides which one to
/// return by calling `Context.check` with a fresh time.
pub const ContextError = error{ Cancelled, DeadlineExceeded };

/// The class of a failure, for a transport to map to its own status.
pub const ErrorCode = enum {
    /// The caller cancelled the operation.
    cancelled,
    /// An error with no better code, for example from an unknown error space.
    unknown,
    /// The request is invalid regardless of the system state.
    invalid_argument,
    /// The deadline expired before the operation finished.
    deadline_exceeded,
    /// A requested entity does not exist.
    not_found,
    /// The entity the caller tried to create already exists.
    already_exists,
    /// The caller is known but not allowed to do this.
    permission_denied,
    /// A quota or a limit ran out: memory, rate, queue, size.
    resource_exhausted,
    /// The system is not in the state the operation needs.
    failed_precondition,
    /// The operation was aborted, typically by a concurrency conflict.
    aborted,
    /// A value is outside the valid range, for example past the end.
    out_of_range,
    /// The operation is not implemented or not supported.
    unimplemented,
    /// An invariant of the system is broken.
    internal,
    /// The service is unavailable right now; retrying may help.
    unavailable,
    /// Unrecoverable data loss or corruption.
    data_loss,
    /// The request has no valid credentials.
    unauthenticated,

    /// The code for an error returned by `Context.check`.
    pub fn fromContextError(err: ContextError) ErrorCode {
        return switch (err) {
            error.Cancelled => .cancelled,
            error.DeadlineExceeded => .deadline_exceeded,
        };
    }
};

/// A failure ready to report: its class and a message for people.
pub const ErrorInfo = struct {
    code: ErrorCode,
    /// Borrowed: points to memory the caller keeps alive, often a literal.
    /// Never filled in automatically, so nothing leaks unless you put it here.
    message: []const u8,
};

test "context errors map to their codes" {
    try std.testing.expectEqual(ErrorCode.cancelled, ErrorCode.fromContextError(error.Cancelled));
    try std.testing.expectEqual(ErrorCode.deadline_exceeded, ErrorCode.fromContextError(error.DeadlineExceeded));
}

test "the code names are the canonical set" {
    const expected = [_][]const u8{
        "cancelled",           "unknown",        "invalid_argument",  "deadline_exceeded",
        "not_found",           "already_exists", "permission_denied", "resource_exhausted",
        "failed_precondition", "aborted",        "out_of_range",      "unimplemented",
        "internal",            "unavailable",    "data_loss",         "unauthenticated",
    };
    const names = @typeInfo(ErrorCode).@"enum".field_names;
    try std.testing.expectEqual(expected.len, names.len);
    for (expected, names) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "a context error propagates through a wider error set" {
    const Handler = struct {
        fn run(fail: ContextError) (ContextError || error{NotFound})!void {
            return fail;
        }
    };
    try std.testing.expectError(error.DeadlineExceeded, Handler.run(error.DeadlineExceeded));
}

test "ErrorInfo borrows its message" {
    var buffer = "user 42 not found".*;
    const info: ErrorInfo = .{ .code = .not_found, .message = &buffer };
    buffer[5] = '7';
    try std.testing.expectEqualStrings("user 72 not found", info.message);
}
