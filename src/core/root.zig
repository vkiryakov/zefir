//! zefir-core — the execution context shared by Zefir modules: deadlines,
//! cancellation, W3C trace context and transport-neutral error codes.
//!
//! ```zig
//! var token: core.CancellationToken = .init;
//! const ctx = core.Context.root
//!     .withDeadline(.after(std.Io.Clock.awake.now(io), .fromSeconds(2)))
//!     .withCancellation(&token);
//!
//! fn getUser(ctx: core.Context, io: std.Io, id: u64) !User {
//!     try ctx.check(std.Io.Clock.awake.now(io));
//!     ...
//! }
//! ```
//!
//! Nothing here allocates, reads a clock or does I/O: the caller passes the
//! current time in. A `Context` owns nothing. It borrows the
//! `CancellationToken` and the tracestate bytes of its trace, so it must not
//! outlive the scope that owns them: the request, the call, the message or
//! the job. Pass contexts down by value, and the allocator and `std.Io` as
//! separate parameters.

const std = @import("std");
const errors = @import("errors.zig");
const trace = @import("trace.zig");

pub const Context = @import("Context.zig");
pub const CancellationToken = @import("CancellationToken.zig");
pub const TraceId = trace.TraceId;
pub const SpanId = trace.SpanId;
pub const TraceFlags = trace.TraceFlags;
pub const TraceState = trace.TraceState;
pub const TraceContext = trace.TraceContext;
pub const Deadline = @import("Deadline.zig");
pub const ErrorCode = errors.ErrorCode;
pub const ErrorInfo = errors.ErrorInfo;
pub const ContextError = errors.ContextError;
pub const w3c = @import("w3c.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("Context.zig");
    _ = @import("CancellationToken.zig");
    _ = @import("Deadline.zig");
    _ = @import("errors.zig");
    _ = @import("trace.zig");
    _ = @import("w3c.zig");
}

/// The first public function, reached from `T`'s public declarations, that
/// takes a `std.mem.Allocator`; null when there is none.
fn findAllocatorParam(comptime T: type) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    const decl_names = switch (@typeInfo(T)) {
        inline .@"struct", .@"enum", .@"union", .@"opaque" => |info| info.decl_names,
        else => return null,
    };
    inline for (decl_names) |name| {
        const decl = @field(T, name);
        const Decl = @TypeOf(decl);
        if (Decl == type) {
            if (findAllocatorParam(decl)) |found| return found;
        } else if (@typeInfo(Decl) == .@"fn") {
            inline for (@typeInfo(Decl).@"fn".param_types) |Param| {
                if (Param == std.mem.Allocator) return @typeName(T) ++ "." ++ name;
            }
        }
    }
    return null;
}

test "no public function takes an allocator" {
    try std.testing.expectEqual(@as(?[]const u8, null), comptime findAllocatorParam(@This()));

    const Planted = struct {
        pub const Inner = struct {
            pub fn grow(gpa: std.mem.Allocator) void {
                _ = gpa;
            }
        };
    };
    try std.testing.expect(comptime findAllocatorParam(Planted) != null);
}

test "core sources do not use the heap" {
    const sources = [_][]const u8{
        @embedFile("CancellationToken.zig"),
        @embedFile("Context.zig"),
        @embedFile("Deadline.zig"),
        @embedFile("errors.zig"),
        @embedFile("trace.zig"),
        @embedFile("w3c.zig"),
    };
    // Split so that this file does not match itself.
    const forbidden = [_][]const u8{ "std." ++ "heap", "mem." ++ "Allocator", "allocator" ++ "()" };
    for (sources) |source| {
        for (forbidden) |needle| try std.testing.expect(std.mem.find(u8, source, needle) == null);
    }
}
