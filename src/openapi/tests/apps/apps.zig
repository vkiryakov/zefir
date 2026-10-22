//! The golden applications as one module, for a program outside this
//! directory that serves them: the codec check of tests/openapi, which
//! sends each its requests and checks the bodies against its documents.
//! A module holds a file once, so the applications, which share
//! request.zig, come in one. The module imports "zefir".
pub const todos = @import("todos.zig");
pub const shapes = @import("shapes.zig");
pub const rules = @import("rules.zig");
pub const secure = @import("secure.zig");
pub const Request = @import("request.zig").Request;
