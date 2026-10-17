//! The strict error check (design section 11): at compile time, once per
//! server, the compiler calls the error handler's `mapError` for every
//! error the application can return to it, and the build stops
//!
//! - on an error of the application that only the fallback branch gives
//!   500 (`from_fallback` and status 500): map it, or give it 500 in a
//!   branch of its own, which the check takes as meant;
//! - on an error of the framework with a status of its own, such as
//!   `RouteNotFound` (404), that `mapError` gives 500: an `else` without
//!   `.fallback` would turn it into 500 unseen;
//! - on an error set the check cannot read: `anyerror`.
//!
//! Without `.error_handler`, the default handler gives every error of the
//! application 500, so the check asks for an error handler that maps it.
//! `.strict_errors = false` turns the check off.
//!
//! The check reads a list of entries, each a place and its error set:
//! plan.zig gives one for the handler of each route and one for the
//! transforms of the JSON value it answers with. Each error is checked
//! once, under the first place that can return it, so the work grows with
//! the errors of the application, not with the routes.
const std = @import("std");
const core = @import("core");
const errors = @import("errors.zig");

/// A place that can return errors to the error handler, and its errors.
pub const Entry = struct {
    /// How a message names the place: `UsersV1Controller.create`, or
    /// `UsersV1Controller.get (writing its response)`.
    where: []const u8,
    Errors: type,
};

/// The end of every message of the check.
pub const hint = " (strict error check; .strict_errors = false turns it off)";

/// Checks every error of `entries` against `H`, the error handler that
/// messages call `name`; `errors.DefaultErrors` without `.error_handler`.
/// The eval branch quota is set here, from the errors and their names: the
/// application sets none.
///
/// Zig orders the names of an error set by when the compilation first met
/// each, so the check orders them itself, for messages that name the same
/// error whatever else the application holds: the places in the order of
/// `entries`, the errors of one place by name.
pub fn check(comptime H: type, comptime name: []const u8, comptime entries: []const Entry) void {
    comptime {
        var count: u64 = 0;
        for (entries) |entry| {
            const list = @typeInfo(entry.Errors).error_set.error_names orelse
                @compileError("zefir.http: " ++ entry.where ++ " returns anyerror; the strict error check needs the errors it can return: give it an error set" ++ hint);
            count += list.len;
        }
        // A look at every name first, then each place raises it by its work.
        var quota: u64 = 10_000 + 4 * count + statused.len * 200;
        @setEvalBranchQuota(capped(quota));
        const verdict = if (H == errors.DefaultErrors)
            "the default error handler gives it 500; set .error_handler and map it"
        else
            name ++ ".mapError gives it 500 through .fallback";
        var seen: []const anyerror = &.{};
        for (entries) |entry| {
            const list = @typeInfo(entry.Errors).error_set.error_names.?;
            // Per error: the list of known ones, the errors checked before,
            // its place among the new ones, found by comparing names a byte
            // at a time, and a call of mapError.
            var longest: u64 = 0;
            for (list) |error_name| longest = @max(longest, error_name.len);
            quota += list.len * (200 + 2 * seen.len + list.len * (longest + 2));
            @setEvalBranchQuota(capped(quota));
            // The errors of the application this place adds, by name.
            var new: []const []const u8 = &.{};
            for (list) |error_name| {
                const err = @field(anyerror, error_name);
                if (isKnown(err) or contains(seen, err)) continue;
                new = insertSorted(new, error_name);
            }
            for (new) |error_name| {
                const err = @field(anyerror, error_name);
                seen = seen ++ [_]anyerror{err};
                const res = H.mapError(err);
                if (res.from_fallback and res.status == 500)
                    @compileError("zefir.http: " ++ entry.where ++ " can return error." ++ error_name ++ "; " ++ verdict ++ hint);
            }
        }
        // The default handler maps every error through .fallback.
        if (H != errors.DefaultErrors) checkStatused(H, name);
    }
}

/// The errors whose answer the framework knows, which the check leaves
/// out: those of `http.Error`, `OutOfMemory`, the cancelations,
/// `ConcurrencyUnavailable`, the errors of `std.Io` readers and writers
/// (`ReadFailed`, `WriteFailed`) and those of core's contexts.
pub fn isKnown(comptime err: anyerror) bool {
    return switch (err) {
        error.OutOfMemory, error.Canceled, error.ConcurrencyUnavailable, error.ReadFailed, error.WriteFailed => true,
        else => inSet(errors.Error, err) or inSet(core.ContextError, err),
    };
}

/// The errors with a status of their own, not 500, that the server
/// answers with: those of `http.Error`, `ConcurrencyUnavailable` (503) and
/// core's `DeadlineExceeded` (504); by status, then by name.
const statused = statusedNames();

fn statusedNames() []const []const u8 {
    var out: []const []const u8 = &.{};
    for (@typeInfo(errors.Error || error{ ConcurrencyUnavailable, DeadlineExceeded }).error_set.error_names.?) |error_name| {
        const status = errors.defaultStatus(@field(anyerror, error_name));
        if (status == 500) continue;
        var at: usize = 0;
        while (at < out.len) : (at += 1) {
            const other = errors.defaultStatus(@field(anyerror, out[at]));
            if (status < other or (status == other and std.mem.order(u8, error_name, out[at]) == .lt)) break;
        }
        out = out[0..at] ++ [_][]const u8{error_name} ++ out[at..];
    }
    return out;
}

/// An error with a status other than 500 must not become 500: an `else`
/// without `.fallback` would make it one unseen.
fn checkStatused(comptime H: type, comptime name: []const u8) void {
    for (statused) |error_name| {
        const err = @field(anyerror, error_name);
        const status = errors.defaultStatus(err);
        if (H.mapError(err).status == 500)
            @compileError("zefir.http: " ++ name ++ ".mapError gives error." ++ error_name ++ " 500, while its status is " ++
                std.fmt.comptimePrint("{d}", .{status}) ++ "; map it or keep .fallback in else" ++ hint);
    }
}

/// An eval branch quota, which is a u32.
fn capped(quota: u64) u32 {
    return @intCast(@min(quota, std.math.maxInt(u32)));
}

/// `list`, sorted, with `item` in its place.
fn insertSorted(comptime list: []const []const u8, comptime item: []const u8) []const []const u8 {
    var at: usize = 0;
    while (at < list.len and std.mem.order(u8, list[at], item) == .lt) at += 1;
    return list[0..at] ++ [_][]const u8{item} ++ list[at..];
}

fn inSet(comptime E: type, comptime err: anyerror) bool {
    for (@typeInfo(E).error_set.error_names.?) |error_name| {
        if (@field(anyerror, error_name) == err) return true;
    }
    return false;
}

fn contains(comptime list: []const anyerror, comptime err: anyerror) bool {
    for (list) |item| {
        if (item == err) return true;
    }
    return false;
}

const testing = std.testing;
const ErrorResponse = errors.ErrorResponse;

const ApiError = struct { code: []const u8 };

/// Maps `TodoNotFound` and `LimitReached`, gives `Corrupted` 500 in a
/// branch of its own, and the rest through `.fallback`.
const AppErrors = struct {
    pub fn mapError(err: anyerror) ErrorResponse(ApiError) {
        return switch (err) {
            error.TodoNotFound => .{ .status = 404, .body = .{ .code = "todos.not_found" } },
            error.LimitReached => .{ .status = 409, .body = .{ .code = "todos.limit_reached" } },
            error.Corrupted => .{ .status = 500, .body = .{ .code = "todos.corrupted" } },
            else => .fallback(err, .{ .code = errors.defaultCode(err) }),
        };
    }
};

test "the strict check passes mapped errors, errors with a branch of 500, and the framework's" {
    comptime check(AppErrors, "AppErrors", &.{
        .{ .where = "TodosV1Controller.create", .Errors = error{ TodoNotFound, LimitReached, OutOfMemory, Canceled } },
        .{ .where = "TodosV1Controller.remove", .Errors = error{ Corrupted, ReadFailed, WriteFailed, Cancelled, DeadlineExceeded } },
        .{ .where = "TodosV1Controller.list", .Errors = errors.Error || error{ConcurrencyUnavailable} },
    });
    // Without an error handler, only the errors whose answer is known pass.
    comptime check(errors.DefaultErrors, "DefaultErrors", &.{
        .{ .where = "TodosV1Controller.list", .Errors = errors.Error || core.ContextError || error{ OutOfMemory, Canceled, ReadFailed, WriteFailed } },
    });
}

test "the strict check knows the errors with an answer of their own" {
    try testing.expect(comptime isKnown(error.RouteNotFound));
    try testing.expect(comptime isKnown(error.InvalidEvent));
    try testing.expect(comptime isKnown(error.DeadlineExceeded));
    try testing.expect(comptime isKnown(error.ConcurrencyUnavailable));
    try testing.expect(comptime !isKnown(error.TodoNotFound));
    try testing.expect(comptime !isKnown(error.FileNotFound));
    // The errors with a status of their own, by status: every one of
    // http.Error but the 500s, and the two of std and core.
    var others: usize = 0;
    inline for (@typeInfo(errors.Error).error_set.error_names.?) |error_name| {
        if (errors.defaultStatus(@field(anyerror, error_name)) != 500) others += 1;
    }
    try testing.expectEqual(others + 2, statused.len);
    try testing.expectEqualStrings("InvalidRequest", statused[0]);
    try testing.expectEqualStrings("RouteNotFound", statused[3]);
    inline for (statused[0 .. statused.len - 1], statused[1..]) |a, b| {
        try testing.expect(errors.defaultStatus(@field(anyerror, a)) <= errors.defaultStatus(@field(anyerror, b)));
    }
}

test "the strict check names the errors of a place by name, whatever order Zig gives them" {
    const sorted = comptime insertSorted(insertSorted(insertSorted(&.{}, "UserNotFound"), "Alpha"), "UserLimitReached");
    try testing.expectEqual(3, sorted.len);
    try testing.expectEqualStrings("Alpha", sorted[0]);
    try testing.expectEqualStrings("UserLimitReached", sorted[1]);
    try testing.expectEqualStrings("UserNotFound", sorted[2]);
}
