//! The cursors that the collection API makes itself, in place of a
//! driver's or around one.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const bson = @import("../bson.zig");
const errors = @import("../errors.zig");
const requests = @import("../requests.zig");
const Cursor = @import("../contract/Cursor.zig");
const Error = errors.Error;
const OperationContext = requests.OperationContext;

/// The cursor of a namespace that is not there, such as the indexes of a
/// collection that does not exist: no documents, and nothing on the
/// server to end.
const Empty = struct {
    /// A field, so that a pointer to the cursor is an address.
    unused: u8 = 0,

    pub fn next(e: *Empty, io: Io, op: OperationContext) Error!?bson.RawDocument {
        _ = e;
        _ = io;
        _ = op;
        return null;
    }

    pub fn close(e: *Empty, io: Io) void {
        _ = e;
        _ = io;
    }

    pub fn deinit(e: *Empty, io: Io) void {
        _ = e;
        _ = io;
    }
};

/// Never written: every empty cursor is this one.
var empty_cursor: Empty = .{};

/// A cursor without documents: `next` gives null, every time.
pub fn empty() Cursor {
    return .init(&empty_cursor);
}

/// A driver's cursor with the diagnostics it writes the errors of its
/// `getMore`s to, for a caller that passed none: the driver keeps the
/// pointer, so they live as long as the cursor. `deinit` frees both.
pub const WithDiagnostics = struct {
    allocator: Allocator,
    diagnostics: errors.Diagnostics = .{},
    inner: Cursor = undefined,

    pub fn create(allocator: Allocator) Allocator.Error!*WithDiagnostics {
        const w = try allocator.create(WithDiagnostics);
        w.* = .{ .allocator = allocator };
        return w;
    }

    /// Frees a wrapper that holds no cursor yet.
    pub fn destroy(w: *WithDiagnostics) void {
        w.allocator.destroy(w);
    }

    /// The cursor of `inner` from now on.
    pub fn wrap(w: *WithDiagnostics, inner: Cursor) Cursor {
        w.inner = inner;
        return .init(w);
    }

    pub fn next(w: *WithDiagnostics, io: Io, op: OperationContext) Error!?bson.RawDocument {
        return w.inner.next(io, op);
    }

    pub fn close(w: *WithDiagnostics, io: Io) void {
        w.inner.close(io);
    }

    pub fn deinit(w: *WithDiagnostics, io: Io) void {
        w.inner.deinit(io);
        w.destroy();
    }
};
