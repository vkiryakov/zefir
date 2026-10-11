//! zefir-log — structured logging.

const std = @import("std");
const options = @import("options.zig");

pub const Level = @import("level.zig").Level;
pub const Options = options.Options;
pub const Service = options.Service;
pub const ScopeRule = options.ScopeRule;
pub const Format = options.Format;
pub const OversizePolicy = options.OversizePolicy;
pub const Output = options.Output;

test {
    std.testing.refAllDecls(@This());
    _ = @import("level.zig");
    _ = @import("timestamp.zig");
    _ = @import("options.zig");
    _ = @import("escape.zig");
    _ = @import("redact.zig");
    _ = @import("fields.zig");
    _ = @import("encode.zig");
    _ = @import("scopes.zig");
}
