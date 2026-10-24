//! The error handler: every error of a route becomes a problem+json body
//! of RFC 9457. The compiler calls `mapError` for each error a route can
//! return, and the document shows what it answers.

const http = @import("zefir").http;

pub const AppErrors = struct {
    pub fn mapError(err: anyerror) http.ErrorResponse(http.Problem) {
        return switch (err) {
            error.TodoNotFound => .{ .status = 404, .body = .{ .title = "Todo not found", .status = 404, .code = "todos.not_found" } },
            else => .fallback(err, .{ .title = http.defaultTitle(err), .status = http.defaultStatus(err), .code = http.defaultCode(err) }),
        };
    }
};
