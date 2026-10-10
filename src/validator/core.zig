//! The core that the rule files and the walker share: limits, violations,
//! rule kinds, the `Rule` type and the compile-time helpers that check
//! declarations. Only what `root.zig` re-exports is public API.

const std = @import("std");

/// Rule constructors, declaration checks and walker functions share one
/// comptime branch counter per declaration, so the library raises the quota
/// itself: a DTO with many fields or rules never stops a build with
/// `evaluation exceeded 1000 backwards branches`.
pub const eval_quota = 10_000_000;

/// Longest `v.custom` and `v.fail` code, in bytes.
pub const max_code_bytes = 128;
/// Longest message, in bytes (not code points).
pub const max_message_bytes = 512;
/// Most violations `checkAll` keeps; `Report.truncated` says when more existed.
pub const max_report_violations = 100;

/// One failed rule. The library builds `code` and `message` at compile time:
/// they live as long as the program and never contain the checked value, so
/// a violation can be logged or sent to a client as it is.
pub const Violation = struct {
    /// `validation.<kind>` for a built-in rule (`validation.not_empty`), a
    /// precondition's code (`validation.finite`), `validation.invalid` for a
    /// malformed `validateSelf` result outside Debug builds, or the `code`
    /// argument of `v.custom` and `v.fail`.
    code: []const u8,
    /// What the value must be, without the field name: a built-in English
    /// message such as `must not be empty`, or the message given to
    /// `v.custom` or `v.fail`. Always 1-512 bytes of valid UTF-8.
    message: []const u8,
    /// The path of the value from the root: `email`, `address.city`,
    /// `items[2].name`, `[1].email`. Null means the root value itself or, for
    /// `check` only, a path that did not fit `path_buf`.
    field: ?[]const u8 = null,
};
