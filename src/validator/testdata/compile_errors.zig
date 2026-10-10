//! The compile-error fixtures: every file listed here must fail to compile,
//! and one line of the compiler's error output must end with `expect`.
//! `build.zig` compiles each file as a test root that imports `validator`
//! (analysis only: nothing is emitted or run) with
//! `expect_errors = .{ .contains = expect }`, which matches the end of an
//! error line, so `expect` is the whole tail of the line from `validator: `.
//!
//! To add a fixture, write `compile_errors/<case>.zig`: a struct `Bad` with a
//! field `x` and the declaration under test, and a test that runs
//! `comptime v.assertRules(Bad);` (or calls `v.check`/`v.checkAll` for errors
//! of the entry points). Then add an entry below. Write `expect` by hand from
//! the text the error is meant to have (for a catalog error, `<Type>` is
//! `<file stem>.Bad` and `<field>` is `x`), never by copying the compiler's
//! output: a copied text would only check the implementation against itself.
//! `row` is the id of the error in the catalog (`G-13`), or `variant of G-13`
//! for another example of the same error. Fixtures are never imported by the
//! module or by its tests; they must stay `zig fmt`-clean, since only their
//! semantic analysis is meant to fail.
const Fixture = @import("cases.zig").Fixture;

pub const list = [_]Fixture{
    .{ .file = "src/validator/testdata/compile_errors/unknown_key_suggestion.zig", .expect = "validator: unknown_key_suggestion.Bad.field_rules.nmae: no such field; did you mean \"name\"?", .row = "G-1" },
    .{ .file = "src/validator/testdata/compile_errors/assert_rules_nested.zig", .expect = "validator: assert_rules_nested.Inner.field_rules.nmae: no such field; did you mean \"name\"?", .row = "variant of G-1" },
    .{ .file = "src/validator/testdata/compile_errors/anonymous_struct_label.zig", .expect = "validator: anonymous_struct_label.Bad.address.geo.field_rules.lta: no such field; did you mean \"lat\"?", .row = "variant of G-1" },
    .{ .file = "src/validator/testdata/compile_errors/unknown_key_no_suggestion.zig", .expect = "validator: unknown_key_no_suggestion.Bad.field_rules.zzz: no such field", .row = "G-2" },
    .{ .file = "src/validator/testdata/compile_errors/field_rules_tuple.zig", .expect = "validator: field_rules_tuple.Bad.field_rules: must be a struct literal .{ .field = rule or .{ rules } }, got a tuple", .row = "G-3" },
    .{ .file = "src/validator/testdata/compile_errors/field_rules_rule.zig", .expect = "validator: field_rules_rule.Bad.field_rules: must be a struct literal .{ .field = rule or .{ rules } }, got core.Rule", .row = "variant of G-3" },
    .{ .file = "src/validator/testdata/compile_errors/field_rules_int.zig", .expect = "validator: field_rules_int.Bad.field_rules: must be a struct literal .{ .field = rule or .{ rules } }, got comptime_int", .row = "variant of G-3" },
    .{ .file = "src/validator/testdata/compile_errors/entry_not_rule.zig", .expect = "validator: entry_not_rule.Bad.field_rules.x: expected a rule or a tuple of rules, got *const [8:0]u8", .row = "G-4" },
    .{ .file = "src/validator/testdata/compile_errors/entry_tuple_item_not_rule.zig", .expect = "validator: entry_tuple_item_not_rule.Bad.field_rules.x: item 1 of the tuple is comptime_int", .row = "G-5" },
    .{ .file = "src/validator/testdata/compile_errors/entry_plain_function.zig", .expect = "validator: entry_plain_function.Bad.field_rules.x: expected a rule or a tuple of rules, got fn (u32) bool; wrap a predicate in v.custom(code, message, f)", .row = "G-7" },
    .{ .file = "src/validator/testdata/compile_errors/entry_plain_function_in_tuple.zig", .expect = "validator: entry_plain_function_in_tuple.Bad.field_rules.x: item 1 of the tuple is fn (u32) bool; wrap a predicate in v.custom(code, message, f)", .row = "variant of G-7" },
    .{ .file = "src/validator/testdata/compile_errors/misnamed_validate.zig", .expect = "validator: misnamed_validate.Bad.validate: rules are declared in pub const field_rules; rename validate to field_rules (a pub fn validate is left to confy)", .row = "G-8" },
    .{ .file = "src/validator/testdata/compile_errors/comptime_field_rules.zig", .expect = "validator: comptime_field_rules.Bad.field_rules.x: comptime fields are not validated", .row = "G-9" },
    .{ .file = "src/validator/testdata/compile_errors/dotted_field.zig", .expect = "validator: dotted_field.Bad.a.b: a field name with '.', '[' or ']' makes paths ambiguous; rename the field", .row = "G-10" },
    .{ .file = "src/validator/testdata/compile_errors/bracket_field.zig", .expect = "validator: bracket_field.Bad.items[0]: a field name with '.', '[' or ']' makes paths ambiguous; rename the field", .row = "variant of G-10" },
    .{ .file = "src/validator/testdata/compile_errors/union_field.zig", .expect = "validator: union_field.Bad.x: unions are not walked; union_field.Choice reaches union_field.Item, which declares field_rules or validateSelf that would be skipped", .row = "G-11" },
    .{ .file = "src/validator/testdata/compile_errors/root_union.zig", .expect = "validator: root_union.Choice: unions are not walked; root_union.Choice reaches root_union.Item, which declares field_rules or validateSelf that would be skipped", .row = "G-12" },
    .{ .file = "src/validator/testdata/compile_errors/assert_rules_pointer.zig", .expect = "validator: *const assert_rules_pointer.Item: pointers are not walked; *const assert_rules_pointer.Item reaches assert_rules_pointer.Item, which declares field_rules or validateSelf that would be skipped", .row = "variant of G-12" },
    .{ .file = "src/validator/testdata/compile_errors/root_opaque.zig", .expect = "validator: root_opaque.Handle: opaque types are not walked; root_opaque.Handle declares field_rules or validateSelf that would be skipped", .row = "variant of G-12" },
    .{ .file = "src/validator/testdata/compile_errors/pointer_field.zig", .expect = "validator: pointer_field.Bad.x: pointers are not walked; *const pointer_field.Item reaches pointer_field.Item, which declares field_rules or validateSelf that would be skipped", .row = "G-13" },
    .{ .file = "src/validator/testdata/compile_errors/many_pointer_field.zig", .expect = "validator: many_pointer_field.Bad.x: pointers are not walked; [*]const many_pointer_field.Item reaches many_pointer_field.Item, which declares field_rules or validateSelf that would be skipped", .row = "variant of G-13" },
    .{ .file = "src/validator/testdata/compile_errors/optional_pointer_field.zig", .expect = "validator: optional_pointer_field.Bad.x: pointers are not walked; *const optional_pointer_field.Item reaches optional_pointer_field.Item, which declares field_rules or validateSelf that would be skipped", .row = "variant of G-13" },
    .{ .file = "src/validator/testdata/compile_errors/recursive_pointer.zig", .expect = "validator: recursive_pointer.Bad.x: pointers are not walked; *const recursive_pointer.Bad reaches recursive_pointer.Bad, which declares field_rules or validateSelf that would be skipped", .row = "variant of G-13" },
    .{ .file = "src/validator/testdata/compile_errors/volatile_slice_field.zig", .expect = "validator: volatile_slice_field.Bad.x: pointers are not walked; []volatile volatile_slice_field.Item reaches volatile_slice_field.Item, which declares field_rules or validateSelf that would be skipped", .row = "variant of G-13" },
    .{ .file = "src/validator/testdata/compile_errors/allowzero_slice_field.zig", .expect = "validator: allowzero_slice_field.Bad.x: pointers are not walked; []allowzero const allowzero_slice_field.Item reaches allowzero_slice_field.Item, which declares field_rules or validateSelf that would be skipped", .row = "variant of G-13" },
    .{ .file = "src/validator/testdata/compile_errors/under_aligned_slice_field.zig", .expect = "validator: under_aligned_slice_field.Bad.x: pointers are not walked; []align(1) const under_aligned_slice_field.Item reaches under_aligned_slice_field.Item, which declares field_rules or validateSelf that would be skipped", .row = "variant of G-13" },
    .{ .file = "src/validator/testdata/compile_errors/pointer_in_slice.zig", .expect = "validator: pointer_in_slice.Bad.x[]: pointers are not walked; *const pointer_in_slice.Item reaches pointer_in_slice.Item, which declares field_rules or validateSelf that would be skipped", .row = "G-14" },
    .{ .file = "src/validator/testdata/compile_errors/tuple_field.zig", .expect = "validator: tuple_field.Bad.x: tuples are not walked; struct { u32, tuple_field.Item } reaches tuple_field.Item, which declares field_rules or validateSelf that would be skipped", .row = "G-15" },
    .{ .file = "src/validator/testdata/compile_errors/enum_with_self.zig", .expect = "validator: enum_with_self.Bad.x: enums are not walked; enum_with_self.Level declares field_rules or validateSelf that would be skipped", .row = "G-16" },
    .{ .file = "src/validator/testdata/compile_errors/union_with_field_rules.zig", .expect = "validator: union_with_field_rules.Bad.x: unions are not walked; union_with_field_rules.Shape declares field_rules or validateSelf that would be skipped", .row = "variant of G-16" },
    .{ .file = "src/validator/testdata/compile_errors/error_union_field.zig", .expect = "validator: error_union_field.Bad.x: error unions are not walked; anyerror!error_union_field.Item reaches error_union_field.Item, which declares field_rules or validateSelf that would be skipped", .row = "G-17" },
    .{ .file = "src/validator/testdata/compile_errors/vector_field.zig", .expect = "validator: vector_field.Bad.x: vectors are not walked; @Vector(2, *const vector_field.Item) reaches vector_field.Item, which declares field_rules or validateSelf that would be skipped", .row = "G-18" },
    .{ .file = "src/validator/testdata/compile_errors/recursive_slice.zig", .expect = "validator: recursive_slice.Bad.x[]: recursive types are not supported; recursive_slice.Bad contains itself", .row = "G-19" },
    .{ .file = "src/validator/testdata/compile_errors/recursive_mutual.zig", .expect = "validator: recursive_mutual.Child.x[]: recursive types are not supported; recursive_mutual.Bad contains itself", .row = "variant of G-19" },
    .{ .file = "src/validator/testdata/compile_errors/not_pointer.zig", .expect = "validator: pass a pointer to the value (&value), got not_pointer.Item", .row = "G-21" },
    .{ .file = "src/validator/testdata/compile_errors/check_all_not_pointer.zig", .expect = "validator: pass a pointer to the value (&value), got check_all_not_pointer.Item", .row = "variant of G-21" },
    .{ .file = "src/validator/testdata/compile_errors/bare_slice.zig", .expect = "validator: pass a pointer to the value (&value), got []const bare_slice.User; pass &slice, not the slice", .row = "G-22" },
    .{ .file = "src/validator/testdata/compile_errors/each_not_last.zig", .expect = "validator: each_not_last.Bad.field_rules.x: each must be the last rule", .row = "G-23" },
    .{ .file = "src/validator/testdata/compile_errors/each_twice.zig", .expect = "validator: each_twice.Bad.field_rules.x: each appears twice; put all item rules into one v.each(.{ ... })", .row = "G-24" },
};
