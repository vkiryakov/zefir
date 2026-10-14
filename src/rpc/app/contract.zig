//! Contracts: what a service opens to its clients, written by hand in a Zig
//! package that the server and its clients share. A contract holds the
//! name and the major version of the service, its methods with their
//! request and response types, and the errors of the application that
//! clients see:
//!
//! ```zig
//! pub const UserApi = rpc.Contract(.{
//!     .name = "users",
//!     .version = 1,
//!     .methods = .{
//!         .getUser = rpc.method(GetUserRequest, User),
//!         .deleteUser = rpc.method(DeleteUserRequest, void),
//!     },
//!     .errors = .{
//!         .UserNotFound = .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" },
//!     },
//! });
//! ```
//!
//! `rpc.Contract` returns a value, not a type: each method is a field of
//! it, so a client passes the method itself to a call
//! (`client.call(io, ctx, UserApi.getUser, request, .{})`). A handler
//! implements the contract with
//! `pub const rpc_handler = rpc.implement(UserApi, .{ ... })`.
//!
//! The compiler checks every rule; a mistake stops the build with a message
//! that starts with "rpc: " and names the contract ("users.v1"). Zig checks
//! a declaration only when something uses it, so a contract is checked once
//! a server, a client or a test refers to it.

const std = @import("std");
const core = @import("core");
const model = @import("../model.zig");
const rules = @import("../rules.zig");
const dto = @import("dto.zig");

/// Whether a method requires an identity.
pub const Auth = @import("../engine/RawServer.zig").Method.Auth;

/// The longest `.message` of an error of a contract, in bytes.
pub const max_message_bytes = 512;

/// The server's limit for a call when `rpc.implement` sets none, in
/// milliseconds.
pub const default_timeout_ms = 3000;

/// The longest `.timeout_ms` that `rpc.implement` accepts.
pub const max_timeout_ms = 300_000;

/// The request and response types of one method, for the `.methods` of a
/// contract: `.getUser = rpc.method(GetUserRequest, User)`. `Req` is a
/// struct; `Resp` is any type JSON can carry, or `void` for a method that
/// answers with nothing but success. `rpc.Contract` checks both.
pub fn method(comptime Req: type, comptime Resp: type) type {
    return struct {
        pub const Request = Req;
        pub const Response = Resp;
    };
}

/// One entry of the `.errors` of a contract: an error that handlers return
/// and the failure that clients get for it.
pub const ErrorMapping = struct {
    /// The name of the Zig error, such as "UserNotFound".
    name: []const u8,
    failure: model.Failure,
};

/// The contract that `spec` describes: a value whose fields are its
/// methods. `spec` is `.{ .name, .version, .methods, .errors }`, as in the
/// doc of this file:
///
/// - `.name`: the service, 1 to 64 characters from `[A-Za-z0-9_-]`;
/// - `.version`: its major version, 1 to 65535; another version is
///   another contract;
/// - `.methods`: at least one, each `rpc.method(Req, Resp)`, named like
///   the service; the name of the field is the name of the method on the
///   wire;
/// - `.errors` (optional): Zig error → `.{ .code, .app_code, .message }`.
///   `.code` is one of the 16 codes of `core.ErrorCode`; `.app_code` is a
///   stable code of 1 to 128 bytes of UTF-8, unique in the contract, that
///   does not start with "rpc."; `.message` is a safe text for people, at
///   most 512 bytes. The errors that rpc maps by itself (`Canceled`,
///   `Cancelled`, `DeadlineExceeded`, `InvalidArgument`,
///   `Unauthenticated`, `PermissionDenied`, `ResourceExhausted`,
///   `Unavailable`, `OutOfMemory`, `Internal`, `RpcFailure`) cannot be
///   listed.
///
/// A method of the contract, such as `UserApi.getUser`, is a value of a
/// type without fields. Its type holds the rest as declarations:
/// `Request`, `Response`, `name`, `route` and `contract`, which holds the
/// `name`, `version` and `errors` of the contract. So a method may be
/// called `name`, `version` or `errors` too.
pub fn Contract(comptime spec: anytype) ContractType(spec) {
    var contract: ContractType(spec) = undefined;
    inline for (@typeInfo(ContractType(spec)).@"struct".field_names) |name| @field(contract, name) = .{};
    return contract;
}

/// The type of the value that `Contract(spec)` returns: a field for each
/// method, whose type is the method's descriptor. A type made with
/// `@Struct` cannot have declarations, so the methods are fields.
fn ContractType(comptime spec: anytype) type {
    if (comptime specProblem(spec)) |message| @compileError(message);
    const About = Info(spec);
    const names = @typeInfo(@TypeOf(spec.methods)).@"struct".field_names;
    var types: [names.len]type = undefined;
    for (names, &types) |name, *Descriptor| Descriptor.* = MethodOf(About, name, @field(spec.methods, name));
    return @Struct(.auto, null, names, &types, &@splat(.{}));
}

/// What a contract says about itself: the `contract` declaration of each of
/// its methods.
fn Info(comptime spec: anytype) type {
    return struct {
        /// The service, such as "users".
        pub const name: []const u8 = spec.name;
        /// The major version of the service.
        pub const version: u16 = spec.version;
        /// How messages name the contract: "users.v1".
        pub const label: []const u8 = std.fmt.comptimePrint("{s}.v{d}", .{ name, version });
        /// The `.errors` of the contract, in their order.
        pub const errors: []const ErrorMapping = mappings(spec);

        /// The failure that the `.errors` of the contract give `err`; null
        /// for an error the contract does not list.
        pub fn mapError(err: anyerror) ?model.Failure {
            inline for (errors) |entry| {
                if (err == @field(anyerror, entry.name)) return entry.failure;
            }
            return null;
        }
    };
}

/// The type of one method of a contract.
fn MethodOf(comptime About: type, comptime method_name: [:0]const u8, comptime Types: type) type {
    return struct {
        pub const is_rpc_method = true;
        pub const Request = Types.Request;
        pub const Response = Types.Response;
        /// The name of the method, as in `.methods`.
        pub const name: []const u8 = method_name;
        pub const route: model.Route = .{ .service = About.name, .version = About.version, .method = method_name };
        /// The name, version and errors of the contract.
        pub const contract = About;
    };
}

/// Whether `C` is the type of a contract that `rpc.Contract` returned.
pub fn isContract(comptime C: type) bool {
    const info = switch (@typeInfo(C)) {
        .@"struct" => |info| info,
        else => return false,
    };
    if (info.is_tuple or info.field_names.len == 0) return false;
    inline for (info.field_types) |Field| {
        if (@typeInfo(Field) != .@"struct" or !@hasDecl(Field, "is_rpc_method")) return false;
    }
    return true;
}

/// The name, version and errors of the contract of type `C`; `C` passes
/// `isContract`.
pub fn InfoOf(comptime C: type) type {
    return @typeInfo(C).@"struct".field_types[0].contract;
}

fn mappings(comptime spec: anytype) []const ErrorMapping {
    if (!@hasField(@TypeOf(spec), "errors")) return &.{};
    const names = @typeInfo(@TypeOf(spec.errors)).@"struct".field_names;
    var list: [names.len]ErrorMapping = undefined;
    for (names, &list) |name, *entry| {
        const given = @field(spec.errors, name);
        entry.* = .{ .name = name, .failure = .{ .code = given.code, .app_code = given.app_code, .message = given.message } };
    }
    const result = list;
    return &result;
}

/// The names of errors that rpc maps to failures by itself.
const reserved_errors = [_][]const u8{
    "Canceled",        "Cancelled",        "DeadlineExceeded",  "InvalidArgument",
    "Unauthenticated", "PermissionDenied", "ResourceExhausted", "Unavailable",
    "OutOfMemory",     "Internal",         "RpcFailure",
};

const name_rule = "must be 1 to 64 characters from [A-Za-z0-9_-]";
const spec_shape = "rpc.Contract takes .{ .name, .version, .methods, .errors }, got ";
const methods_shape = ".methods must be a struct literal such as .{ .getUser = rpc.method(GetUserRequest, User) }, got ";
const errors_shape = ".errors must be a struct literal such as .{ .UserNotFound = .{ .code = .not_found, .app_code = \"users.not_found\", .message = \"User not found\" } }, got ";

/// The compile error for a contract against the rules, or null.
fn specProblem(comptime spec: anytype) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    const S = @TypeOf(spec);
    const info = switch (@typeInfo(S)) {
        .@"struct" => |info| info,
        else => return "rpc: " ++ spec_shape ++ @typeName(S),
    };
    if (info.is_tuple and info.field_names.len > 0) return "rpc: " ++ spec_shape ++ "a tuple";
    const called: []const u8 = if (@hasField(S, "name") and stringOf(spec.name) != null)
        "\"" ++ stringOf(spec.name).? ++ "\""
    else
        "without a name";
    for (info.field_names) |field| {
        if (!isOneOf(field, &.{ "name", "version", "methods", "errors" }))
            return "rpc: contract " ++ called ++ ": unknown field ." ++ field ++ "; a contract has .name, .version, .methods and .errors";
    }

    if (!@hasField(S, "name")) return "rpc: a contract needs .name, the service, such as \"users\"";
    const name = stringOf(spec.name) orelse
        return "rpc: contract .name must be a string such as \"users\", got " ++ @typeName(@TypeOf(spec.name));
    if (!rules.isValidName(name)) return "rpc: contract \"" ++ name ++ "\": the name " ++ name_rule;

    if (!@hasField(S, "version")) return "rpc: contract \"" ++ name ++ "\" needs .version, the major version of the service, from 1 to 65535";
    if (!isInteger(@TypeOf(spec.version)))
        return "rpc: contract \"" ++ name ++ "\": .version must be an integer from 1 to 65535, got " ++ @typeName(@TypeOf(spec.version));
    if (spec.version < 1 or spec.version > std.math.maxInt(u16))
        return std.fmt.comptimePrint("rpc: contract \"{s}\": .version must be 1 to 65535, got {d}", .{ name, spec.version });

    const label = std.fmt.comptimePrint("{s}.v{d}", .{ name, spec.version });
    if (!@hasField(S, "methods")) return "rpc: " ++ label ++ ": a contract needs .methods, such as .{ .getUser = rpc.method(GetUserRequest, User) }";
    if (methodsProblem(label, spec.methods)) |found| return found;
    if (@hasField(S, "errors")) {
        if (errorsProblem(label, spec.errors)) |found| return found;
    }
    return null;
}

fn methodsProblem(comptime label: []const u8, comptime methods: anytype) ?[]const u8 {
    const at = "rpc: " ++ label ++ ": ";
    const M = @TypeOf(methods);
    const info = switch (@typeInfo(M)) {
        .@"struct" => |info| info,
        else => return at ++ methods_shape ++ @typeName(M),
    };
    if (info.field_names.len == 0) return at ++ ".methods is empty; a contract has at least one method";
    if (info.is_tuple) return at ++ methods_shape ++ "a tuple";
    for (info.field_names) |name| {
        if (!rules.isValidName(name)) return at ++ "the method name \"" ++ name ++ "\" " ++ name_rule;
    }
    inline for (info.field_names) |name| {
        const given = @field(methods, name);
        const where = "rpc: " ++ label ++ "." ++ name ++ ": ";
        if (@TypeOf(given) != type) return where ++ "write rpc.method(Request, Response), got " ++ @typeName(@TypeOf(given));
        if (!isMethodTypes(given)) return where ++ "write rpc.method(Request, Response), got the type " ++ @typeName(given);
        if (dto.problem(given.Request, .request)) |found| return where ++ found;
        if (dto.problem(given.Response, .response)) |found| return where ++ found;
    }
    return null;
}

/// Whether `T` is what `method` returns.
fn isMethodTypes(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "Request") or !@hasDecl(T, "Response")) return false;
    if (@TypeOf(T.Request) != type or @TypeOf(T.Response) != type) return false;
    return T == method(T.Request, T.Response);
}

fn errorsProblem(comptime label: []const u8, comptime errors: anytype) ?[]const u8 {
    const at = "rpc: " ++ label ++ ": ";
    const E = @TypeOf(errors);
    const info = switch (@typeInfo(E)) {
        .@"struct" => |info| info,
        else => return at ++ errors_shape ++ @typeName(E),
    };
    if (info.is_tuple and info.field_names.len > 0) return at ++ errors_shape ++ "a tuple";
    inline for (info.field_names) |name| {
        const here = at ++ ".errors." ++ name;
        if (isOneOf(name, &reserved_errors))
            return here ++ ": rpc maps " ++ name ++ " by itself, so a contract cannot list it; give the error another name";
        if (entryProblem(here, @field(errors, name))) |found| return found;
    }
    inline for (info.field_names, 0..) |first, i| {
        inline for (info.field_names[i + 1 ..]) |second| {
            const code = stringOf(@field(errors, first).app_code).?;
            if (std.mem.eql(u8, code, stringOf(@field(errors, second).app_code).?))
                return at ++ ".errors." ++ first ++ " and .errors." ++ second ++ " share .app_code \"" ++ code ++ "\"; each error needs its own";
        }
    }
    return null;
}

fn entryProblem(comptime here: []const u8, comptime entry: anytype) ?[]const u8 {
    const T = @TypeOf(entry);
    const shape = " must be .{ .code, .app_code, .message }, got ";
    const info = switch (@typeInfo(T)) {
        .@"struct" => |info| info,
        else => return here ++ shape ++ @typeName(T),
    };
    if (info.is_tuple and info.field_names.len > 0) return here ++ shape ++ "a tuple";
    for (info.field_names) |field| {
        if (!isOneOf(field, &.{ "code", "app_code", "message" }))
            return here ++ ": unknown field ." ++ field ++ "; an error has .code, .app_code and .message";
    }
    inline for (.{ "code", "app_code", "message" }) |field| {
        if (!@hasField(T, field)) return here ++ " needs .code, .app_code and .message; ." ++ field ++ " is missing";
    }

    const code_rule = ".code must be one of core.ErrorCode, such as .not_found, got ";
    switch (@typeInfo(@TypeOf(entry.code))) {
        .enum_literal => if (!@hasField(core.ErrorCode, @tagName(entry.code))) return here ++ code_rule ++ "." ++ @tagName(entry.code),
        else => if (@TypeOf(entry.code) != core.ErrorCode) return here ++ code_rule ++ @typeName(@TypeOf(entry.code)),
    }

    const app_code = stringOf(entry.app_code) orelse
        return here ++ ".app_code must be a string such as \"users.not_found\", got " ++ @typeName(@TypeOf(entry.app_code));
    if (app_code.len == 0) return here ++ ".app_code is empty; write a stable code such as \"users.not_found\"";
    if (app_code.len > rules.max_app_code_bytes)
        return std.fmt.comptimePrint("{s}.app_code is {d} bytes; the limit is {d}", .{ here, app_code.len, rules.max_app_code_bytes });
    if (!std.unicode.utf8ValidateSlice(app_code)) return here ++ ".app_code is not valid UTF-8";
    if (std.mem.startsWith(u8, app_code, "rpc."))
        return here ++ ".app_code \"" ++ app_code ++ "\" starts with \"rpc.\", which belongs to the framework";

    const message = stringOf(entry.message) orelse
        return here ++ ".message must be a string such as \"User not found\", got " ++ @typeName(@TypeOf(entry.message));
    if (message.len > max_message_bytes)
        return std.fmt.comptimePrint("{s}.message is {d} bytes; the limit is {d}", .{ here, message.len, max_message_bytes });
    if (!std.unicode.utf8ValidateSlice(message)) return here ++ ".message is not valid UTF-8";
    return null;
}

/// The settings of one method of a handler, as `rpc.implement` merges them.
pub const MethodSettings = struct {
    /// The server's limit for a call, in milliseconds.
    timeout_ms: u32 = default_timeout_ms,
    auth: Auth = .optional,
};

/// The declaration `rpc_handler` of a handler: the contract it implements
/// and its settings. `settings` is `.{ .defaults, .middleware, .methods }`,
/// each optional:
///
/// - `.defaults`: `.timeout_ms`, the server's limit for a call, 1 to
///   300 000 (3000 by default), and `.auth`, `.required` or `.optional`
///   (by default): with `.required` a call without an identity is refused
///   with `unauthenticated`;
/// - `.middleware`: a tuple of links for every method of the handler;
/// - `.methods.<name>`: `.timeout_ms` and `.auth` of one method, over
///   `.defaults`, and its `.middleware`, after that of the handler.
///
/// `rpc.implement` checks what does not need the type of the handler;
/// `rpc.Server.init` checks the rest: that the handler has a method for
/// each method of the contract, that `.methods` names only those, and the
/// links of middleware.
pub fn implement(comptime contract: anytype, comptime settings: anytype) type {
    const C = @TypeOf(contract);
    if (!isContract(C)) @compileError("rpc.implement: the first argument must be a contract made by rpc.Contract(...), got " ++ @typeName(C));
    if (comptime settingsProblem(InfoOf(C).label, settings)) |message| @compileError(message);
    const S = @TypeOf(settings);
    return struct {
        pub const is_rpc_implementation = true;
        /// The contract the handler implements.
        pub const api = contract;
        /// `.defaults`, with the default values for what it leaves out.
        pub const defaults: MethodSettings = merge(.{}, if (@hasField(S, "defaults")) settings.defaults else .{});
        /// The links of every method of the handler, as written.
        pub const middleware = if (@hasField(S, "middleware")) settings.middleware else .{};
        /// The settings of single methods, as written.
        pub const methods = if (@hasField(S, "methods")) settings.methods else .{};

        /// The timeout and the auth of the method `name`: its entry in
        /// `.methods` over `.defaults`.
        pub fn settingsOf(comptime name: []const u8) MethodSettings {
            if (!@hasField(@TypeOf(methods), name)) return defaults;
            return merge(defaults, @field(methods, name));
        }
    };
}

/// `base` with what `group` sets; `group` passed `groupProblem`.
fn merge(comptime base: MethodSettings, comptime group: anytype) MethodSettings {
    var result = base;
    if (@hasField(@TypeOf(group), "timeout_ms")) result.timeout_ms = group.timeout_ms;
    if (@hasField(@TypeOf(group), "auth")) result.auth = group.auth;
    return result;
}

fn settingsProblem(comptime label: []const u8, comptime settings: anytype) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    const at = "rpc.implement(" ++ label ++ "): ";
    const S = @TypeOf(settings);
    const shape = "settings must be a struct literal .{ .defaults, .middleware, .methods }, got ";
    const info = switch (@typeInfo(S)) {
        .@"struct" => |info| info,
        else => return at ++ shape ++ @typeName(S),
    };
    if (info.is_tuple and info.field_names.len > 0) return at ++ shape ++ "a tuple";
    for (info.field_names) |field| {
        if (!isOneOf(field, &.{ "defaults", "middleware", "methods" }))
            return at ++ "unknown setting ." ++ field ++ "; the settings are .defaults, .middleware and .methods";
    }
    if (@hasField(S, "defaults")) {
        if (groupProblem(at, ".defaults", settings.defaults, &.{ "timeout_ms", "auth" }, ".defaults has .timeout_ms and .auth")) |found| return found;
    }
    if (@hasField(S, "middleware")) {
        if (middlewareProblem(at, ".middleware", settings.middleware)) |found| return found;
    }
    if (@hasField(S, "methods")) {
        const M = @TypeOf(settings.methods);
        const methods_info = switch (@typeInfo(M)) {
            .@"struct" => |methods_info| methods_info,
            else => return at ++ ".methods must be a struct literal such as .{ .getUser = .{ .auth = .optional } }, got " ++ @typeName(M),
        };
        if (methods_info.is_tuple and methods_info.field_names.len > 0)
            return at ++ ".methods must be a struct literal such as .{ .getUser = .{ .auth = .optional } }, got a tuple";
        inline for (methods_info.field_names) |name| {
            const entry = @field(settings.methods, name);
            const path = ".methods." ++ name;
            if (groupProblem(at, path, entry, &.{ "timeout_ms", "auth", "middleware" }, "a method has .timeout_ms, .auth and .middleware")) |found| return found;
            if (@hasField(@TypeOf(entry), "middleware")) {
                if (middlewareProblem(at, path ++ ".middleware", entry.middleware)) |found| return found;
            }
        }
    }
    return null;
}

/// The problem of `.defaults` or of one entry of `.methods`.
fn groupProblem(
    comptime at: []const u8,
    comptime path: []const u8,
    comptime group: anytype,
    comptime allowed: []const []const u8,
    comptime has: []const u8,
) ?[]const u8 {
    const G = @TypeOf(group);
    const shape = " must be a struct literal such as .{ .timeout_ms = 5000, .auth = .required }, got ";
    const info = switch (@typeInfo(G)) {
        .@"struct" => |info| info,
        else => return at ++ path ++ shape ++ @typeName(G),
    };
    if (info.is_tuple and info.field_names.len > 0) return at ++ path ++ shape ++ "a tuple";
    for (info.field_names) |field| {
        if (!isOneOf(field, allowed)) return at ++ "unknown setting " ++ path ++ "." ++ field ++ "; " ++ has;
    }
    if (@hasField(G, "timeout_ms")) {
        const rule = std.fmt.comptimePrint("{s}{s}.timeout_ms must be 1 to {d} ms, got ", .{ at, path, max_timeout_ms });
        if (!isInteger(@TypeOf(group.timeout_ms))) return rule ++ @typeName(@TypeOf(group.timeout_ms));
        if (group.timeout_ms < 1 or group.timeout_ms > max_timeout_ms) return rule ++ std.fmt.comptimePrint("{d}", .{group.timeout_ms});
    }
    if (@hasField(G, "auth")) {
        const rule = at ++ path ++ ".auth must be .required or .optional, got ";
        switch (@typeInfo(@TypeOf(group.auth))) {
            .enum_literal => if (!@hasField(Auth, @tagName(group.auth))) return rule ++ "." ++ @tagName(group.auth),
            else => if (@TypeOf(group.auth) != Auth) return rule ++ @typeName(@TypeOf(group.auth)),
        }
    }
    return null;
}

fn middlewareProblem(comptime at: []const u8, comptime path: []const u8, comptime links: anytype) ?[]const u8 {
    const L = @TypeOf(links);
    const is_tuple = switch (@typeInfo(L)) {
        .@"struct" => |info| info.is_tuple or info.field_names.len == 0,
        else => false,
    };
    if (!is_tuple) return at ++ path ++ " must be a tuple such as .{ mw.audit }, got " ++ @typeName(L);
    return null;
}

/// `value` as a string, if it is one.
fn stringOf(comptime value: anytype) ?[]const u8 {
    switch (@typeInfo(@TypeOf(value))) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8) return value,
            .one => switch (@typeInfo(ptr.child)) {
                .array => |array| if (array.child == u8) return value,
                else => {},
            },
            else => {},
        },
        else => {},
    }
    return null;
}

fn isInteger(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .comptime_int => true,
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

const UserApi = Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{
        .getUser = method(GetUserRequest, User),
        .deleteUser = method(DeleteUserRequest, void),
    },
    .errors = .{
        .UserNotFound = .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" },
        .EmailTaken = .{ .code = core.ErrorCode.already_exists, .app_code = "users.email_taken", .message = "Email already taken" },
    },
});

test "a contract is a value whose fields are its methods" {
    const GetUser = @TypeOf(UserApi.getUser);
    try testing.expect(GetUser.is_rpc_method);
    try testing.expect(GetUser.Request == GetUserRequest);
    try testing.expect(GetUser.Response == User);
    try testing.expectEqualStrings("getUser", GetUser.name);
    try testing.expectEqualStrings("users", GetUser.route.service);
    try testing.expectEqual(@as(u16, 1), GetUser.route.version);
    try testing.expectEqualStrings("getUser", GetUser.route.method);
    try testing.expect(@TypeOf(UserApi.deleteUser).Response == void);
    try testing.expectEqual(@as(usize, 0), @sizeOf(@TypeOf(UserApi)));
    try testing.expectEqual(@as(usize, 2), @typeInfo(@TypeOf(UserApi)).@"struct".field_names.len);
}

test "the methods of a contract share its name, version and errors" {
    const About = @TypeOf(UserApi.getUser).contract;
    try testing.expect(About == @TypeOf(UserApi.deleteUser).contract);
    try testing.expect(About == InfoOf(@TypeOf(UserApi)));
    try testing.expectEqualStrings("users", About.name);
    try testing.expectEqual(@as(u16, 1), About.version);
    try testing.expectEqualStrings("users.v1", About.label);
    try testing.expectEqual(@as(usize, 2), About.errors.len);
    try testing.expectEqualStrings("UserNotFound", About.errors[0].name);
    try testing.expectEqual(core.ErrorCode.not_found, About.errors[0].failure.code);
    try testing.expectEqualStrings("users.not_found", About.errors[0].failure.app_code);
    try testing.expectEqualStrings("User not found", About.errors[0].failure.message);
    try testing.expectEqual(core.ErrorCode.already_exists, About.errors[1].failure.code);
}

test "mapError gives the failure of a listed error and null for any other" {
    const About = InfoOf(@TypeOf(UserApi));
    const failure = About.mapError(error.EmailTaken).?;
    try testing.expectEqual(core.ErrorCode.already_exists, failure.code);
    try testing.expectEqualStrings("users.email_taken", failure.app_code);
    try testing.expectEqualStrings("Email already taken", failure.message);
    try testing.expect(About.mapError(error.Unknown) == null);
    try testing.expect(About.mapError(error.OutOfMemory) == null);
    const map: *const fn (anyerror) ?model.Failure = &About.mapError;
    try testing.expectEqualStrings("users.not_found", map(error.UserNotFound).?.app_code);
}

test "a contract without errors maps nothing" {
    const Api = Contract(.{ .name = "ping", .version = 3, .methods = .{ .ping = method(struct {}, void) } });
    const About = InfoOf(@TypeOf(Api));
    try testing.expectEqual(@as(usize, 0), About.errors.len);
    try testing.expect(About.mapError(error.Anything) == null);
    try testing.expectEqualStrings("ping.v3", About.label);
}

test "methods may be called name, version or errors" {
    const Api = Contract(.{
        .name = "meta",
        .version = 2,
        .methods = .{
            .name = method(GetUserRequest, User),
            .version = method(GetUserRequest, u64),
            .errors = method(GetUserRequest, []const u8),
            .@"get-all" = method(GetUserRequest, []const User),
        },
    });
    try testing.expectEqualStrings("name", @TypeOf(Api.name).route.method);
    try testing.expect(@TypeOf(Api.version).Response == u64);
    try testing.expectEqualStrings("errors", @TypeOf(Api.errors).name);
    try testing.expectEqualStrings("get-all", @TypeOf(Api.@"get-all").route.method);
    try testing.expectEqualStrings("meta", @TypeOf(Api.errors).contract.name);
}

test "only contracts pass isContract" {
    try testing.expect(isContract(@TypeOf(UserApi)));
    try testing.expect(!isContract(@TypeOf(UserApi.getUser)));
    try testing.expect(!isContract(GetUserRequest));
    try testing.expect(!isContract(@TypeOf(.{})));
    try testing.expect(!isContract(u32));
    try testing.expect(!isContract(@TypeOf(.{ .getUser = method(GetUserRequest, User) })));
}

fn expectSpecProblem(comptime spec: anytype, comptime expected: []const u8) !void {
    const found = comptime specProblem(spec);
    if (found == null) {
        std.debug.print("expected: {s}\ngot no problem\n", .{expected});
        return error.TestExpectedProblem;
    }
    try testing.expectEqualStrings(expected, found.?);
}

const get_user = method(GetUserRequest, User);

test "the shape of a contract" {
    try expectSpecProblem(42, "rpc: rpc.Contract takes .{ .name, .version, .methods, .errors }, got comptime_int");
    try expectSpecProblem(.{ "users", 1 }, "rpc: rpc.Contract takes .{ .name, .version, .methods, .errors }, got a tuple");
    try expectSpecProblem(.{ .name = "users", .version = 1, .methods = .{ .getUser = get_user }, .erors = .{} }, "rpc: contract \"users\": unknown field .erors; a contract has .name, .version, .methods and .errors");
    try expectSpecProblem(.{ .nmae = "users" }, "rpc: contract without a name: unknown field .nmae; a contract has .name, .version, .methods and .errors");
    try expectSpecProblem(.{}, "rpc: a contract needs .name, the service, such as \"users\"");
    try expectSpecProblem(.{ .name = "users" }, "rpc: contract \"users\" needs .version, the major version of the service, from 1 to 65535");
    try expectSpecProblem(.{ .name = "users", .version = 1 }, "rpc: users.v1: a contract needs .methods, such as .{ .getUser = rpc.method(GetUserRequest, User) }");
}

test "the name and the version of a contract" {
    try expectSpecProblem(.{ .name = 7 }, "rpc: contract .name must be a string such as \"users\", got comptime_int");
    try expectSpecProblem(.{ .name = "user service" }, "rpc: contract \"user service\": the name must be 1 to 64 characters from [A-Za-z0-9_-]");
    try expectSpecProblem(.{ .name = "" }, "rpc: contract \"\": the name must be 1 to 64 characters from [A-Za-z0-9_-]");
    const long: [65]u8 = @splat('a');
    try expectSpecProblem(.{ .name = &long }, "rpc: contract \"" ++ long ++ "\": the name must be 1 to 64 characters from [A-Za-z0-9_-]");
    try expectSpecProblem(.{ .name = "users", .version = 0 }, "rpc: contract \"users\": .version must be 1 to 65535, got 0");
    try expectSpecProblem(.{ .name = "users", .version = 65536 }, "rpc: contract \"users\": .version must be 1 to 65535, got 65536");
    try expectSpecProblem(.{ .name = "users", .version = "1" }, "rpc: contract \"users\": .version must be an integer from 1 to 65535, got *const [1:0]u8");
    const longest: [64]u8 = @splat('a');
    comptime std.debug.assert(specProblem(.{ .name = &longest, .version = 65535, .methods = .{ .@"A-z_09" = get_user } }) == null);
    comptime std.debug.assert(specProblem(.{ .name = "users", .version = @as(u16, 7), .methods = .{ .getUser = get_user } }) == null);
}

const Pointer = struct { next: *const GetUserRequest };

test "the methods of a contract" {
    try expectSpecProblem(.{ .name = "users", .version = 1, .methods = .{} }, "rpc: users.v1: .methods is empty; a contract has at least one method");
    try expectSpecProblem(.{ .name = "users", .version = 1, .methods = get_user }, "rpc: users.v1: .methods must be a struct literal such as .{ .getUser = rpc.method(GetUserRequest, User) }, got type");
    try expectSpecProblem(.{ .name = "users", .version = 1, .methods = .{get_user} }, "rpc: users.v1: .methods must be a struct literal such as .{ .getUser = rpc.method(GetUserRequest, User) }, got a tuple");
    try expectSpecProblem(.{ .name = "users", .version = 1, .methods = .{ .@"get.user" = get_user } }, "rpc: users.v1: the method name \"get.user\" must be 1 to 64 characters from [A-Za-z0-9_-]");
    try expectSpecProblem(.{ .name = "users", .version = 1, .methods = .{ .getUser = GetUserRequest } }, "rpc: users.v1.getUser: write rpc.method(Request, Response), got the type app.contract.GetUserRequest");
    try expectSpecProblem(.{ .name = "users", .version = 1, .methods = .{ .getUser = .{ GetUserRequest, User } } }, "rpc: users.v1.getUser: write rpc.method(Request, Response), got struct { comptime type = app.contract.GetUserRequest, comptime type = app.contract.User }");
    try expectSpecProblem(.{ .name = "users", .version = 1, .methods = .{ .getUser = method(u64, User) } }, "rpc: users.v1.getUser: request must be a struct, got u64");
    try expectSpecProblem(.{ .name = "users", .version = 1, .methods = .{ .getUser = method(void, User) } }, "rpc: users.v1.getUser: request must be a struct, got void");
    try expectSpecProblem(.{ .name = "users", .version = 1, .methods = .{ .getUser = method(Pointer, User) } }, "rpc: users.v1.getUser: request app.contract.Pointer.next has unsupported type *const app.contract.GetUserRequest");
    try expectSpecProblem(.{ .name = "users", .version = 1, .methods = .{ .getUser = method(GetUserRequest, *User) } }, "rpc: users.v1.getUser: response has unsupported type *app.contract.User");
}

fn withErrors(comptime errors: anytype) @TypeOf(.{ .name = "users", .version = 1, .methods = .{ .getUser = get_user }, .errors = errors }) {
    return .{ .name = "users", .version = 1, .methods = .{ .getUser = get_user }, .errors = errors };
}

test "the errors of a contract" {
    try expectSpecProblem(withErrors(error.UserNotFound), "rpc: users.v1: .errors must be a struct literal such as .{ .UserNotFound = .{ .code = .not_found, .app_code = \"users.not_found\", .message = \"User not found\" } }, got error{UserNotFound}");
    try expectSpecProblem(withErrors(.{.{ .code = .not_found }}), "rpc: users.v1: .errors must be a struct literal such as .{ .UserNotFound = .{ .code = .not_found, .app_code = \"users.not_found\", .message = \"User not found\" } }, got a tuple");
    try expectSpecProblem(withErrors(.{ .Unavailable = .{ .code = .unavailable, .app_code = "users.down", .message = "Down" } }), "rpc: users.v1: .errors.Unavailable: rpc maps Unavailable by itself, so a contract cannot list it; give the error another name");
    try expectSpecProblem(withErrors(.{ .RpcFailure = .{ .code = .internal, .app_code = "users.x", .message = "" } }), "rpc: users.v1: .errors.RpcFailure: rpc maps RpcFailure by itself, so a contract cannot list it; give the error another name");
    try expectSpecProblem(withErrors(.{ .UserNotFound = core.ErrorCode.not_found }), "rpc: users.v1: .errors.UserNotFound must be .{ .code, .app_code, .message }, got errors.ErrorCode");
    try expectSpecProblem(withErrors(.{ .UserNotFound = .{ .code = .not_found, .app_code = "users.not_found", .messge = "x" } }), "rpc: users.v1: .errors.UserNotFound: unknown field .messge; an error has .code, .app_code and .message");
    try expectSpecProblem(withErrors(.{ .UserNotFound = .{ .code = .not_found, .app_code = "users.not_found" } }), "rpc: users.v1: .errors.UserNotFound needs .code, .app_code and .message; .message is missing");
    try expectSpecProblem(withErrors(.{ .UserNotFound = .{ .code = .notfound, .app_code = "users.not_found", .message = "x" } }), "rpc: users.v1: .errors.UserNotFound.code must be one of core.ErrorCode, such as .not_found, got .notfound");
    try expectSpecProblem(withErrors(.{ .UserNotFound = .{ .code = 5, .app_code = "users.not_found", .message = "x" } }), "rpc: users.v1: .errors.UserNotFound.code must be one of core.ErrorCode, such as .not_found, got comptime_int");
}

test "the app code and the message of an error" {
    const long_code: [129]u8 = @splat('c');
    const longest_code: [128]u8 = @splat('c');
    const long_message: [513]u8 = @splat('m');
    const longest_message: [512]u8 = @splat('m');
    try expectSpecProblem(withErrors(.{ .UserNotFound = .{ .code = .not_found, .app_code = 404, .message = "x" } }), "rpc: users.v1: .errors.UserNotFound.app_code must be a string such as \"users.not_found\", got comptime_int");
    try expectSpecProblem(withErrors(.{ .UserNotFound = .{ .code = .not_found, .app_code = "", .message = "x" } }), "rpc: users.v1: .errors.UserNotFound.app_code is empty; write a stable code such as \"users.not_found\"");
    try expectSpecProblem(withErrors(.{ .UserNotFound = .{ .code = .not_found, .app_code = &long_code, .message = "x" } }), "rpc: users.v1: .errors.UserNotFound.app_code is 129 bytes; the limit is 128");
    try expectSpecProblem(withErrors(.{ .UserNotFound = .{ .code = .not_found, .app_code = "users.\xff", .message = "x" } }), "rpc: users.v1: .errors.UserNotFound.app_code is not valid UTF-8");
    try expectSpecProblem(withErrors(.{ .UserNotFound = .{ .code = .not_found, .app_code = "rpc.not_found", .message = "x" } }), "rpc: users.v1: .errors.UserNotFound.app_code \"rpc.not_found\" starts with \"rpc.\", which belongs to the framework");
    try expectSpecProblem(withErrors(.{ .UserNotFound = .{ .code = .not_found, .app_code = "users.not_found", .message = 1 } }), "rpc: users.v1: .errors.UserNotFound.message must be a string such as \"User not found\", got comptime_int");
    try expectSpecProblem(withErrors(.{ .UserNotFound = .{ .code = .not_found, .app_code = "users.not_found", .message = &long_message } }), "rpc: users.v1: .errors.UserNotFound.message is 513 bytes; the limit is 512");
    try expectSpecProblem(withErrors(.{ .UserNotFound = .{ .code = .not_found, .app_code = "users.not_found", .message = "\xc3" } }), "rpc: users.v1: .errors.UserNotFound.message is not valid UTF-8");
    try expectSpecProblem(withErrors(.{
        .UserNotFound = .{ .code = .not_found, .app_code = "users.not_found", .message = "x" },
        .EmailTaken = .{ .code = .already_exists, .app_code = "users.email_taken", .message = "y" },
        .NoUser = .{ .code = .not_found, .app_code = "users.not_found", .message = "z" },
    }), "rpc: users.v1: .errors.UserNotFound and .errors.NoUser share .app_code \"users.not_found\"; each error needs its own");
    comptime std.debug.assert(specProblem(withErrors(.{
        .UserNotFound = .{ .code = .not_found, .app_code = &longest_code, .message = &longest_message },
        .Gone = .{ .code = .unavailable, .app_code = "users.gone", .message = "" },
        .Unicode = .{ .code = .aborted, .app_code = "users.é", .message = "Ошибка" },
    })) == null);
    comptime std.debug.assert(specProblem(withErrors(.{})) == null);
}

fn audit() void {}
fn trace() void {}

test "implement keeps the contract, the defaults and the settings as written" {
    const Impl = implement(UserApi, .{
        .defaults = .{ .timeout_ms = 5000, .auth = .required },
        .middleware = .{audit},
        .methods = .{
            .getUser = .{ .auth = .optional },
            .deleteUser = .{ .timeout_ms = 100, .middleware = .{ trace, .fraud } },
        },
    });
    try testing.expect(Impl.is_rpc_implementation);
    try testing.expect(@TypeOf(Impl.api) == @TypeOf(UserApi));
    try testing.expectEqual(MethodSettings{ .timeout_ms = 5000, .auth = .required }, Impl.defaults);
    try testing.expectEqual(MethodSettings{ .timeout_ms = 5000, .auth = .optional }, Impl.settingsOf("getUser"));
    try testing.expectEqual(MethodSettings{ .timeout_ms = 100, .auth = .required }, Impl.settingsOf("deleteUser"));
    try testing.expectEqual(@as(usize, 1), Impl.middleware.len);
    try testing.expect(Impl.middleware[0] == audit);
    try testing.expect(Impl.methods.deleteUser.middleware[0] == trace);
    try testing.expect(Impl.methods.deleteUser.middleware[1] == .fraud);
}

test "implement without settings gives 3000 ms and optional auth to every method" {
    const Impl = implement(UserApi, .{});
    try testing.expectEqual(MethodSettings{ .timeout_ms = 3000, .auth = .optional }, Impl.defaults);
    try testing.expectEqual(Impl.defaults, Impl.settingsOf("getUser"));
    try testing.expectEqual(@as(usize, 0), Impl.middleware.len);
    try testing.expectEqual(@as(usize, 0), @typeInfo(@TypeOf(Impl.methods)).@"struct".field_names.len);
    const Typed = implement(UserApi, .{ .defaults = .{ .auth = Auth.required, .timeout_ms = @as(u32, 300_000) } });
    try testing.expectEqual(MethodSettings{ .timeout_ms = 300_000, .auth = .required }, Typed.defaults);
    const Shortest = implement(UserApi, .{ .methods = .{ .getUser = .{ .timeout_ms = 1 } } });
    try testing.expectEqual(@as(u32, 1), Shortest.settingsOf("getUser").timeout_ms);
}

fn expectSettingsProblem(comptime settings: anytype, comptime expected: []const u8) !void {
    const found = comptime settingsProblem("users.v1", settings);
    if (found == null) {
        std.debug.print("expected: {s}\ngot no problem\n", .{expected});
        return error.TestExpectedProblem;
    }
    try testing.expectEqualStrings(expected, found.?);
}

test "the settings of implement" {
    try expectSettingsProblem(3000, "rpc.implement(users.v1): settings must be a struct literal .{ .defaults, .middleware, .methods }, got comptime_int");
    try expectSettingsProblem(.{.{}}, "rpc.implement(users.v1): settings must be a struct literal .{ .defaults, .middleware, .methods }, got a tuple");
    try expectSettingsProblem(.{ .default = .{} }, "rpc.implement(users.v1): unknown setting .default; the settings are .defaults, .middleware and .methods");
    try expectSettingsProblem(.{ .defaults = 5 }, "rpc.implement(users.v1): .defaults must be a struct literal such as .{ .timeout_ms = 5000, .auth = .required }, got comptime_int");
    try expectSettingsProblem(.{ .defaults = .{ .timeout = 5 } }, "rpc.implement(users.v1): unknown setting .defaults.timeout; .defaults has .timeout_ms and .auth");
    try expectSettingsProblem(.{ .defaults = .{ .middleware = .{} } }, "rpc.implement(users.v1): unknown setting .defaults.middleware; .defaults has .timeout_ms and .auth");
    try expectSettingsProblem(.{ .middleware = audit }, "rpc.implement(users.v1): .middleware must be a tuple such as .{ mw.audit }, got fn () void");
    try expectSettingsProblem(.{ .methods = .{.{}} }, "rpc.implement(users.v1): .methods must be a struct literal such as .{ .getUser = .{ .auth = .optional } }, got a tuple");
    try expectSettingsProblem(.{ .methods = .{ .getUser = .optional } }, "rpc.implement(users.v1): .methods.getUser must be a struct literal such as .{ .timeout_ms = 5000, .auth = .required }, got @EnumLiteral()");
    try expectSettingsProblem(.{ .methods = .{ .getUser = .{ .timeot_ms = 5 } } }, "rpc.implement(users.v1): unknown setting .methods.getUser.timeot_ms; a method has .timeout_ms, .auth and .middleware");
    try expectSettingsProblem(.{ .methods = .{ .getUser = .{ .middleware = audit } } }, "rpc.implement(users.v1): .methods.getUser.middleware must be a tuple such as .{ mw.audit }, got fn () void");
}

test "the timeout and the auth of implement" {
    try expectSettingsProblem(.{ .defaults = .{ .timeout_ms = 0 } }, "rpc.implement(users.v1): .defaults.timeout_ms must be 1 to 300000 ms, got 0");
    try expectSettingsProblem(.{ .defaults = .{ .timeout_ms = -5 } }, "rpc.implement(users.v1): .defaults.timeout_ms must be 1 to 300000 ms, got -5");
    try expectSettingsProblem(.{ .methods = .{ .getUser = .{ .timeout_ms = 300_001 } } }, "rpc.implement(users.v1): .methods.getUser.timeout_ms must be 1 to 300000 ms, got 300001");
    try expectSettingsProblem(.{ .defaults = .{ .timeout_ms = 1.5 } }, "rpc.implement(users.v1): .defaults.timeout_ms must be 1 to 300000 ms, got comptime_float");
    try expectSettingsProblem(.{ .defaults = .{ .auth = .maybe } }, "rpc.implement(users.v1): .defaults.auth must be .required or .optional, got .maybe");
    try expectSettingsProblem(.{ .methods = .{ .getUser = .{ .auth = true } } }, "rpc.implement(users.v1): .methods.getUser.auth must be .required or .optional, got bool");
}
