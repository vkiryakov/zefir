//! The bean contract of zefir.App: the states of an App, the lifecycle
//! methods of a bean, type-erased, and the read-only status beans may take.
const std = @import("std");
const names = @import("names.zig");

const pre = names.pre;

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

/// The methods of the contract (design §7): a provider or a factory result
/// that declares one of them is a bean App drives.
pub const lifecycle_names = [_][]const u8{ "start", "wait", "requestStop", "shutdown", "isReady", "deinit" };

/// Whether T declares the marker `pub const app_lifecycle = false;`: App
/// builds and frees such a type, and its owner (a server of rpc for its
/// transport) starts and stops it. Only `deinit` counts then.
fn isMarked(comptime T: type) bool {
    return @hasDecl(T, "app_lifecycle");
}

/// Whether App calls a method of a bean of type T, so that T gets an entry.
pub fn needsEntry(comptime T: type) bool {
    if (!names.isContainer(T)) return false;
    if (isMarked(T)) return @hasDecl(T, "deinit");
    for (lifecycle_names) |m| if (@hasDecl(T, m)) return true;
    return false;
}

/// The methods App calls on a bean of type T, as messages list them:
/// "start, shutdown, deinit"; with the marker, "deinit".
pub fn drivenMethods(comptime T: type) []const u8 {
    var out: []const u8 = "";
    for (lifecycle_names) |m| if (@hasDecl(T, m) and (!isMarked(T) or eql(m, "deinit"))) {
        out = out ++ (if (out.len == 0) "" else ", ") ++ m;
    };
    return out;
}

/// Checks the marker and the signature of every method of the contract that
/// T declares. `where` names the place of T in its module, for the marker:
/// "Root.providers".
pub fn checkMethods(comptime Root: type, comptime T: type, comptime where: []const u8) void {
    if (!names.isContainer(T)) return;
    const t = names.typeName(T);
    if (isMarked(T)) {
        const Marker = @TypeOf(T.app_lifecycle);
        const marker_rule = "; the marker only says false (App builds and frees the type, its owner starts and stops it): write false, or drop the declaration";
        if (Marker != bool) @compileError(pre(Root) ++ where ++ ": " ++ t ++ ".app_lifecycle is a " ++ names.typeName(Marker) ++ marker_rule);
        if (T.app_lifecycle) @compileError(pre(Root) ++ where ++ ": " ++ t ++ ".app_lifecycle is true" ++ marker_rule);
    } else {
        for (methods) |m| if (@hasDecl(T, m.name) and !hasShape(T, m.name, m.params(T), m.returns))
            @compileError(pre(Root) ++ t ++ "." ++ m.name ++ " has the wrong signature; expected " ++ m.signature(t) ++ foreignHint(T, m.name));
    }
    if (@hasDecl(T, "deinit") and !hasShape(T, "deinit", &.{*T}, .nothing) and !hasShape(T, "deinit", &.{ *T, std.Io }, .nothing))
        @compileError(pre(Root) ++ t ++ ".deinit has the wrong signature; expected pub fn deinit(self: *" ++ t ++ ") void or pub fn deinit(self: *" ++ t ++ ", io: std.Io) void");
}

/// What a method of the contract returns: `void`; `!void` (void or an error
/// union of void); or `bool`.
const Returns = enum { nothing, may_fail, flag };

const Method = struct {
    name: []const u8,
    returns: Returns,

    fn params(comptime m: Method, comptime T: type) []const type {
        if (eql(m.name, "shutdown")) return &.{ *T, std.Io, std.Io.Clock.Timestamp };
        if (eql(m.name, "isReady")) return &.{*const T};
        return &.{ *T, std.Io };
    }

    fn signature(comptime m: Method, comptime t: []const u8) []const u8 {
        if (eql(m.name, "shutdown")) return "pub fn shutdown(self: *" ++ t ++ ", io: std.Io, deadline: std.Io.Clock.Timestamp) !void";
        if (eql(m.name, "isReady")) return "pub fn isReady(self: *const " ++ t ++ ") bool";
        const result = if (m.returns == .nothing) "void" else "!void";
        return "pub fn " ++ m.name ++ "(self: *" ++ t ++ ", io: std.Io) " ++ result;
    }
};

/// The methods of the contract but `deinit`, which has two forms.
const methods = [_]Method{
    .{ .name = "start", .returns = .may_fail },
    .{ .name = "wait", .returns = .may_fail },
    .{ .name = "requestStop", .returns = .nothing },
    .{ .name = "shutdown", .returns = .may_fail },
    .{ .name = "isReady", .returns = .flag },
};

/// A `start` with three params or an `isReady` that takes `*T` look like a
/// transport of rpc, whose methods of these names the server calls: the
/// marker is the way out.
fn foreignHint(comptime T: type, comptime m: []const u8) []const u8 {
    const info = @typeInfo(@TypeOf(@field(T, m)));
    if (info != .@"fn") return "";
    const params = info.@"fn".param_types;
    const foreign = (eql(m, "start") and params.len == 3) or (eql(m, "isReady") and params.len == 1 and params[0] == *T);
    if (!foreign) return "";
    return "; if " ++ names.typeName(T) ++ "." ++ m ++ " belongs to another contract (a transport of rpc), declare `pub const app_lifecycle = false;`";
}

fn hasShape(comptime T: type, comptime m: []const u8, comptime params: []const type, comptime returns: Returns) bool {
    const info = @typeInfo(@TypeOf(@field(T, m)));
    if (info != .@"fn") return false;
    const f = info.@"fn";
    if (f.param_types.len != params.len) return false;
    for (f.param_types, params) |got, want| if (got != want) return false;
    const R = f.return_type orelse return false;
    return switch (returns) {
        .nothing => R == void,
        .may_fail => R == void or (@typeInfo(R) == .error_union and @typeInfo(R).error_union.payload == void),
        .flag => R == bool,
    };
}

/// The methods of T, type-erased: one VTable per type, in static memory. A
/// type with the marker gets only its `deinit`.
pub fn vtableOf(comptime T: type) *const VTable {
    const driven = !isMarked(T);
    const S = struct {
        fn self(p: *anyopaque) *T {
            return @ptrCast(@alignCast(p));
        }
        fn start(p: *anyopaque, io: std.Io) anyerror!void {
            return self(p).start(io);
        }
        fn wait(p: *anyopaque, io: std.Io) anyerror!void {
            return self(p).wait(io);
        }
        fn requestStop(p: *anyopaque, io: std.Io) void {
            self(p).requestStop(io);
        }
        fn shutdown(p: *anyopaque, io: std.Io, deadline: std.Io.Clock.Timestamp) anyerror!void {
            return self(p).shutdown(io, deadline);
        }
        fn isReady(p: *const anyopaque) bool {
            const bean: *const T = @ptrCast(@alignCast(p));
            return bean.isReady();
        }
        fn deinit(p: *anyopaque, io: std.Io) void {
            if (@typeInfo(@TypeOf(T.deinit)).@"fn".param_types.len == 2) self(p).deinit(io) else self(p).deinit();
        }
        const vtable: VTable = .{
            .start = if (driven and @hasDecl(T, "start")) start else null,
            .wait = if (driven and @hasDecl(T, "wait")) wait else null,
            .requestStop = if (driven and @hasDecl(T, "requestStop")) requestStop else null,
            .shutdown = if (driven and @hasDecl(T, "shutdown")) shutdown else null,
            .isReady = if (driven and @hasDecl(T, "isReady")) isReady else null,
            .deinit = if (@hasDecl(T, "deinit")) deinit else null,
        };
    };
    return &S.vtable;
}

fn eql(comptime a: []const u8, comptime b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
