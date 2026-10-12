//! List rules: `each`. A list is a slice whose items are not `u8`, or an
//! array `[N]T` (`[N]u8` included: it is an array of numbers).
const core = @import("core.zig");
const Rule = core.Rule;
const Outcome = core.Outcome;

fn acceptsList(comptime T: type) bool {
    return core.ListChild(T) != null;
}

/// The rules for every item of a slice or an array: one rule or a tuple of
/// rules. It declares item rules rather than checking the list: it must be
/// the last rule of its tuple and appear once, and it has no code or message
/// of its own. Null items are skipped; item paths are `tags[3]`.
pub fn each(comptime rules: anytype) Rule {
    @setEvalBranchQuota(core.eval_quota);
    const inner = core.toRules(rules, "each(...)");
    if (inner.len == 0) @compileError("validator: each(.{}): the list is empty");
    return .{
        .kind = .each,
        .code = "",
        .message = "",
        .args = "...",
        .inner = inner,
        .fits = struct {
            fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
                const Item = core.ListChild(T) orelse core.typeError(rule, T, where, "a slice or an array", acceptsList, null);
                core.checkRuleList(rule.inner, core.Unwrap(Item), where ++ "[]");
            }
        }.fits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                _ = value;
                @compileError("validator: internal: each is applied by the walker and never evaluated");
            }
        }.eval,
    };
}

/// The arguments the hints show for an uncalled constructor of this file:
/// `each must be called, e.g. v.each(v.notEmpty)`.
pub const call_examples = .{ .each = "v.notEmpty" };
