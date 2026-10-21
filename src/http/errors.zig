//! Errors and their responses: the framework's own
//! errors, `http.Error`, the status, code and title of every error the
//! framework knows, the form of an error handler (`http.ErrorResponse`,
//! `.fallback`, `http.ErrorAction`) and `http.Problem`, the body of RFC
//! 9457 that answers an error when the application has no error handler of
//! its own.
//!
//! An error handler is one object for the whole server, `.error_handler =
//! &app_errors`. Its `mapError` gives an error its status and body; the
//! compiler calls it at build time for the strict error check, so it takes
//! no context and does no I/O. Its optional `handle` adds what the request
//! knows, or writes a response of its own:
//!
//! ```zig
//! pub const AppErrors = struct {
//!     pub fn mapError(err: anyerror) http.ErrorResponse(ApiError) {
//!         return switch (err) {
//!             error.TodoNotFound => .{ .status = 404, .body = .{ .code = "todos.not_found", .message = "Todo not found" } },
//!             else => .fallback(err, .{ .code = http.defaultCode(err), .message = http.defaultTitle(err) }),
//!         };
//!     }
//!
//!     pub fn handle(self: *AppErrors, ctx: *http.Context, err: anyerror, res: *http.ErrorResponse(ApiError)) !http.ErrorAction {
//!         res.body.trace_id = ctx.traceId();
//!         if (err == error.ValidationFailed) res.body.details = ctx.violations();
//!         return .respond;
//!     }
//! };
//! ```
const std = @import("std");
const Violation = @import("validator").Violation;
const Context = @import("Context.zig");

/// The framework's own errors, with their statuses in `defaultStatus`.
pub const Error = error{
    InvalidRequest, // 400
    Unauthenticated, // 401
    PermissionDenied, // 403
    RouteNotFound, // 404
    MethodNotAllowed, // 405, with Allow
    PayloadTooLarge, // 413
    UnsupportedMediaType, // 415
    ValidationFailed, // 422
    RateLimited, // 429
    Overloaded, // 503: .max_in_flight, .max_streams
    Unavailable, // 503
    RequestTimeout, // 504: the deadline of the request passed
    // 500: mistakes of the program.
    ResponseCommitted,
    InvalidHeaderValue,
    /// `setHeader` of a field the backend writes itself.
    ReservedHeader,
    LocalMissing,
    BodyConsumed,
    HandledWithoutResponse,
    /// CR, LF or NUL in the `id` of an SSE event.
    InvalidEvent,
    /// An SSE event longer than the `.queue.max_bytes` of its manager.
    EventTooLarge,
};

/// What `handle` decided: `respond` sends the `http.ErrorResponse` as it
/// is now; `handled` sends what `handle` wrote with `ctx.response` itself,
/// such as an HTML page or a redirect.
pub const ErrorAction = enum { respond, handled };

/// The status and the body of the response to an error, as `mapError`
/// gives it. The body goes out as JSON, through the transforms and with the
/// outside names of its `field_rules`: as `application/problem+json` for
/// `http.Problem`, else as `application/json`.
pub fn ErrorResponse(comptime T: type) type {
    return struct {
        status: u16,
        body: T,
        /// Set by `fallback` alone; leave it as it is. By it the strict
        /// error check tells the fallback branch of `mapError` from an
        /// explicit one: an error of the application that only the
        /// fallback gives 500 fails the build.
        from_fallback: bool = false,

        const Self = @This();
        /// The type of the body.
        pub const Body = T;
        pub const zefir_http_error_response = {};

        /// The branch for the errors `mapError` does not name: the
        /// framework's status, `http.defaultStatus(err)`, with a body of
        /// yours, so that every error goes out in one format.
        ///
        /// ```zig
        /// else => .fallback(err, .{ .code = http.defaultCode(err), .message = http.defaultTitle(err) }),
        /// ```
        pub fn fallback(err: anyerror, body: T) Self {
            return .{ .status = defaultStatus(err), .body = body, .from_fallback = true };
        }
    };
}

/// RFC 9457 problem details, with the members `code` and `errors` of
/// zefir: the body of `application/problem+json`.
pub const Problem = struct {
    type: []const u8 = "about:blank",
    title: []const u8,
    status: u16,
    detail: ?[]const u8 = null,
    instance: ?[]const u8 = null,
    /// A stable code: `defaultCode`.
    code: []const u8,
    /// The violations of a 422.
    errors: []const Violation = &.{},
};

/// The status of `err` when nobody maps it: the framework's errors and
/// those of std and core the framework knows; else 500. Pure, callable at
/// compile time.
pub fn defaultStatus(err: anyerror) u16 {
    return switch (err) {
        error.InvalidRequest => 400,
        error.Unauthenticated => 401,
        error.PermissionDenied => 403,
        error.RouteNotFound => 404,
        error.MethodNotAllowed => 405,
        error.PayloadTooLarge => 413,
        error.UnsupportedMediaType => 415,
        error.ValidationFailed => 422,
        error.RateLimited => 429,
        error.Overloaded, error.Unavailable, error.ConcurrencyUnavailable => 503,
        error.RequestTimeout, error.DeadlineExceeded => 504,
        else => 500,
    };
}

/// The stable code of `err` for a response body. Pure, callable at
/// compile time.
pub fn defaultCode(err: anyerror) []const u8 {
    return switch (defaultStatus(err)) {
        400 => "invalid_request",
        401 => "unauthenticated",
        403 => "permission_denied",
        404 => "not_found",
        405 => "method_not_allowed",
        413 => "payload_too_large",
        415 => "unsupported_media_type",
        422 => "validation_failed",
        429 => "rate_limited",
        503 => "unavailable",
        504 => "timeout",
        else => "internal",
    };
}

/// The reason phrase of `defaultStatus(err)`. Pure, callable at compile
/// time.
pub fn defaultTitle(err: anyerror) []const u8 {
    return switch (defaultStatus(err)) {
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Content Too Large",
        415 => "Unsupported Media Type",
        422 => "Unprocessable Content",
        429 => "Too Many Requests",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "Internal Server Error",
    };
}

/// The error handler of a server without `.error_handler`:
/// problem+json with the framework's status, code and title, and the
/// violations of a 422 in `errors`. Every error goes through `.fallback`,
/// so an error of the application is 500, and the strict error check asks
/// for an error handler that maps it.
pub const DefaultErrors = struct {
    pub fn mapError(err: anyerror) ErrorResponse(Problem) {
        return .fallback(err, problem(err));
    }

    pub fn handle(_: *DefaultErrors, ctx: *Context, err: anyerror, res: *ErrorResponse(Problem)) error{}!ErrorAction {
        res.body.status = res.status;
        if (err == error.ValidationFailed) res.body.errors = ctx.violations();
        return .respond;
    }

    /// The problem of `err`: its status, code and title.
    pub fn problem(err: anyerror) Problem {
        return .{ .title = defaultTitle(err), .status = defaultStatus(err), .code = defaultCode(err) };
    }
};

/// The errors that end a request without a response: the client has gone
/// or the server stops (`Canceled` of std.Io, `Cancelled` of core).
pub fn isCancellation(err: anyerror) bool {
    return err == error.Canceled or err == error.Cancelled;
}

const testing = std.testing;

test "status table: every http.Error and the std and core errors" {
    const Row = struct { anyerror, u16, []const u8, []const u8 };
    const framework = [_]Row{
        .{ error.InvalidRequest, 400, "invalid_request", "Bad Request" },
        .{ error.Unauthenticated, 401, "unauthenticated", "Unauthorized" },
        .{ error.PermissionDenied, 403, "permission_denied", "Forbidden" },
        .{ error.RouteNotFound, 404, "not_found", "Not Found" },
        .{ error.MethodNotAllowed, 405, "method_not_allowed", "Method Not Allowed" },
        .{ error.PayloadTooLarge, 413, "payload_too_large", "Content Too Large" },
        .{ error.UnsupportedMediaType, 415, "unsupported_media_type", "Unsupported Media Type" },
        .{ error.ValidationFailed, 422, "validation_failed", "Unprocessable Content" },
        .{ error.RateLimited, 429, "rate_limited", "Too Many Requests" },
        .{ error.Overloaded, 503, "unavailable", "Service Unavailable" },
        .{ error.Unavailable, 503, "unavailable", "Service Unavailable" },
        .{ error.RequestTimeout, 504, "timeout", "Gateway Timeout" },
        .{ error.ResponseCommitted, 500, "internal", "Internal Server Error" },
        .{ error.InvalidHeaderValue, 500, "internal", "Internal Server Error" },
        .{ error.ReservedHeader, 500, "internal", "Internal Server Error" },
        .{ error.LocalMissing, 500, "internal", "Internal Server Error" },
        .{ error.BodyConsumed, 500, "internal", "Internal Server Error" },
        .{ error.HandledWithoutResponse, 500, "internal", "Internal Server Error" },
        .{ error.InvalidEvent, 500, "internal", "Internal Server Error" },
        .{ error.EventTooLarge, 500, "internal", "Internal Server Error" },
    };
    // The table holds every error of http.Error.
    const names = @typeInfo(Error).error_set.error_names.?;
    try testing.expectEqual(names.len, framework.len);
    inline for (names) |name| {
        for (framework) |row| {
            if (row[0] == @field(anyerror, name)) break;
        } else {
            std.debug.print("error.{s} is not in the table\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
    // The errors of std and core, and one of the application.
    const others = [_]Row{
        .{ error.ConcurrencyUnavailable, 503, "unavailable", "Service Unavailable" },
        .{ error.DeadlineExceeded, 504, "timeout", "Gateway Timeout" },
        .{ error.OutOfMemory, 500, "internal", "Internal Server Error" },
        .{ error.ReadFailed, 500, "internal", "Internal Server Error" },
        .{ error.WriteFailed, 500, "internal", "Internal Server Error" },
        .{ error.TodoNotFound, 500, "internal", "Internal Server Error" },
    };
    for (framework ++ others) |row| {
        errdefer std.debug.print("error.{t}\n", .{row[0]});
        try testing.expectEqual(row[1], defaultStatus(row[0]));
        try testing.expectEqualStrings(row[2], defaultCode(row[0]));
        try testing.expectEqualStrings(row[3], defaultTitle(row[0]));
    }
    // A cancelation ends the request without a response.
    try testing.expect(isCancellation(error.Canceled) and isCancellation(error.Cancelled));
    try testing.expect(!isCancellation(error.RequestTimeout) and !isCancellation(error.DeadlineExceeded));
}

test "ErrorResponse: .fallback takes the framework's status and marks the branch" {
    const ApiError = struct { code: []const u8 };
    const R = ErrorResponse(ApiError);
    try testing.expect(R.Body == ApiError);
    const explicit: R = .{ .status = 500, .body = .{ .code = "boom" } };
    try testing.expect(!explicit.from_fallback);
    const missing: R = .fallback(error.RouteNotFound, .{ .code = "not_found" });
    try testing.expectEqual(404, missing.status);
    try testing.expect(missing.from_fallback);
    try testing.expectEqualStrings("not_found", missing.body.code);
    // The compiler can call it, as the strict error check does.
    const unknown = comptime R.fallback(error.TodoNotFound, .{ .code = "internal" });
    try testing.expectEqual(500, unknown.status);
}

test "the default handler: problem+json with status, code and the violations of a 422" {
    var res = DefaultErrors.mapError(error.MethodNotAllowed);
    try testing.expect(res.from_fallback);
    try testing.expectEqual(405, res.status);
    try testing.expectEqualStrings("about:blank", res.body.type);
    try testing.expectEqualStrings("Method Not Allowed", res.body.title);
    try testing.expectEqualStrings("method_not_allowed", res.body.code);
    // An error of the application: 500 through .fallback.
    const app = DefaultErrors.mapError(error.TodoNotFound);
    try testing.expect(app.from_fallback);
    try testing.expectEqual(500, app.status);
    try testing.expectEqualStrings("internal", app.body.code);

    // handle: the status of the response in the body, and the violations
    // of a 422 in `errors`.
    const violations = [_]Violation{.{ .code = "http.missing_field", .message = "is required", .field = "title" }};
    var ctx: Context = undefined;
    ctx.internal.violations = &violations;
    var handler: DefaultErrors = .{};
    res.status = 409;
    try testing.expectEqual(ErrorAction.respond, try handler.handle(&ctx, error.MethodNotAllowed, &res));
    try testing.expectEqual(409, res.body.status);
    try testing.expectEqual(0, res.body.errors.len);
    var invalid = DefaultErrors.mapError(error.ValidationFailed);
    try testing.expectEqual(ErrorAction.respond, try handler.handle(&ctx, error.ValidationFailed, &invalid));
    try testing.expectEqual(422, invalid.body.status);
    try testing.expectEqualStrings("validation_failed", invalid.body.code);
    try testing.expectEqual(1, invalid.body.errors.len);
    try testing.expectEqualStrings("title", invalid.body.errors[0].field.?);
}
