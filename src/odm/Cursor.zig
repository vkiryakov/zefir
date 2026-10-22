//! `odm.Cursor(T)`: the documents of a find, a findAs, a query or an
//! aggregateRaw, one at a time.
//!
//! ```zig
//! var adults = try users.find(io, ctx, .{ .age = .{ .gte = 18 } }, .{ .sort = .{ .age = .desc } });
//! defer adults.deinit(io);
//! while (try adults.next(io, ctx, arena)) |user| {
//!     // The strings of user live in arena.
//! }
//! ```
//!
//! A cursor holds a lease of its own on the generation of its session's
//! connection, so it may outlive the session: its work goes on where it
//! began, even when the connection is replaced meanwhile. After a forced
//! close of that generation — a drain that ran out, a shutdown past its
//! deadline — `next` is `Closed`. `deinit` closes the cursor of the driver
//! and gives the lease back; it is needed always.
//!
//! A document that does not fit is `DecodeFailed`, with the path and the
//! cause in `cursor.diagnostics()`, and the cursor goes on: the next `next`
//! reads the document after it. Each call of the cursor starts its
//! diagnostics afresh. One task at a time calls `next`, `nextRaw` and
//! `deinit` of a cursor; in safe builds two at once panic.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const bson = @import("mongo-bson");
const errors = @import("errors.zig");
const driver = @import("driver.zig");
const leases = @import("registry/generation.zig");
const Registry = @import("Registry.zig");
const Diagnostics = errors.Diagnostics;

/// The documents of a read, decoded into `T`: a model, a projection of
/// one, or the type of the results of an aggregateRaw.
pub fn Cursor(comptime T: type) type {
    return struct {
        // The fields are for odm; the application uses the methods.

        registry: *Registry,
        /// The generation whose lease the cursor holds.
        generation: *leases.Generation,
        raw: driver.RawCursor,
        /// Chosen by the call that made the cursor, which knows the model.
        decode: *const Decode(T),
        diag: Diagnostics = .{},
        /// In safe builds: a call of the cursor is in progress.
        busy: if (std.debug.runtime_safety) std.atomic.Value(bool) else void = if (std.debug.runtime_safety) .init(false) else {},

        const Self = @This();

        /// The next document, decoded into `arena`: its strings, lists and
        /// bytes are copies there. Null after the last one.
        pub fn next(c: *Self, io: Io, ctx: core.Context, arena: Allocator) errors.Error!?T {
            c.enter(io);
            defer c.leave();
            const doc = try c.raw.next(io, ctx, &c.diag) orelse return null;
            return try c.decode(arena, doc, &c.diag);
        }

        /// The BSON of the next document as the driver gives it, borrowed
        /// until the next call of the cursor; null after the last one.
        pub fn nextRaw(c: *Self, io: Io, ctx: core.Context) errors.Error!?bson.RawDocument {
            c.enter(io);
            defer c.leave();
            return c.raw.next(io, ctx, &c.diag);
        }

        /// The details of the error of the latest call of the cursor.
        pub fn diagnostics(c: *const Self) *const Diagnostics {
            return &c.diag;
        }

        /// Closes the cursor of the driver, which may tell the server, and
        /// gives the lease back.
        pub fn deinit(c: *Self, io: Io) void {
            c.enter(io);
            c.raw.deinit(io);
            leases.release(c.registry, io, c.generation);
            c.* = undefined;
        }

        fn enter(c: *Self, io: Io) void {
            c.registry.checkUse(io);
            if (std.debug.runtime_safety) {
                if (c.busy.swap(true, .acquire)) @panic("zefir-odm: a cursor used by two tasks at once: one task at a time calls next and deinit of a cursor");
            }
            c.diag = .{};
        }

        fn leave(c: *Self) void {
            if (std.debug.runtime_safety) c.busy.store(false, .release);
        }
    };
}

/// What decoding a document fails with: it is not valid BSON, it does not
/// fit, or memory ran out.
pub const DecodeError = error{ InvalidBson, DecodeFailed, OutOfMemory };

/// The decoder of a cursor of `T`: the document `raw` as a `T` in `arena`;
/// the path and the cause of a failure in `d`.
pub fn Decode(comptime T: type) type {
    return fn (arena: Allocator, raw: bson.RawDocument, d: *Diagnostics) DecodeError!T;
}
