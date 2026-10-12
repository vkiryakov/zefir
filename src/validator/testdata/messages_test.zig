//! Messages: the default code and message of every rule, `.withMessage`
//! templates and their placeholders, braces, messages in any language, the
//! 512-byte limit, and preconditions, which keep their fixed code and message
//! under `.withMessage`.
const std = @import("std");
const v = @import("validator");
const h = @import("vtest");
const math = std.math;
const testing = std.testing;

const finite_code = "validation.finite";
const finite_message = "must be a finite number";

fn isFree(name: []const u8) bool {
    return !std.mem.eql(u8, name, "admin");
}

fn isEven(n: u32) bool {
    return n % 2 == 0;
}

/// `s` written `n` times.
fn repeat(comptime s: []const u8, comptime n: usize) [s.len * n]u8 {
    var out: [s.len * n]u8 = undefined;
    for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    return out;
}

test "every rule has its default code and message, in the singular and the plural and with one value" {
    try h.expectRule(v.notEmpty, "validation.not_empty", "must not be empty");
    try h.expectRule(v.positive, "validation.positive", "must be greater than 0");
    try h.expectRule(v.minItems(1), "validation.min_items", "must have at least 1 item");
    try h.expectRule(v.minItems(2), "validation.min_items", "must have at least 2 items");
    try h.expectRule(v.range(1, 10), "validation.range", "must be from 1 to 10");
    try h.expectRule(v.range(7, 7), "validation.range", "must be 7");
    try h.expectRule(v.oneOf(.{ "a", "b" }), "validation.one_of", "must be one of: a, b");
    try h.expectRule(v.oneOf(.{.admin}), "validation.one_of", "must be admin");
    try h.expectRule(v.custom("users.name_taken", "is already taken", isFree), "users.name_taken", "is already taken");
    try h.expectRule(v.equals(5), "validation.equals", "must be equal to 5");
    try h.expectRule(v.notEquals("root"), "validation.not_equals", "must not be equal to root");
    try h.expectRule(v.noneOf(.{ "admin", "root" }), "validation.none_of", "must not be one of: admin, root");
    try h.expectRule(v.noneOf(.{"root"}), "validation.none_of", "must not be root");
    try h.expectRule(v.empty, "validation.empty", "must be empty");
    try h.expectRule(v.min(18), "validation.min", "must be at least 18");
    try h.expectRule(v.max(100), "validation.max", "must be at most 100");
    try h.expectRule(v.nonNegative, "validation.non_negative", "must not be negative");
    try h.expectRule(v.negative, "validation.negative", "must be less than 0");
    try h.expectRule(v.nonPositive, "validation.non_positive", "must not be positive");
    try h.expectRule(v.divisibleBy(5), "validation.divisible_by", "must be divisible by 5");
    try h.expectRule(v.finite, finite_code, finite_message);
    try h.expectRule(v.maxItems(1), "validation.max_items", "must have at most 1 item");
    try h.expectRule(v.maxItems(100), "validation.max_items", "must have at most 100 items");
    // each reports through its inner rules.
    try h.expectRule(v.each(v.notEmpty), "", "");
}

test "withMessage fills in the placeholders of its rule" {
    try h.expectRule(v.min(18).withMessage("at least {min} years"), "validation.min", "at least 18 years");
    try h.expectRule(v.range(18, 120).withMessage("{min}..{max}"), "validation.range", "18..120");
    try h.expectRule(v.divisibleBy(5).withMessage("{{divisor}} = {divisor}"), "validation.divisible_by", "{divisor} = 5");
    try h.expectRule(v.min(3).withMessage("json: {{\"min\": {min}}}"), "validation.min", "json: {\"min\": 3}");
    try h.expectRule(v.negative.withMessage("a } b"), "validation.negative", "a } b");
    try h.expectRule(v.minItems(2).withMessage("добавьте не меньше {min} элементов"), "validation.min_items", "добавьте не меньше 2 элементов");
    // A violation carries the new message.
    try h.expectFail(u8, v.min(18).withMessage("at least {min} years"), 17, "validation.min", "at least 18 years");
    try h.expectFail([]const u32, v.minItems(2).withMessage("добавьте не меньше {min} элементов"), &.{1}, "validation.min_items", "добавьте не меньше 2 элементов");
    try h.expectFail(i32, v.range(1, 100).withMessage("от {min} до {max} штук"), 0, "validation.range", "от 1 до 100 штук");
}

test "{{ and }} write braces and a lone } stays as it is" {
    try h.expectRule(v.notEmpty.withMessage("{{"), "validation.not_empty", "{");
    try h.expectRule(v.notEmpty.withMessage("}}"), "validation.not_empty", "}");
    try h.expectRule(v.notEmpty.withMessage("}"), "validation.not_empty", "}");
    try h.expectRule(v.notEmpty.withMessage("}}}"), "validation.not_empty", "}}");
    try h.expectRule(v.notEmpty.withMessage("{{}}"), "validation.not_empty", "{}");
    try h.expectRule(v.notEmpty.withMessage("}{{"), "validation.not_empty", "}{");
    try h.expectRule(v.notEmpty.withMessage("a}b}}c"), "validation.not_empty", "a}b}c");
    // {{min}} is the text {min}, not a placeholder; {{{min}}} is the value in braces.
    try h.expectRule(v.min(3).withMessage("{{min}}"), "validation.min", "{min}");
    try h.expectRule(v.min(3).withMessage("{{{min}}}"), "validation.min", "{3}");
    try h.expectRule(v.min(3).withMessage("{min}{min}"), "validation.min", "33");
}

test "a second withMessage replaces the first, the placeholders stay, and the rule it was called on keeps its message" {
    try h.expectRule(v.minItems(8).withMessage("a {min}").withMessage("b {min}"), "validation.min_items", "b 8");
    const base = v.range(1, 100);
    const own = base.withMessage("от {min} до {max} штук");
    try h.expectRule(own, "validation.range", "от 1 до 100 штук");
    try h.expectRule(base, "validation.range", "must be from 1 to 100");
    try h.expectRule(v.range(1, 100), "validation.range", "must be from 1 to 100");
}

test "a message may be in any language and script; the 512-byte limit counts bytes" {
    try h.expectRule(v.notEmpty.withMessage("имя обязательно"), "validation.not_empty", "имя обязательно");
    try h.expectRule(v.notEmpty.withMessage("名前は必須です"), "validation.not_empty", "名前は必須です");
    try h.expectRule(v.notEmpty.withMessage("الاسم مطلوب"), "validation.not_empty", "الاسم مطلوب");
    try h.expectRule(v.notEmpty.withMessage("το όνομα είναι υποχρεωτικό"), "validation.not_empty", "το όνομα είναι υποχρεωτικό");
    try h.expectRule(v.notEmpty.withMessage("🙂 required"), "validation.not_empty", "🙂 required");
    try h.expectRule(v.max(10).withMessage("не больше {max}"), "validation.max", "не больше 10");
    try h.expectRule(v.oneOf(.{ "да", "нет" }).withMessage("ответ: {values}"), "validation.one_of", "ответ: да, нет");
    try h.expectFail([]const u8, v.notEmpty.withMessage("名前は必須です"), "", "validation.not_empty", "名前は必須です");
    // 256 Cyrillic letters, 128 emoji or 170 CJK characters and 2 ASCII letters are 512 bytes each.
    const cyrillic = comptime repeat("я", 256);
    const emoji = comptime repeat("🙂", 128);
    const cjk = comptime repeat("語", 170) ++ repeat("a", 2);
    inline for (.{ &cyrillic, &emoji, &cjk }) |text| {
        try testing.expectEqual(512, text.len);
        try h.expectRule(v.notEmpty.withMessage(text), "validation.not_empty", text);
        try h.expectFail([]const u8, v.notEmpty.withMessage(text), "", "validation.not_empty", text);
    }
}

test "the message after substitution may be exactly 512 bytes" {
    const fill: [511]u8 = @splat('m');
    const rule = v.maxItems(5).withMessage(fill ++ "{max}");
    try testing.expectEqual(512, rule.message.len);
    try h.expectFail([]const u32, rule, &.{ 1, 2, 3, 4, 5, 6 }, "validation.max_items", fill ++ "5");
    // A long placeholder value counts as it is shown: two values of 255 bytes and ", " make 512.
    const values = .{ &@as([255]u8, @splat('a')), &@as([255]u8, @splat('b')) };
    try testing.expectEqual(512, v.oneOf(values).withMessage("{values}").message.len);
}

test "withMessage replaces a fallback message, and its placeholder still shows every value" {
    const a: [247]u8 = @splat('a');
    const b: [248]u8 = @splat('b');
    const values = .{ &a, &b };
    // The default message would be 513 bytes, so the rule falls back.
    try h.expectRule(v.oneOf(values), "validation.one_of", "must be one of the allowed values");
    try h.expectRule(v.oneOf(values).withMessage("pick a listed value"), "validation.one_of", "pick a listed value");
    try h.expectRule(v.oneOf(values).withMessage("{values}"), "validation.one_of", &a ++ ", " ++ &b);
    try h.expectFail([]const u8, v.oneOf(values).withMessage("pick a listed value"), "c", "validation.one_of", "pick a listed value");
}

test "withMessage replaces the literal message of custom; braces are text in custom's message and syntax in a template" {
    const literal = v.custom("acme.even", "must be even, not {odd} }}", isEven);
    try h.expectRule(literal, "acme.even", "must be even, not {odd} }}");
    try h.expectFail(u32, literal, 3, "acme.even", "must be even, not {odd} }}");
    try h.expectRule(literal.withMessage("{{odd}} is not allowed }}"), "acme.even", "{odd} is not allowed }");
    try h.expectFail(u32, literal.withMessage("число должно быть чётным"), 3, "acme.even", "число должно быть чётным");
    try h.expectPass(u32, literal.withMessage("число должно быть чётным"), 4);
}

test "a precondition keeps its fixed code and message under withMessage" {
    const above_zero = v.positive.withMessage("must be above zero");
    try h.expectFail(f64, above_zero, math.nan(f64), finite_code, finite_message);
    try h.expectFail(f64, above_zero, -1, "validation.positive", "must be above zero");
    try h.expectPass(f64, above_zero, 1);
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try h.expectFail(F, v.min(0).withMessage("too small"), math.inf(F), finite_code, finite_message);
        try h.expectFail(F, v.min(0).withMessage("too small"), -1, "validation.min", "too small");
        try h.expectFail(F, v.range(0, 1).withMessage("{min}..{max}"), -math.inf(F), finite_code, finite_message);
        try h.expectFail(F, v.equals(1).withMessage("must be one"), math.nan(F), finite_code, finite_message);
        try h.expectFail(F, v.notEquals(0).withMessage("must not be zero"), math.nan(F), finite_code, finite_message);
        try h.expectFail(F, v.divisibleBy(2).withMessage("must be even"), math.nan(F), finite_code, finite_message);
        try h.expectFail(F, v.nonNegative.withMessage("must be zero or more"), -math.inf(F), finite_code, finite_message);
    }
    // finite fails NaN by its own check, so its withMessage applies: put it first to word that case.
    const price = .{ v.finite.withMessage("цена должна быть числом"), v.positive };
    try h.expectFail(f64, price, math.nan(f64), finite_code, "цена должна быть числом");
    try h.expectFail(f64, price, math.inf(f64), finite_code, "цена должна быть числом");
    try h.expectFail(f64, price, 0, "validation.positive", "must be greater than 0");
}

test "every rule with parameters has its placeholders, which show the parameters as the default message does" {
    try h.expectRule(v.equals(.admin).withMessage("{expected}"), "validation.equals", "admin");
    try h.expectRule(v.equals("tab\there").withMessage("{expected}"), "validation.equals", "tab\\there");
    try h.expectRule(v.equals(-0.0).withMessage("{expected}"), "validation.equals", "0");
    try h.expectRule(v.notEquals(false).withMessage("{forbidden}"), "validation.not_equals", "false");
    try h.expectRule(v.oneOf(.{ "", "x" }).withMessage("{values}"), "validation.one_of", "\"\", x");
    try h.expectRule(v.noneOf(.{ .admin, .editor }).withMessage("{values}"), "validation.none_of", "admin, editor");
    try h.expectRule(v.noneOf([_]u8{ 1, 2 }).withMessage("not {values}"), "validation.none_of", "not 1, 2");
    try h.expectRule(v.min(0.5).withMessage("{min}"), "validation.min", "0.5");
    try h.expectRule(v.max(0.1).withMessage("{max}"), "validation.max", "0.1");
    try h.expectRule(v.range(-1, 1e21).withMessage("{min} {max}"), "validation.range", "-1 1e21");
    try h.expectRule(v.divisibleBy(5).withMessage("{divisor}"), "validation.divisible_by", "5");
    try h.expectRule(v.minItems(3).withMessage("{min}"), "validation.min_items", "3");
    try h.expectRule(v.maxItems(10).withMessage("{max}"), "validation.max_items", "10");
    // The same text as in the default message, and the bound as written, before conversion to the field type.
    try h.expectRule(v.max(1e-6).withMessage("must be at most {max}"), "validation.max", v.max(1e-6).message);
    try h.expectFail(f32, v.max(0.1).withMessage("не больше {max}"), 0.2, "validation.max", "не больше 0.1");
}

test "a rule with its own message works inside each and can be declared once and reused on fields of different types" {
    const filled = v.notEmpty.withMessage("заполните поле");
    const Form = struct {
        name: []const u8,
        tags: []const []const u8,
        pub const field_rules = .{ .name = filled, .tags = .{ filled, v.each(filled) } };
    };
    try h.expectValid(&Form{ .name = "a", .tags = &.{"b"} });
    try h.expectAt(&Form{ .name = "", .tags = &.{"b"} }, "validation.not_empty", "заполните поле", "name");
    try h.expectAt(&Form{ .name = "a", .tags = &.{} }, "validation.not_empty", "заполните поле", "tags");
    try h.expectAt(&Form{ .name = "a", .tags = &.{ "b", "" } }, "validation.not_empty", "заполните поле", "tags[1]");
}

test "a bound whose default message would be longer than 512 bytes compiles and runs with withMessage" {
    const Big = struct {
        a: u2000 = 1 << 1700,
        b: u2000 = 1 << 1700,
        c: u1000 = 1 << 820,
        d: f128 = 0,
        pub const field_rules = .{
            .a = v.min(1 << 1700).withMessage("too small"),
            .b = v.max(1 << 1700).withMessage("too big"),
            .c = v.range(1 << 820, 1 << 830).withMessage("out of range"),
            .d = v.divisibleBy(1 << 2000).withMessage("must be a multiple of 2^2000"),
        };
    };
    comptime v.assertRules(Big);
    try h.expectValid(&Big{});
    try h.expectValid(&Big{ .c = 1 << 830, .d = 0x1p2000 });
    try h.expectAt(&Big{ .a = (1 << 1700) - 1 }, "validation.min", "too small", "a");
    try h.expectAt(&Big{ .b = (1 << 1700) + 1 }, "validation.max", "too big", "b");
    try h.expectAt(&Big{ .c = (1 << 830) + 1 }, "validation.range", "out of range", "c");
    try h.expectAt(&Big{ .d = 1 }, "validation.divisible_by", "must be a multiple of 2^2000", "d");
    try h.expectAt(&Big{ .d = math.nan(f128) }, finite_code, finite_message, "d");
}
