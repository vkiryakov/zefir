//! The compile-time checks of `rpc.Server.init`: its options, the handlers
//! it serves and their middleware. Each check returns the message of the
//! first problem it finds, or null; `rpc.Server.init` stops the build with
//! it. The messages of handlers are those of the specification, word for
//! word. Internal to the module.

const std = @import("std");
const contract = @import("contract.zig");
const ServerTransport = @import("../ServerTransport.zig");
const Limits = @import("../engine/RawServer.zig").Limits;
const Context = @import("../engine/Context.zig").Context;
const middleware = @import("../middleware.zig");
const MiddlewareFn = middleware.MiddlewareFn;
const Next = middleware.Next;

const at = "rpc.Server.init: ";
const options_list = ".transport, .handlers, .authenticator, .middleware, .limits and .shutdown_grace";
const link_function = "fn (*rpc.Context, *rpc.Next) anyerror!void";
const link_method = "pub fn run(self, *rpc.Context, *rpc.Next) anyerror!void";

/// The compile error for the options of `rpc.Server.init`, of type `O`, or
/// null. Checks the shape of the options, the transport, the
/// authenticator, every handler and the links of the server's level.
pub fn optionsProblem(comptime O: type) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    const shape = "options must be a struct literal such as .{ .transport = memory.serverTransport(), .handlers = .{&users} }, got ";
    const info = switch (@typeInfo(O)) {
        .@"struct" => |info| info,
        else => return at ++ shape ++ @typeName(O),
    };
    if (info.is_tuple and info.field_names.len > 0) return at ++ shape ++ "a tuple";
    for (info.field_names) |name| {
        if (!isOneOf(name, &.{ "transport", "handlers", "authenticator", "middleware", "limits", "shutdown_grace" }))
            return at ++ "unknown option ." ++ name ++ "; the options are " ++ options_list;
    }
    if (!@hasField(O, "transport")) return at ++ ".transport is missing; pass the server side of a transport, such as memory.serverTransport()";
    if (@FieldType(O, "transport") != ServerTransport)
        return at ++ ".transport must be an rpc.ServerTransport, such as memory.serverTransport(); got " ++ @typeName(@FieldType(O, "transport"));
    if (hasAuthenticator(O)) {
        if (authenticatorProblem(@FieldType(O, "authenticator"))) |found| return found;
    }
    if (!@hasField(O, "handlers")) return at ++ ".handlers is missing; pass pointers to the handlers, such as .{&users}";
    if (handlersProblem(@FieldType(O, "handlers"), hasAuthenticator(O))) |found| return found;
    if (@hasField(O, "limits")) {
        if (limitsProblem(@FieldType(O, "limits"))) |found| return found;
    }
    if (@hasField(O, "shutdown_grace") and @FieldType(O, "shutdown_grace") != std.Io.Duration)
        return at ++ ".shutdown_grace must be a std.Io.Duration, such as std.Io.Duration.fromSeconds(10); got " ++ @typeName(@FieldType(O, "shutdown_grace"));
    return null;
}

/// `.limits` is `rpc.Limits`, or a struct literal of some of its fields,
/// which `rpc.Server.init` copies over the defaults.
fn limitsProblem(comptime L: type) ?[]const u8 {
    if (L == Limits) return null;
    const shape = ".limits must be rpc.Limits or a struct literal of its fields, such as .{ .max_active_tasks = 1024 }; got ";
    const info = switch (@typeInfo(L)) {
        .@"struct" => |info| info,
        else => return at ++ shape ++ @typeName(L),
    };
    if (info.is_tuple and info.field_names.len > 0) return at ++ shape ++ "a tuple";
    for (info.field_names) |name| {
        if (!@hasField(Limits, name)) return at ++ ".limits has no field ." ++ name ++ "; the limits are the fields of rpc.Limits";
    }
    return null;
}

/// Whether the options of type `O` set an authenticator: `.authenticator`
/// is there and is not `null`.
pub fn hasAuthenticator(comptime O: type) bool {
    return @hasField(O, "authenticator") and @FieldType(O, "authenticator") != @TypeOf(null);
}

fn authenticatorProblem(comptime A: type) ?[]const u8 {
    const problem = at ++ ".authenticator must be a pointer to an authenticator, e.g. &auth; got " ++ @typeName(A);
    const pointer = switch (@typeInfo(A)) {
        .pointer => |pointer| pointer,
        else => return problem,
    };
    if (pointer.size != .one or !isContainer(pointer.child)) return problem;
    // rpc.Authenticator.init checks the rest: a mutable pointer and the
    // method authenticate, with messages that name the signature.
    return null;
}

fn handlersProblem(comptime H: type, comptime has_authenticator: bool) ?[]const u8 {
    const shape = ".handlers must be a tuple of pointers to handlers, such as .{&users}; got ";
    const info = switch (@typeInfo(H)) {
        .@"struct" => |info| info,
        else => return at ++ shape ++ @typeName(H),
    };
    if (info.field_names.len == 0) return at ++ ".handlers is empty; a server needs at least one handler";
    if (!info.is_tuple) return at ++ shape ++ @typeName(H);
    inline for (info.field_types, 0..) |Pointer, i| {
        if (handlerProblem(i, Pointer, has_authenticator)) |found| return found;
    }
    // Two handlers whose contracts share a route.
    inline for (info.field_types, 0..) |First, i| {
        inline for (info.field_types[i + 1 ..]) |Second| {
            const A = @typeInfo(First).pointer.child;
            const B = @typeInfo(Second).pointer.child;
            if (sharedLabel(@TypeOf(A.rpc_handler.api), @TypeOf(B.rpc_handler.api))) |label|
                return at ++ @typeName(A) ++ " and " ++ @typeName(B) ++ " both serve " ++ label;
        }
    }
    return null;
}

/// The label of two contracts that share a route, such as "users.v1"; null
/// when they share none.
fn sharedLabel(comptime A: type, comptime B: type) ?[]const u8 {
    const first = contract.InfoOf(A);
    const second = contract.InfoOf(B);
    if (first.version != second.version or !std.mem.eql(u8, first.name, second.name)) return null;
    for (@typeInfo(A).@"struct".field_names) |name| {
        if (@hasField(B, name)) return first.label;
    }
    return null;
}

/// The problem of `.handlers[index]`, a value of type `Pointer`.
fn handlerProblem(comptime index: usize, comptime Pointer: type, comptime has_authenticator: bool) ?[]const u8 {
    const by_value = std.fmt.comptimePrint("{s}.handlers[{d}] is {s}; pass a pointer to a handler, e.g. &users", .{ at, index, @typeName(Pointer) });
    const pointer = switch (@typeInfo(Pointer)) {
        .pointer => |pointer| pointer,
        else => return by_value,
    };
    if (pointer.size != .one or @typeInfo(pointer.child) != .@"struct") return by_value;
    if (pointer.attrs.@"const")
        return std.fmt.comptimePrint("{s}.handlers[{d}] is {s}; the handler must be mutable, declared with var", .{ at, index, @typeName(Pointer) });
    const T = pointer.child;
    const name = @typeName(T);
    // From another file, @hasDecl sees only pub declarations.
    if (!@hasDecl(T, "rpc_handler"))
        return at ++ name ++ " has no `pub const rpc_handler = rpc.implement(Api, ...)`; every handler must declare it (and it must be pub)";
    if (!isImplementation(T.rpc_handler)) return at ++ name ++ ".rpc_handler must be built with rpc.implement(Api, ...)";
    const Impl = T.rpc_handler;
    const C = @TypeOf(Impl.api);
    const label = contract.InfoOf(C).label;
    for (@typeInfo(@TypeOf(Impl.methods)).@"struct".field_names) |method_name| {
        if (!@hasField(C, method_name)) return "rpc: " ++ name ++ ".rpc_handler: " ++ method_name ++ " is not a method of " ++ label;
    }
    inline for (@typeInfo(C).@"struct".field_names) |method_name| {
        const M = @FieldType(C, method_name);
        if (methodProblem(T, label, method_name, M.Request, M.Response)) |found| return found;
        if (Impl.settingsOf(method_name).auth == .required and !has_authenticator)
            return at ++ name ++ "." ++ method_name ++ " requires auth, but .authenticator is not set";
    }
    return null;
}

/// Whether `D`, the declaration `rpc_handler` of a handler, is what
/// `rpc.implement` returns.
fn isImplementation(comptime D: anytype) bool {
    if (@TypeOf(D) != type or !isContainer(D)) return false;
    return @hasDecl(D, "is_rpc_implementation");
}

/// The problem of the method of `T` that implements `method_name` of the
/// contract `label`, whose types are `Req` and `Resp`.
fn methodProblem(comptime T: type, comptime label: []const u8, comptime method_name: []const u8, comptime Req: type, comptime Resp: type) ?[]const u8 {
    const name = @typeName(T);
    if (!@hasDecl(T, method_name))
        return "rpc: " ++ name ++ " implements " ++ label ++ " but has no pub fn " ++ method_name ++ "(self: *" ++ name ++ ", ctx: *rpc.Context, req: " ++ @typeName(Req) ++ ") !" ++ @typeName(Resp);
    const F = @TypeOf(@field(T, method_name));
    if (!isMethod(F, T, Req, Resp))
        return "rpc: " ++ name ++ "." ++ method_name ++ ": expected fn (*" ++ name ++ ", *rpc.Context, " ++ @typeName(Req) ++ ") !" ++ @typeName(Resp) ++ ", found " ++ @typeName(F);
    return null;
}

/// Whether `F` is `fn (*T, *rpc.Context, Req) E!Resp` for some error set
/// `E`, inferred or not.
fn isMethod(comptime F: type, comptime T: type, comptime Req: type, comptime Resp: type) bool {
    const info = switch (@typeInfo(F)) {
        .@"fn" => |info| info,
        else => return false,
    };
    if (info.is_generic or info.attrs.varargs or info.param_types.len != 3) return false;
    if (info.param_types[0] != *T or info.param_types[1] != *Context or info.param_types[2] != Req) return false;
    const Return = info.return_type orelse return false;
    return switch (@typeInfo(Return)) {
        .error_union => |error_union| error_union.payload == Resp,
        else => false,
    };
}

/// The problem of the links of `T` at the level of the handler or of one
/// method: a tuple whose items are middleware functions or names of fields
/// of `T` that hold an object. `where` names the level in the message.
pub fn linksProblem(comptime T: type, comptime where: []const u8, comptime links: anytype) ?[]const u8 {
    inline for (@typeInfo(@TypeOf(links)).@"struct".field_names, 0..) |field, i| {
        if (!isLink(T, @field(links, field)))
            return std.fmt.comptimePrint("rpc: {s}: middleware[{d}] must be " ++ link_function ++ ", or a field of {s} whose type has " ++ link_method, .{ where, i, @typeName(T) });
    }
    return null;
}

/// Whether `item` is a link of a handler of type `T`: a middleware function,
/// or `.name` of a field of `T` that holds an object with `run`, or points
/// to one.
fn isLink(comptime T: type, comptime item: anytype) bool {
    const Item = @TypeOf(item);
    if (Item == MiddlewareFn) return true;
    if (Item != @TypeOf(.enum_literal)) return false;
    if (!@hasField(T, @tagName(item))) return false;
    return objectOf(@FieldType(T, @tagName(item))) != null;
}

/// The type of the object that a field of type `F` holds or points to, if
/// it has `run`; null otherwise.
pub fn objectOf(comptime F: type) ?type {
    switch (@typeInfo(F)) {
        .pointer => |pointer| {
            if (pointer.size != .one or pointer.attrs.@"const" or !hasRun(pointer.child)) return null;
            return pointer.child;
        },
        else => return if (hasRun(F)) F else null,
    }
}

/// Whether `X` has `pub fn run(self: *X, ctx: *rpc.Context, next: *rpc.Next) anyerror!void`.
fn hasRun(comptime X: type) bool {
    if (!isContainer(X) or !@hasDecl(X, "run")) return false;
    return @TypeOf(X.run) == fn (*X, *Context, *Next) anyerror!void;
}

/// The problem of the links of the server's level, a value of type `L`:
/// middleware functions and pointers to objects.
pub fn serverLinksProblem(comptime L: type) ?[]const u8 {
    const shape = ".middleware must be a tuple such as .{ mw.logCalls, &limiter }; got ";
    const info = switch (@typeInfo(L)) {
        .@"struct" => |info| info,
        else => return at ++ shape ++ @typeName(L),
    };
    if (!info.is_tuple and info.field_names.len > 0) return at ++ shape ++ @typeName(L);
    inline for (info.field_types, 0..) |Item, i| {
        const fits = Item == MiddlewareFn or switch (@typeInfo(Item)) {
            .pointer => |pointer| pointer.size == .one and !pointer.attrs.@"const" and hasRun(pointer.child),
            else => false,
        };
        if (!fits) return std.fmt.comptimePrint("{s}.middleware[{d}] must be " ++ link_function ++ " or a pointer to a type with " ++ link_method, .{ at, i });
    }
    return null;
}

fn isContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
}

fn isOneOf(comptime name: []const u8, comptime names: []const []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

const testing = std.testing;

const GetUserRequest = struct { id: u64 };
const User = struct { id: u64, name: []const u8 };
const DeleteUserRequest = struct { id: u64 };

const UserApi = contract.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{
        .getUser = contract.method(GetUserRequest, User),
        .deleteUser = contract.method(DeleteUserRequest, void),
    },
});

const OrderApi = contract.Contract(.{
    .name = "orders",
    .version = 1,
    .methods = .{ .getUser = contract.method(GetUserRequest, User) },
});

const UserApiV2 = contract.Contract(.{
    .name = "users",
    .version = 2,
    .methods = .{ .getUser = contract.method(GetUserRequest, User) },
});

const Users = struct {
    pub const rpc_handler = contract.implement(UserApi, .{});

    pub fn getUser(self: *Users, ctx: *Context, req: GetUserRequest) !User {
        _ = self;
        _ = ctx;
        return .{ .id = req.id, .name = "Ann" };
    }

    pub fn deleteUser(self: *Users, ctx: *Context, req: DeleteUserRequest) error{UserNotFound}!void {
        _ = self;
        _ = ctx;
        if (req.id == 0) return error.UserNotFound;
    }
};

/// Another handler of the same contract.
const MoreUsers = struct {
    pub const rpc_handler = contract.implement(UserApi, .{});
    pub const getUser = MethodsOf(MoreUsers).getUser;
    pub fn deleteUser(self: *MoreUsers, ctx: *Context, req: DeleteUserRequest) !void {
        _ = self;
        _ = ctx;
        _ = req;
    }
};

const UsersV2 = struct {
    pub const rpc_handler = contract.implement(UserApiV2, .{});
    pub fn getUser(self: *UsersV2, ctx: *Context, req: GetUserRequest) !User {
        _ = self;
        _ = ctx;
        return .{ .id = req.id, .name = "Ann" };
    }
};

const Orders = struct {
    pub const rpc_handler = contract.implement(OrderApi, .{});
    pub fn getUser(self: *Orders, ctx: *Context, req: GetUserRequest) !User {
        _ = self;
        _ = ctx;
        return .{ .id = req.id, .name = "Ann" };
    }
};

/// The options of a server that serves `Handlers`.
fn Options(comptime Handlers: type) type {
    return struct { transport: ServerTransport, handlers: Handlers };
}

/// The same with an authenticator of type `A`.
fn OptionsWith(comptime Handlers: type, comptime A: type) type {
    return struct { transport: ServerTransport, handlers: Handlers, authenticator: A };
}

const Auth = struct {
    pub fn authenticate(self: *Auth, ctx: *const @import("../auth.zig").AuthContext) @import("../auth.zig").AuthError!?@import("../auth.zig").IdentityView {
        _ = self;
        _ = ctx;
        return null;
    }
};

fn expectProblem(comptime O: type, comptime expected: []const u8) !void {
    const found = comptime optionsProblem(O);
    if (found == null) {
        std.debug.print("expected: {s}\ngot no problem\n", .{expected});
        return error.TestExpectedProblem;
    }
    try testing.expectEqualStrings(expected, found.?);
}

fn expectNoProblem(comptime O: type) !void {
    const found = comptime optionsProblem(O);
    if (found) |message| {
        std.debug.print("unexpected: {s}\n", .{message});
        return error.TestUnexpectedProblem;
    }
}

test "good options pass" {
    try expectNoProblem(Options(struct { *Users }));
    try expectNoProblem(OptionsWith(struct { *Users }, @TypeOf(null)));
    try expectNoProblem(OptionsWith(struct { *Users }, *Auth));
    // Two versions of one service, and two services, on one server.
    try expectNoProblem(Options(struct { *Users, *UsersV2, *Orders }));
}

const NamedHandlers = struct { users: *Users };

test "the shape of the options" {
    try expectProblem(u32, "rpc.Server.init: options must be a struct literal such as .{ .transport = memory.serverTransport(), .handlers = .{&users} }, got u32");
    try expectProblem(struct { ServerTransport }, "rpc.Server.init: options must be a struct literal such as .{ .transport = memory.serverTransport(), .handlers = .{&users} }, got a tuple");
    try expectProblem(struct { transport: ServerTransport, handlers: struct { *Users }, handler: u8 }, "rpc.Server.init: unknown option .handler; the options are .transport, .handlers, .authenticator, .middleware, .limits and .shutdown_grace");
    try expectProblem(struct { handlers: struct { *Users } }, "rpc.Server.init: .transport is missing; pass the server side of a transport, such as memory.serverTransport()");
    try expectProblem(struct { transport: *u8, handlers: struct { *Users } }, "rpc.Server.init: .transport must be an rpc.ServerTransport, such as memory.serverTransport(); got *u8");
    try expectProblem(struct { transport: ServerTransport }, "rpc.Server.init: .handlers is missing; pass pointers to the handlers, such as .{&users}");
    try expectProblem(Options(@TypeOf(.{})), "rpc.Server.init: .handlers is empty; a server needs at least one handler");
    try expectProblem(Options(*Users), "rpc.Server.init: .handlers must be a tuple of pointers to handlers, such as .{&users}; got *app.handlers.Users");
    try expectProblem(Options(NamedHandlers), "rpc.Server.init: .handlers must be a tuple of pointers to handlers, such as .{&users}; got app.handlers.NamedHandlers");
    try expectProblem(OptionsWith(struct { *Users }, u8), "rpc.Server.init: .authenticator must be a pointer to an authenticator, e.g. &auth; got u8");
    try expectProblem(OptionsWith(struct { *Users }, []Auth), "rpc.Server.init: .authenticator must be a pointer to an authenticator, e.g. &auth; got []app.handlers.Auth");
    try expectProblem(OptionsWith(struct { *Users }, Auth), "rpc.Server.init: .authenticator must be a pointer to an authenticator, e.g. &auth; got app.handlers.Auth");
}

test "the limits and the shutdown grace" {
    const Handlers = struct { *Users };
    try expectNoProblem(struct { transport: ServerTransport, handlers: Handlers, limits: Limits, shutdown_grace: std.Io.Duration });
    try expectNoProblem(struct { transport: ServerTransport, handlers: Handlers, limits: struct { max_active_tasks: u32, max_json_depth: comptime_int } });
    try expectNoProblem(struct { transport: ServerTransport, handlers: Handlers, limits: @TypeOf(.{}) });
    try expectProblem(struct { transport: ServerTransport, handlers: Handlers, limits: struct { max_tasks: u32 } }, "rpc.Server.init: .limits has no field .max_tasks; the limits are the fields of rpc.Limits");
    try expectProblem(struct { transport: ServerTransport, handlers: Handlers, limits: u32 }, "rpc.Server.init: .limits must be rpc.Limits or a struct literal of its fields, such as .{ .max_active_tasks = 1024 }; got u32");
    try expectProblem(struct { transport: ServerTransport, handlers: Handlers, limits: struct { u32 } }, "rpc.Server.init: .limits must be rpc.Limits or a struct literal of its fields, such as .{ .max_active_tasks = 1024 }; got a tuple");
    try expectProblem(struct { transport: ServerTransport, handlers: Handlers, shutdown_grace: comptime_int }, "rpc.Server.init: .shutdown_grace must be a std.Io.Duration, such as std.Io.Duration.fromSeconds(10); got comptime_int");
}

const NoDecl = struct {
    pub fn getUser(self: *NoDecl) void {
        _ = self;
    }
};
const WrongDecl = struct {
    pub const rpc_handler = .{ .methods = .{} };
};
const TypeDecl = struct {
    pub const rpc_handler = u32;
};

test "a handler is a pointer to a struct that declares rpc_handler with rpc.implement" {
    try expectProblem(Options(struct { Users }), "rpc.Server.init: .handlers[0] is app.handlers.Users; pass a pointer to a handler, e.g. &users");
    try expectProblem(Options(struct { *Users, []Users }), "rpc.Server.init: .handlers[1] is []app.handlers.Users; pass a pointer to a handler, e.g. &users");
    try expectProblem(Options(struct { *u32 }), "rpc.Server.init: .handlers[0] is *u32; pass a pointer to a handler, e.g. &users");
    try expectProblem(Options(struct { *const Users }), "rpc.Server.init: .handlers[0] is *const app.handlers.Users; the handler must be mutable, declared with var");
    try expectProblem(Options(struct { *NoDecl }), "rpc.Server.init: app.handlers.NoDecl has no `pub const rpc_handler = rpc.implement(Api, ...)`; every handler must declare it (and it must be pub)");
    try expectProblem(Options(struct { *WrongDecl }), "rpc.Server.init: app.handlers.WrongDecl.rpc_handler must be built with rpc.implement(Api, ...)");
    try expectProblem(Options(struct { *TypeDecl }), "rpc.Server.init: app.handlers.TypeDecl.rpc_handler must be built with rpc.implement(Api, ...)");
}

const MissingMethod = struct {
    pub const rpc_handler = contract.implement(UserApi, .{});
    pub const getUser = MethodsOf(MissingMethod).getUser;
};
const NoContext = struct {
    pub const rpc_handler = contract.implement(UserApi, .{});
    pub fn getUser(self: *NoContext, req: GetUserRequest) !User {
        _ = self;
        return .{ .id = req.id, .name = "Ann" };
    }
    pub const deleteUser = MethodsOf(NoContext).deleteUser;
};
const NoErrors = struct {
    pub const rpc_handler = contract.implement(UserApi, .{});
    pub fn getUser(self: *NoErrors, ctx: *Context, req: GetUserRequest) User {
        _ = self;
        _ = ctx;
        return .{ .id = req.id, .name = "Ann" };
    }
};
const ConstSelf = struct {
    pub const rpc_handler = contract.implement(UserApi, .{});
    pub fn getUser(self: *const ConstSelf, ctx: *Context, req: GetUserRequest) error{X}!User {
        _ = self;
        _ = ctx;
        return .{ .id = req.id, .name = "Ann" };
    }
};
const OtherResponse = struct {
    pub const rpc_handler = contract.implement(UserApi, .{});
    pub fn getUser(self: *OtherResponse, ctx: *Context, req: GetUserRequest) error{X}![]const u8 {
        _ = self;
        _ = ctx;
        _ = req;
        return "Ann";
    }
};
const Generic = struct {
    pub const rpc_handler = contract.implement(UserApi, .{});
    pub fn getUser(self: *Generic, ctx: *Context, req: anytype) error{X}!User {
        _ = self;
        _ = ctx;
        return .{ .id = req.id, .name = "Ann" };
    }
};
const NotAFunction = struct {
    pub const rpc_handler = contract.implement(UserApi, .{});
    pub const getUser = 5;
};

test "a handler has a pub fn of the contract's signature for each method" {
    try expectProblem(Options(struct { *MissingMethod }), "rpc: app.handlers.MissingMethod implements users.v1 but has no pub fn deleteUser(self: *app.handlers.MissingMethod, ctx: *rpc.Context, req: app.handlers.DeleteUserRequest) !void");
    try expectProblem(Options(struct { *NoContext }), "rpc: app.handlers.NoContext.getUser: expected fn (*app.handlers.NoContext, *rpc.Context, app.handlers.GetUserRequest) !app.handlers.User, found fn (*app.handlers.NoContext, app.handlers.GetUserRequest) @typeInfo(@typeInfo(@TypeOf(app.handlers.NoContext.getUser)).@\"fn\".return_type.?).error_union.error_set!app.handlers.User");
    try expectProblem(Options(struct { *NoErrors }), "rpc: app.handlers.NoErrors.getUser: expected fn (*app.handlers.NoErrors, *rpc.Context, app.handlers.GetUserRequest) !app.handlers.User, found fn (*app.handlers.NoErrors, *engine.Context.Context, app.handlers.GetUserRequest) app.handlers.User");
    try expectProblem(Options(struct { *ConstSelf }), "rpc: app.handlers.ConstSelf.getUser: expected fn (*app.handlers.ConstSelf, *rpc.Context, app.handlers.GetUserRequest) !app.handlers.User, found fn (*const app.handlers.ConstSelf, *engine.Context.Context, app.handlers.GetUserRequest) error{X}!app.handlers.User");
    try expectProblem(Options(struct { *OtherResponse }), "rpc: app.handlers.OtherResponse.getUser: expected fn (*app.handlers.OtherResponse, *rpc.Context, app.handlers.GetUserRequest) !app.handlers.User, found fn (*app.handlers.OtherResponse, *engine.Context.Context, app.handlers.GetUserRequest) error{X}![]const u8");
    try expectProblem(Options(struct { *Generic }), "rpc: app.handlers.Generic.getUser: expected fn (*app.handlers.Generic, *rpc.Context, app.handlers.GetUserRequest) !app.handlers.User, found fn (*app.handlers.Generic, *engine.Context.Context, anytype) error{X}!app.handlers.User");
    try expectProblem(Options(struct { *NotAFunction }), "rpc: app.handlers.NotAFunction.getUser: expected fn (*app.handlers.NotAFunction, *rpc.Context, app.handlers.GetUserRequest) !app.handlers.User, found comptime_int");
}

const UnknownSetting = struct {
    pub const rpc_handler = contract.implement(UserApi, .{ .methods = .{ .getUsers = .{ .timeout_ms = 5 } } });
    pub const getUser = MethodsOf(UnknownSetting).getUser;
    pub const deleteUser = MethodsOf(UnknownSetting).deleteUser;
};

test "rpc_handler sets only methods of its contract" {
    try expectProblem(Options(struct { *UnknownSetting }), "rpc: app.handlers.UnknownSetting.rpc_handler: getUsers is not a method of users.v1");
}

/// The methods of `Users`, for handlers of other types: `self` is any
/// pointer.
fn MethodsOf(comptime T: type) type {
    return struct {
        pub fn getUser(self: *T, ctx: *Context, req: GetUserRequest) !User {
            _ = self;
            _ = ctx;
            return .{ .id = req.id, .name = "Ann" };
        }
        pub fn deleteUser(self: *T, ctx: *Context, req: DeleteUserRequest) !void {
            _ = self;
            _ = ctx;
            _ = req;
        }
    };
}

const RequiredByDefault = struct {
    pub const rpc_handler = contract.implement(UserApi, .{
        .defaults = .{ .auth = .required },
        .methods = .{ .getUser = .{ .auth = .optional } },
    });
    pub const getUser = MethodsOf(RequiredByDefault).getUser;
    pub const deleteUser = MethodsOf(RequiredByDefault).deleteUser;
};
const RequiredMethod = struct {
    pub const rpc_handler = contract.implement(UserApi, .{ .methods = .{ .getUser = .{ .auth = .required } } });
    pub const getUser = MethodsOf(RequiredMethod).getUser;
    pub const deleteUser = MethodsOf(RequiredMethod).deleteUser;
};

test "a method that requires auth needs an authenticator" {
    try expectProblem(Options(struct { *RequiredByDefault }), "rpc.Server.init: app.handlers.RequiredByDefault.deleteUser requires auth, but .authenticator is not set");
    try expectProblem(Options(struct { *RequiredMethod }), "rpc.Server.init: app.handlers.RequiredMethod.getUser requires auth, but .authenticator is not set");
    try expectProblem(OptionsWith(struct { *RequiredMethod }, @TypeOf(null)), "rpc.Server.init: app.handlers.RequiredMethod.getUser requires auth, but .authenticator is not set");
    try expectNoProblem(OptionsWith(struct { *RequiredByDefault }, *Auth));
    try expectNoProblem(OptionsWith(struct { *RequiredMethod }, *Auth));
}

test "two handlers may not serve one route" {
    try expectProblem(Options(struct { *Users, *MoreUsers }), "rpc.Server.init: app.handlers.Users and app.handlers.MoreUsers both serve users.v1");
    try expectProblem(Options(struct { *Orders, *Users, *Users }), "rpc.Server.init: app.handlers.Users and app.handlers.Users both serve users.v1");
    // The same name and version with other methods: no route is shared.
    try expectNoProblem(Options(struct { *Users, *OtherUsers }));
}

const OtherUserApi = contract.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{ .listUsers = contract.method(GetUserRequest, []const User) },
});
const OtherUsers = struct {
    pub const rpc_handler = contract.implement(OtherUserApi, .{});
    pub fn listUsers(self: *OtherUsers, ctx: *Context, req: GetUserRequest) ![]const User {
        _ = self;
        _ = ctx;
        _ = req;
        return &.{};
    }
};
