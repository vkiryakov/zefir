//! The options of `rpc.Client.init`: their compile-time checks, and how the
//! credentials and the middleware written as literals become the engine's
//! values. Each check returns the message of the first problem it finds,
//! or null; `rpc.Client.init` stops the build with it. Internal to the
//! module.

const std = @import("std");
const ClientTransport = @import("../ClientTransport.zig");
const credentials = @import("../credentials.zig");
const Credentials = credentials.Credentials;
const CredentialsProvider = credentials.CredentialsProvider;
const middleware = @import("../middleware.zig");
const ClientMiddleware = middleware.ClientMiddleware;
const ClientMiddlewareFn = middleware.ClientMiddlewareFn;
const ClientNext = middleware.ClientNext;
const ClientContext = @import("../engine/RawClient.zig").ClientContext;
const handlers = @import("handlers.zig");

const at = "rpc.Client.init: ";
const options_list = ".transport, .credentials, .middleware, .default_timeout, .max_pending and .max_response_bytes";
const kinds_list = ".none, .bearer, .basic, .provider and .custom";
const link_function = "fn (*rpc.ClientContext, *rpc.ClientNext) anyerror!void";
const link_method = "pub fn run(self, *rpc.ClientContext, *rpc.ClientNext) anyerror!void";

/// The compile error for the options of `rpc.Client.init`, of type `O`, or
/// null. A credentials literal such as `.bearer` written alone is checked
/// by `literalProblem`, where its value is known.
pub fn optionsProblem(comptime O: type) ?[]const u8 {
    const shape = "options must be a struct literal such as .{ .transport = memory.clientTransport() }, got ";
    const info = switch (@typeInfo(O)) {
        .@"struct" => |info| info,
        else => return at ++ shape ++ @typeName(O),
    };
    if (info.is_tuple and info.field_names.len > 0) return at ++ shape ++ "a tuple";
    for (info.field_names) |name| {
        if (!isOneOf(name, &.{ "transport", "credentials", "middleware", "default_timeout", "max_pending", "max_response_bytes" }))
            return at ++ "unknown option ." ++ name ++ "; the options are " ++ options_list;
    }
    if (!@hasField(O, "transport")) return at ++ ".transport is missing; pass the client side of a transport, such as memory.clientTransport()";
    if (@FieldType(O, "transport") != ClientTransport)
        return at ++ ".transport must be an rpc.ClientTransport, such as memory.clientTransport(); got " ++ @typeName(@FieldType(O, "transport"));
    if (@hasField(O, "credentials")) {
        if (credentialsProblem(@FieldType(O, "credentials"))) |found| return found;
    }
    if (@hasField(O, "middleware")) {
        if (linksProblem(@FieldType(O, "middleware"))) |found| return found;
    }
    if (@hasField(O, "default_timeout")) {
        if (@FieldType(O, "default_timeout") != std.Io.Duration)
            return at ++ ".default_timeout must be a std.Io.Duration, such as std.Io.Duration.fromSeconds(3); got " ++ @typeName(@FieldType(O, "default_timeout"));
        if (comptimeValue(O, "default_timeout")) |timeout| {
            if (timeout.nanoseconds <= 0) return at ++ ".default_timeout must be above zero, such as std.Io.Duration.fromSeconds(3)";
        }
    }
    if (@hasField(O, "max_pending")) {
        if (!coercesTo(@FieldType(O, "max_pending"), u32))
            return at ++ ".max_pending must be a u32, such as 1024; got " ++ @typeName(@FieldType(O, "max_pending"));
        if (rangeProblem(O, "max_pending", u32)) |found| return found;
    }
    if (@hasField(O, "max_response_bytes")) {
        if (!coercesTo(@FieldType(O, "max_response_bytes"), usize))
            return at ++ ".max_response_bytes must be a usize, such as 1 << 20; got " ++ @typeName(@FieldType(O, "max_response_bytes"));
        if (rangeProblem(O, "max_response_bytes", usize)) |found| return found;
    }
    return null;
}

/// The value of the field `name` of `O` when it is known at compile time,
/// as a literal makes it; null for a value known only at run time.
fn comptimeValue(comptime O: type, comptime name: []const u8) ?@FieldType(O, name) {
    const info = @typeInfo(O).@"struct";
    for (info.field_names, info.field_attrs) |field, attrs| {
        if (!std.mem.eql(u8, field, name)) continue;
        if (!attrs.@"comptime") return null;
        return attrs.defaultValue(@FieldType(O, name));
    }
    return null;
}

/// The problem of a limit known at compile time that is not 1 to the
/// largest `Target`: zero would refuse every call, and a larger literal
/// would not fit.
fn rangeProblem(comptime O: type, comptime name: []const u8, comptime Target: type) ?[]const u8 {
    const value = comptimeValue(O, name) orelse return null;
    if (value >= 1 and value <= std.math.maxInt(Target)) return null;
    return std.fmt.comptimePrint("{s}.{s} must be 1 to {d}; got {d}", .{ at, name, std.math.maxInt(Target), value });
}

/// `.credentials` is `rpc.Credentials`, a literal such as `.none`, or a
/// struct literal of one kind with its value: `.{ .bearer = token }`,
/// `.{ .basic = .{ .user = "svc", .password = secret } }`,
/// `.{ .provider = oauth.credentialsProvider() }`, `.{ .custom = value }`.
fn credentialsProblem(comptime T: type) ?[]const u8 {
    if (T == Credentials or T == @TypeOf(.enum_literal)) return null;
    const shape = at ++ ".credentials must be rpc.Credentials, such as .{ .bearer = token } or .none; got " ++ @typeName(T);
    const info = switch (@typeInfo(T)) {
        .@"struct" => |info| info,
        else => return shape,
    };
    if (info.is_tuple or info.field_names.len != 1) return shape;
    const kind = info.field_names[0];
    const Value = info.field_types[0];
    if (isOneOf(kind, &.{ "bearer", "custom" })) {
        if (!isString(Value)) return at ++ ".credentials." ++ kind ++ " must be a string; got " ++ @typeName(Value);
    } else if (std.mem.eql(u8, kind, "basic")) {
        if (Value != Credentials.Basic and !isBasicLiteral(Value))
            return at ++ ".credentials.basic must be .{ .user = ..., .password = ... } with strings; got " ++ @typeName(Value);
    } else if (std.mem.eql(u8, kind, "provider")) {
        if (Value != CredentialsProvider)
            return at ++ ".credentials.provider must be an rpc.CredentialsProvider, such as oauth.credentialsProvider(); got " ++ @typeName(Value);
    } else return at ++ ".credentials has no kind ." ++ kind ++ "; the kinds are " ++ kinds_list;
    return null;
}

/// The problem of `.credentials` written as a lone literal: only `.none`
/// has no value.
pub fn literalProblem(comptime literal: @TypeOf(.enum_literal)) ?[]const u8 {
    const kind = @tagName(literal);
    if (std.mem.eql(u8, kind, "none")) return null;
    if (isOneOf(kind, &.{ "bearer", "basic", "provider", "custom" }))
        return at ++ ".credentials = ." ++ kind ++ " needs a value, such as .{ .bearer = token }; only .none stands alone";
    return at ++ ".credentials has no kind ." ++ kind ++ "; the kinds are " ++ kinds_list;
}

/// The credentials that `given`, the value of `.credentials`, stands for;
/// its type passed `credentialsProblem` and, for a lone literal,
/// `literalProblem`.
pub fn credentialsOf(given: anytype) Credentials {
    const T = @TypeOf(given);
    if (T == Credentials) return given;
    if (T == @TypeOf(.enum_literal)) return .none;
    const kind = @typeInfo(T).@"struct".field_names[0];
    const value = @field(given, kind);
    if (comptime std.mem.eql(u8, kind, "basic")) {
        if (@TypeOf(value) == Credentials.Basic) return .{ .basic = value };
        return .{ .basic = .{ .user = value.user, .password = value.password } };
    }
    return @unionInit(Credentials, kind, value);
}

/// The links of `.middleware`, a tuple whose type passed `linksProblem`, in
/// `buffer`, one for each item.
pub fn linksOf(links: anytype, buffer: []ClientMiddleware) []const ClientMiddleware {
    const names = @typeInfo(@TypeOf(links)).@"struct".field_names;
    inline for (names, 0..) |name, i| buffer[i] = .of(@field(links, name));
    return buffer[0..names.len];
}

/// The problem of the links of a client, a value of type `L`: middleware
/// functions and pointers to objects.
fn linksProblem(comptime L: type) ?[]const u8 {
    const shape = ".middleware must be a tuple such as .{ clientMetrics, &breaker }; got ";
    const info = switch (@typeInfo(L)) {
        .@"struct" => |info| info,
        else => return at ++ shape ++ @typeName(L),
    };
    if (!info.is_tuple and info.field_names.len > 0) return at ++ shape ++ @typeName(L);
    inline for (info.field_types, 0..) |Item, i| {
        if (@typeInfo(Item) == .@"fn" and Item != ClientMiddlewareFn)
            return std.fmt.comptimePrint("{s}.middleware[{d}] must be " ++ link_function ++ ", with anyerror written out, not inferred; got {s}", .{ at, i, handlers.typeName(Item) });
        const fits = Item == ClientMiddlewareFn or switch (@typeInfo(Item)) {
            .pointer => |pointer| pointer.size == .one and !pointer.attrs.@"const" and hasRun(pointer.child),
            else => false,
        };
        if (!fits) return std.fmt.comptimePrint("{s}.middleware[{d}] must be " ++ link_function ++ " or a pointer to a type with " ++ link_method, .{ at, i });
    }
    return null;
}

/// Whether `X` has `pub fn run(self: *X, ctx: *rpc.ClientContext, next: *rpc.ClientNext) anyerror!void`.
fn hasRun(comptime X: type) bool {
    switch (@typeInfo(X)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return false,
    }
    if (!@hasDecl(X, "run")) return false;
    return @TypeOf(X.run) == fn (*X, *ClientContext, *ClientNext) anyerror!void;
}

/// Whether a value of type `T` coerces to `Target`, an unsigned integer
/// type: a literal, or an unsigned integer no wider.
fn coercesTo(comptime T: type, comptime Target: type) bool {
    if (T == comptime_int) return true;
    const from = switch (@typeInfo(T)) {
        .int => |info| info,
        else => return false,
    };
    return from.signedness == .unsigned and from.bits <= @typeInfo(Target).int.bits;
}

/// Whether a value of type `T` coerces to `[]const u8`: a slice of bytes or
/// a pointer to an array of them, such as a string literal.
fn isString(comptime T: type) bool {
    const pointer = switch (@typeInfo(T)) {
        .pointer => |pointer| pointer,
        else => return false,
    };
    return switch (pointer.size) {
        .slice => pointer.child == u8,
        .one => switch (@typeInfo(pointer.child)) {
            .array => |array| array.child == u8,
            else => false,
        },
        else => false,
    };
}

/// Whether `T` is a struct literal `.{ .user = ..., .password = ... }` of
/// two strings.
fn isBasicLiteral(comptime T: type) bool {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |info| info,
        else => return false,
    };
    if (info.is_tuple or info.field_names.len != 2) return false;
    if (!@hasField(T, "user") or !@hasField(T, "password")) return false;
    return isString(@FieldType(T, "user")) and isString(@FieldType(T, "password"));
}

fn isOneOf(comptime name: []const u8, comptime names: []const []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

const testing = std.testing;

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

/// The options of a client with these more fields besides the transport.
fn With(comptime name: [:0]const u8, comptime T: type) type {
    return @Struct(.auto, null, &.{ "transport", name }, &.{ ClientTransport, T }, &@splat(.{}));
}

fn countCalls(ctx: *ClientContext, next: *ClientNext) anyerror!void {
    _ = ctx;
    return next.run();
}

fn inferredLink(ctx: *ClientContext, next: *ClientNext) !void {
    _ = ctx;
    return next.run();
}

const Breaker = struct {
    pub fn run(self: *Breaker, ctx: *ClientContext, next: *ClientNext) anyerror!void {
        _ = self;
        _ = ctx;
        return next.run();
    }
};

/// A middleware object of the server, not of the client.
const ServerSide = struct {
    pub fn run(self: *ServerSide, ctx: *@import("../engine/Context.zig").Context, next: *middleware.Next) anyerror!void {
        _ = self;
        _ = ctx;
        return next.run();
    }
};

test "good options pass" {
    try expectNoProblem(struct { transport: ClientTransport });
    try expectNoProblem(struct {
        transport: ClientTransport,
        credentials: Credentials,
        middleware: struct { @TypeOf(countCalls), *Breaker },
        default_timeout: std.Io.Duration,
        max_pending: comptime_int,
        max_response_bytes: usize,
    });
    try expectNoProblem(With("max_pending", u16));
    try expectNoProblem(With("max_pending", u32));
    try expectNoProblem(With("middleware", @TypeOf(.{})));
}

test "the shape of the options" {
    try expectProblem(u32, "rpc.Client.init: options must be a struct literal such as .{ .transport = memory.clientTransport() }, got u32");
    try expectProblem(struct { ClientTransport }, "rpc.Client.init: options must be a struct literal such as .{ .transport = memory.clientTransport() }, got a tuple");
    try expectProblem(With("timeout", std.Io.Duration), "rpc.Client.init: unknown option .timeout; the options are .transport, .credentials, .middleware, .default_timeout, .max_pending and .max_response_bytes");
    try expectProblem(struct { max_pending: u32 }, "rpc.Client.init: .transport is missing; pass the client side of a transport, such as memory.clientTransport()");
    try expectProblem(struct { transport: *u8 }, "rpc.Client.init: .transport must be an rpc.ClientTransport, such as memory.clientTransport(); got *u8");
    try expectProblem(With("default_timeout", comptime_int), "rpc.Client.init: .default_timeout must be a std.Io.Duration, such as std.Io.Duration.fromSeconds(3); got comptime_int");
    try expectProblem(With("default_timeout", @TypeOf(.enum_literal)), "rpc.Client.init: .default_timeout must be a std.Io.Duration, such as std.Io.Duration.fromSeconds(3); got @EnumLiteral()");
    try expectProblem(With("max_pending", u64), "rpc.Client.init: .max_pending must be a u32, such as 1024; got u64");
    try expectProblem(With("max_pending", i32), "rpc.Client.init: .max_pending must be a u32, such as 1024; got i32");
    try expectProblem(With("max_response_bytes", f64), "rpc.Client.init: .max_response_bytes must be a usize, such as 1 << 20; got f64");
}

const TwoKinds = struct { bearer: []const u8, custom: []const u8 };
const UserOnly = struct { user: []const u8 };

/// The options of a client with one more field besides the transport,
/// `name`, known at compile time: `value`, as a literal makes it.
fn WithValue(comptime name: [:0]const u8, comptime value: anytype) type {
    const T = @TypeOf(value);
    const stored: T = value;
    return @Struct(.auto, null, &.{ "transport", name }, &.{ ClientTransport, T }, &.{ .{}, .{ .@"comptime" = true, .default_value_ptr = &stored } });
}

test "limits known at compile time are above zero and fit their types" {
    const zero_timeout: std.Io.Duration = .zero;
    try expectNoProblem(WithValue("max_pending", 1));
    try expectNoProblem(WithValue("max_pending", std.math.maxInt(u32)));
    try expectNoProblem(WithValue("max_response_bytes", 1));
    try expectNoProblem(WithValue("default_timeout", std.Io.Duration.fromMilliseconds(1)));
    try expectProblem(WithValue("max_pending", 0), "rpc.Client.init: .max_pending must be 1 to 4294967295; got 0");
    try expectProblem(WithValue("max_pending", -1), "rpc.Client.init: .max_pending must be 1 to 4294967295; got -1");
    try expectProblem(WithValue("max_pending", 1 << 32), "rpc.Client.init: .max_pending must be 1 to 4294967295; got 4294967296");
    try expectProblem(WithValue("max_pending", @as(u32, 0)), "rpc.Client.init: .max_pending must be 1 to 4294967295; got 0");
    const bytes_range = std.fmt.comptimePrint("1 to {d}", .{std.math.maxInt(usize)});
    try expectProblem(WithValue("max_response_bytes", 0), "rpc.Client.init: .max_response_bytes must be " ++ bytes_range ++ "; got 0");
    try expectProblem(WithValue("max_response_bytes", std.math.maxInt(usize) + 1), std.fmt.comptimePrint("rpc.Client.init: .max_response_bytes must be {s}; got {d}", .{ bytes_range, std.math.maxInt(usize) + 1 }));
    try expectProblem(WithValue("default_timeout", zero_timeout), "rpc.Client.init: .default_timeout must be above zero, such as std.Io.Duration.fromSeconds(3)");
    try expectProblem(WithValue("default_timeout", std.Io.Duration.fromMilliseconds(-5)), "rpc.Client.init: .default_timeout must be above zero, such as std.Io.Duration.fromSeconds(3)");
}

test "credentials are rpc.Credentials or a literal of one kind" {
    try expectNoProblem(With("credentials", Credentials));
    try expectNoProblem(With("credentials", @TypeOf(.enum_literal)));
    try expectNoProblem(With("credentials", struct { bearer: *const [5:0]u8 }));
    try expectNoProblem(With("credentials", struct { bearer: []const u8 }));
    try expectNoProblem(With("credentials", struct { custom: []u8 }));
    try expectNoProblem(With("credentials", struct { basic: struct { user: *const [3:0]u8, password: []const u8 } }));
    try expectNoProblem(With("credentials", struct { basic: Credentials.Basic }));
    try expectNoProblem(With("credentials", struct { provider: CredentialsProvider }));
    try expectProblem(With("credentials", u8), "rpc.Client.init: .credentials must be rpc.Credentials, such as .{ .bearer = token } or .none; got u8");
    try expectProblem(With("credentials", TwoKinds), "rpc.Client.init: .credentials must be rpc.Credentials, such as .{ .bearer = token } or .none; got app.client_options.TwoKinds");
    try expectProblem(With("credentials", struct { token: []const u8 }), "rpc.Client.init: .credentials has no kind .token; the kinds are .none, .bearer, .basic, .provider and .custom");
    try expectProblem(With("credentials", struct { bearer: u64 }), "rpc.Client.init: .credentials.bearer must be a string; got u64");
    try expectProblem(With("credentials", struct { custom: []const u16 }), "rpc.Client.init: .credentials.custom must be a string; got []const u16");
    try expectProblem(With("credentials", struct { basic: UserOnly }), "rpc.Client.init: .credentials.basic must be .{ .user = ..., .password = ... } with strings; got app.client_options.UserOnly");
    try expectProblem(With("credentials", struct { provider: *CredentialsProvider }), "rpc.Client.init: .credentials.provider must be an rpc.CredentialsProvider, such as oauth.credentialsProvider(); got *credentials.CredentialsProvider");
}

test "a lone credentials literal is only .none" {
    try testing.expectEqual(@as(?[]const u8, null), comptime literalProblem(.none));
    try testing.expectEqualStrings("rpc.Client.init: .credentials = .bearer needs a value, such as .{ .bearer = token }; only .none stands alone", comptime literalProblem(.bearer).?);
    try testing.expectEqualStrings("rpc.Client.init: .credentials has no kind .anonymous; the kinds are .none, .bearer, .basic, .provider and .custom", comptime literalProblem(.anonymous).?);
}

test "credentials literals become rpc.Credentials" {
    var token: []const u8 = "t-1";
    _ = &token;
    try testing.expect(credentialsOf(.none) == .none);
    try testing.expectEqualStrings("t-1", credentialsOf(.{ .bearer = token }).bearer);
    try testing.expectEqualStrings("lit", credentialsOf(.{ .bearer = "lit" }).bearer);
    try testing.expectEqualStrings("ApiKey k", credentialsOf(.{ .custom = "ApiKey k" }).custom);
    const basic = credentialsOf(.{ .basic = .{ .user = "svc", .password = token } }).basic;
    try testing.expectEqualStrings("svc", basic.user);
    try testing.expectEqualStrings("t-1", basic.password);
    const typed: Credentials.Basic = .{ .user = "u", .password = "p" };
    try testing.expectEqualStrings("u", credentialsOf(.{ .basic = typed }).basic.user);
    const given: Credentials = .{ .bearer = token };
    try testing.expectEqualStrings("t-1", credentialsOf(given).bearer);
}

test "the links of a client are functions or pointers to objects" {
    try expectNoProblem(With("middleware", struct { @TypeOf(countCalls), *Breaker }));
    const message = "rpc.Client.init: .middleware[1] must be fn (*rpc.ClientContext, *rpc.ClientNext) anyerror!void or a pointer to a type with pub fn run(self, *rpc.ClientContext, *rpc.ClientNext) anyerror!void";
    try expectProblem(With("middleware", struct { @TypeOf(countCalls), Breaker }), message);
    try expectProblem(With("middleware", struct { @TypeOf(countCalls), *const Breaker }), message);
    try expectProblem(With("middleware", struct { @TypeOf(countCalls), *ServerSide }), message);
    try expectProblem(With("middleware", struct { @TypeOf(countCalls), []Breaker }), message);
    try expectProblem(With("middleware", struct { @TypeOf(countCalls), @TypeOf(inferredLink) }), "rpc.Client.init: .middleware[1] must be fn (*rpc.ClientContext, *rpc.ClientNext) anyerror!void, with anyerror written out, not inferred; got fn (*rpc.ClientContext, *rpc.ClientNext) !void");
    try expectProblem(With("middleware", *Breaker), "rpc.Client.init: .middleware must be a tuple such as .{ clientMetrics, &breaker }; got *app.client_options.Breaker");
}

test "the links become the engine's, in order" {
    var breaker: Breaker = .{};
    var buffer: [2]ClientMiddleware = undefined;
    const links = linksOf(.{ countCalls, &breaker }, &buffer);
    try testing.expectEqual(@as(usize, 2), links.len);
    try testing.expectEqual(@as(?*anyopaque, null), links[0].ptr);
    try testing.expectEqual(@as(?*anyopaque, &breaker), links[1].ptr);
    try testing.expectEqual(@as(usize, 0), linksOf(.{}, &buffer).len);
}
