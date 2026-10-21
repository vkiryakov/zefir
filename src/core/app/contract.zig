//! The bean contract of zefir.App: the states of an App, the lifecycle
//! methods of a bean, type-erased, and the read-only status beans may take.
const std = @import("std");

/// Where an App is in its life.
pub const State = enum(u8) { created, starting, running, stopping, stopped, failed };

/// The lifecycle methods of one bean, type-erased. A method the bean's type
/// does not declare is null.
pub const VTable = struct {
    start: ?*const fn (ptr: *anyopaque, io: std.Io) anyerror!void = null,
    wait: ?*const fn (ptr: *anyopaque, io: std.Io) anyerror!void = null,
    requestStop: ?*const fn (ptr: *anyopaque, io: std.Io) void = null,
    shutdown: ?*const fn (ptr: *anyopaque, io: std.Io, deadline: std.Io.Clock.Timestamp) anyerror!void = null,
    isReady: ?*const fn (ptr: *const anyopaque) bool = null,
    /// Calls the bean's `deinit(self)` or `deinit(self, io)`.
    deinit: ?*const fn (ptr: *anyopaque, io: std.Io) void = null,
};

/// A bean App drives: its label, its address in App's memory and its methods.
pub const Entry = struct { name: []const u8, ptr: *anyopaque, vtable: *const VTable };

/// What a bean may read about its App: take `*const zefir.app.Status`, for
/// example in the controller of `/readyz`. It lives in App's memory, so the
/// pointer stays valid while the App lives, wherever the App value moves.
pub const Status = struct {
    /// App's own fields, as in `http.Server`: a bean sees the methods, and
    /// reaches no entries of its neighbours.
    internal: Internal = .{},

    pub const Internal = struct {
        state: std.atomic.Value(State) = .init(.created),
        entries: []const Entry = &.{},
    };

    pub fn state(status: *const Status) State {
        return status.internal.state.load(.acquire);
    }

    /// Whether the App runs and every bean with `isReady` is ready.
    pub fn isReady(status: *const Status) bool {
        if (status.state() != .running) return false;
        for (status.internal.entries) |entry| {
            if (entry.vtable.isReady) |isReadyFn| if (!isReadyFn(entry.ptr)) return false;
        }
        return true;
    }
};

/// Whether App calls a method of a bean of type T, so that T gets an entry.
pub fn needsEntry(comptime T: type) bool {
    return @hasDecl(T, "deinit");
}

/// The methods of T, type-erased: one VTable per type, in static memory.
pub fn vtableOf(comptime T: type) *const VTable {
    const S = struct {
        fn deinit(p: *anyopaque, io: std.Io) void {
            const self: *T = @ptrCast(@alignCast(p));
            if (@typeInfo(@TypeOf(T.deinit)).@"fn".param_types.len == 2) self.deinit(io) else self.deinit();
        }
        const vtable: VTable = .{
            .deinit = if (@hasDecl(T, "deinit")) deinit else null,
        };
    };
    return &S.vtable;
}
