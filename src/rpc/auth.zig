//! Authentication: who calls. The authenticator of the application checks
//! the credentials of a call and returns an identity; the engine runs it in
//! the handler's task before middleware, the same way on every transport.
//! Permissions are not checked here: that is middleware of the application,
//! such as `requirePermission` in the guide.

const std = @import("std");
const core = @import("core");
const model = @import("model.zig");
const failures = @import("failures.zig");
const signature = @import("signature.zig");
const credentials = @import("credentials.zig");
const Credentials = credentials.Credentials;
const engine_context = @import("engine/Context.zig");
const Context = engine_context.Context;

const log = std.log.scoped(.rpc);

/// Checks the credentials of calls. Hand `rpc.Authenticator.init(&impl)` to
/// the server; `impl` has the method
///
/// ```zig
/// pub fn authenticate(self: *@This(), ctx: *const rpc.AuthContext) rpc.AuthError!?rpc.IdentityView
/// ```
///
/// It returns the identity of the caller, or null for an anonymous call (no
/// credentials). Wrong credentials are `error.InvalidCredentials`, also on a
/// method where authentication is optional: they never pass as anonymous.
/// It runs in the handler's task under its deadline: wait only through
/// `ctx.io()`, and return `error.Canceled` as it is.
pub const Authenticator = struct {
    ptr: *anyopaque,
    authenticate: *const fn (ptr: *anyopaque, ctx: *const AuthContext) AuthError!?IdentityView,

    const interface = "rpc.Authenticator";

    /// The authenticator of `impl: *T`. A missing method or another
    /// signature stops the build with a message that names the signature to
    /// write.
    pub fn init(impl: anytype) Authenticator {
        const Ptr = @TypeOf(impl);
        const T = signature.expectPointer(interface, "authenticator", Ptr);
        comptime signature.expectMethod(interface, T, "authenticate", fn (Ptr, *const AuthContext) AuthError!?IdentityView, "pub fn authenticate(self: *@This(), ctx: *const rpc.AuthContext) rpc.AuthError!?rpc.IdentityView");
        const gen = struct {
            fn authenticate(ptr: *anyopaque, ctx: *const AuthContext) AuthError!?IdentityView {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                return T.authenticate(self, ctx);
            }
        };
        return .{ .ptr = impl, .authenticate = gen.authenticate };
    }
};

/// What an authenticator may return besides an identity:
/// `InvalidCredentials` → `unauthenticated`; `Unavailable` (the store of
/// tokens or sessions is down) → `unavailable`; `OutOfMemory` →
/// `resource_exhausted`; `Canceled`, `Cancelled` and `DeadlineExceeded` end
/// the call as the engine decided.
pub const AuthError = error{ InvalidCredentials, Unavailable, OutOfMemory } || std.Io.Cancelable || core.ContextError;

/// What an authenticator sees of a call.
pub const AuthContext = struct {
    /// What the caller sent in `authorization`, parsed by the engine:
    /// `.none` without the key, `.bearer`, `.basic`, or `.custom` with the
    /// value as it is. Never `.provider`.
    credentials: Credentials,
    /// The call; read it through the methods below.
    call: *Context,

    /// The `std.Io` of the server: every wait goes through it.
    pub fn io(ctx: *const AuthContext) std.Io {
        return ctx.call.io();
    }

    /// The deadline, the token and the trace of the call.
    pub fn operation(ctx: *const AuthContext) core.Context {
        return ctx.call.operation();
    }

    /// The arena of the call: the strings of the identity may live here.
    pub fn allocator(ctx: *const AuthContext) std.mem.Allocator {
        return ctx.call.allocator();
    }

    /// The request's metadata without the reserved keys.
    pub fn metadata(ctx: *const AuthContext) model.Metadata.View {
        return ctx.call.metadata();
    }

    /// The service, version and method of the call.
    pub fn route(ctx: *const AuthContext) model.Route {
        return ctx.call.route();
    }
};

/// The identity of a caller. Its strings live in the arena of the call
/// (`AuthContext.allocator()`) or are constant. The engine checks it before
/// anyone sees it: over the limits below → `resource_exhausted`; an empty
/// or non-UTF-8 string → `internal`, a bug of the authenticator.
pub const IdentityView = struct {
    /// Who calls: a user, a service.
    subject: []const u8,
    /// The tenant the authenticator verified; null outside multi-tenant
    /// services. A tenant in the request's metadata is not verified: compare
    /// it with this one.
    tenant_id: ?[]const u8 = null,
    roles: []const []const u8 = &.{},
    permissions: []const []const u8 = &.{},

    /// The limits, as in rpc 1.6.
    pub const max_subject_bytes = 256;
    pub const max_tenant_bytes = 256;
    pub const max_roles = 64;
    pub const max_permissions = 256;
    /// Of one role or permission.
    pub const max_name_bytes = 128;

    /// Whether the identity holds `permission`, exactly: no wildcards.
    pub fn hasPermission(identity: IdentityView, permission: []const u8) bool {
        for (identity.permissions) |held| {
            if (std.mem.eql(u8, held, permission)) return true;
        }
        return false;
    }
};

/// What is wrong with an identity.
const Problem = enum { too_large, malformed };

fn checkIdentity(identity: IdentityView) ?Problem {
    const V = IdentityView;
    if (identity.roles.len > V.max_roles or identity.permissions.len > V.max_permissions) return .too_large;
    if (identity.subject.len > V.max_subject_bytes) return .too_large;
    if (identity.tenant_id) |tenant| if (tenant.len > V.max_tenant_bytes) return .too_large;
    for (identity.roles) |role| if (role.len > V.max_name_bytes) return .too_large;
    for (identity.permissions) |permission| if (permission.len > V.max_name_bytes) return .too_large;
    if (!isText(identity.subject)) return .malformed;
    if (identity.tenant_id) |tenant| if (!isText(tenant)) return .malformed;
    for (identity.roles) |role| if (!isText(role)) return .malformed;
    for (identity.permissions) |permission| if (!isText(permission)) return .malformed;
    return null;
}

fn isText(s: []const u8) bool {
    return s.len > 0 and std.unicode.utf8ValidateSlice(s);
}

/// Authenticates one call before its middleware: parses `authorization`,
/// asks the authenticator, checks the identity and keeps it for
/// `ctx.identity()`. A refusal is the exact failure of the call
/// (`error.RpcFailure`); a cancelation of the handler's task comes back as
/// `error.Canceled`. Without an authenticator, a call with credentials is
/// refused: credentials nobody checks are not ignored. Internal to the
/// module.
pub fn authenticate(ctx: *Context, authenticator: ?Authenticator, required: bool) error{ RpcFailure, Canceled }!void {
    const call = engine_context.callOf(ctx);
    const parsed = parsed: {
        // A Debug allocator may take a cancelable lock.
        const protection = call.io.swapCancelProtection(.blocked);
        defer _ = call.io.swapCancelProtection(protection);
        break :parsed credentials.parse(call.arena, call.authorization) catch
            return refuse(ctx, failures.resource_exhausted);
    };
    // The call wipes what was decoded before it frees its arena.
    call.credentials = parsed;
    const checker = authenticator orelse {
        if (parsed != .none) return refuse(ctx, failures.invalid_credentials);
        if (required) return refuse(ctx, failures.authentication_required);
        return;
    };
    const auth_context: AuthContext = .{ .credentials = parsed, .call = ctx };
    const found = checker.authenticate(checker.ptr, &auth_context) catch |err| return switch (err) {
        error.InvalidCredentials => refuse(ctx, failures.invalid_credentials),
        error.Unavailable => refuse(ctx, failures.unavailable),
        error.OutOfMemory => refuse(ctx, failures.resource_exhausted),
        error.Cancelled => refuse(ctx, failures.cancelled),
        error.DeadlineExceeded => refuse(ctx, failures.deadline_exceeded),
        error.Canceled => error.Canceled,
    };
    const identity = found orelse {
        if (required) return refuse(ctx, failures.authentication_required);
        return;
    };
    if (checkIdentity(identity)) |problem| switch (problem) {
        .too_large => return refuse(ctx, failures.identity_too_large),
        .malformed => {
            const r = call.route;
            log.warn("the authenticator returned an identity with an empty or non-UTF-8 string for {s}.v{d}.{s}", .{ r.service, r.version, r.method });
            return refuse(ctx, failures.internal);
        },
    };
    call.identity = identity;
}

fn refuse(ctx: *Context, failure: model.Failure) error{RpcFailure} {
    return engine_context.failWithBody(ctx, failure, "");
}

const testing = std.testing;

test "hasPermission matches exactly" {
    const identity: IdentityView = .{ .subject = "u-1", .permissions = &.{ "users.read", "users.delete" } };
    try testing.expect(identity.hasPermission("users.read"));
    try testing.expect(identity.hasPermission("users.delete"));
    try testing.expect(!identity.hasPermission("users"));
    try testing.expect(!identity.hasPermission("users.*"));
    try testing.expect(!identity.hasPermission("Users.read"));
    try testing.expect(!(IdentityView{ .subject = "u-1" }).hasPermission("users.read"));
}

test "an identity within the limits passes; over them it is too large; an empty or non-UTF-8 string is malformed" {
    const subject256: [256]u8 = @splat('s');
    const subject257: [257]u8 = @splat('s');
    const name128: [128]u8 = @splat('n');
    const name129: [129]u8 = @splat('n');
    const roles64: [64][]const u8 = @splat("role");
    const roles65: [65][]const u8 = @splat("role");
    const permissions256: [256][]const u8 = @splat("p");
    const permissions257: [257][]const u8 = @splat("p");

    for ([_]IdentityView{
        .{ .subject = "u-1" },
        .{ .subject = &subject256, .tenant_id = &subject256, .roles = &roles64, .permissions = &permissions256 },
        .{ .subject = "ü", .roles = &.{&name128}, .permissions = &.{&name128} },
    }) |identity| try testing.expectEqual(@as(?Problem, null), checkIdentity(identity));

    for ([_]IdentityView{
        .{ .subject = &subject257 },
        .{ .subject = "u", .tenant_id = &subject257 },
        .{ .subject = "u", .roles = &roles65 },
        .{ .subject = "u", .permissions = &permissions257 },
        .{ .subject = "u", .roles = &.{&name129} },
        .{ .subject = "u", .permissions = &.{&name129} },
        // Over the limits and malformed: too large.
        .{ .subject = "", .roles = &roles65 },
    }) |identity| try testing.expectEqual(@as(?Problem, .too_large), checkIdentity(identity));

    for ([_]IdentityView{
        .{ .subject = "" },
        .{ .subject = "\xff" },
        .{ .subject = "u", .tenant_id = "" },
        .{ .subject = "u", .tenant_id = "\xc3" },
        .{ .subject = "u", .roles = &.{""} },
        .{ .subject = "u", .permissions = &.{ "p", "\xfe" } },
    }) |identity| try testing.expectEqual(@as(?Problem, .malformed), checkIdentity(identity));
}

/// Knows one token.
const OneToken = struct {
    calls: u32 = 0,

    pub fn authenticate(self: *OneToken, ctx: *const AuthContext) AuthError!?IdentityView {
        self.calls += 1;
        return switch (ctx.credentials) {
            .none => null,
            .bearer => |token| if (std.mem.eql(u8, token, "good")) .{ .subject = "u-1" } else error.InvalidCredentials,
            else => error.InvalidCredentials,
        };
    }
};

test "init builds an authenticator whose calls reach the method" {
    var impl: OneToken = .{};
    const authenticator: Authenticator = .init(&impl);
    // The engine's AuthContext needs a call; the method only reads the
    // credentials here.
    const anonymous: AuthContext = .{ .credentials = .none, .call = undefined };
    try testing.expectEqual(@as(?IdentityView, null), try authenticator.authenticate(authenticator.ptr, &anonymous));
    const good: AuthContext = .{ .credentials = .{ .bearer = "good" }, .call = undefined };
    try testing.expectEqualStrings("u-1", (try authenticator.authenticate(authenticator.ptr, &good)).?.subject);
    const bad: AuthContext = .{ .credentials = .{ .custom = "x" }, .call = undefined };
    try testing.expectError(error.InvalidCredentials, authenticator.authenticate(authenticator.ptr, &bad));
    try testing.expectEqual(@as(u32, 3), impl.calls);
}
