//! What build.zig compiles for the validator's tests, read by
//! `addValidatorTests`. Paths are relative to the repository root and stay
//! inside `src/`, the part of the package that `build.zig.zon` ships, since
//! a client's build runs zefir's build.zig too.

/// A file that must fail to compile with an error whose message is `expect`:
/// the whole text after `error: ` to the end of the line, which starts with
/// "validator: " for the validator's own errors. build.zig matches
/// `error: <expect>` against the end of each error line, so the tail of a
/// longer message does not match. `row` names the catalog row the text
/// comes from ("G-1", or "variant of G-13"), or is "internal" for an error
/// that only a misuse of the module's internals can reach.
pub const Fixture = struct { file: []const u8, expect: []const u8, row: []const u8 };

/// A program that must end in a Debug panic whose stderr contains `stderr`.
/// It declares the root panic handler of panic/self_malformed.zig, which
/// prints `panic: <message>` and exits with code 3: build.zig expects exit
/// code 3, and the default handler aborts instead on Linux and macOS.
pub const PanicRun = struct { file: []const u8, stderr: []const u8 };

/// Tests that use only the public API, compiled as client code: each file may
/// import "validator" and "vtest" (helpers.zig).
pub const test_files = [_][]const u8{
    "src/validator/testdata/walk_test.zig",
    "src/validator/testdata/paths_test.zig",
    "src/validator/testdata/memory_test.zig",
    "src/validator/testdata/guarantees_test.zig",
    "src/validator/testdata/assert_rules_test.zig",
    "src/validator/testdata/self_test.zig",
    "src/validator/testdata/common_test.zig",
    "src/validator/testdata/numbers_test.zig",
    "src/validator/testdata/strings_test.zig",
    "src/validator/testdata/formats_test.zig",
    "src/validator/testdata/encodings_test.zig",
    "src/validator/testdata/identifiers_test.zig",
    "src/validator/testdata/dates_test.zig",
    "src/validator/testdata/lists_test.zig",
    "src/validator/testdata/custom_test.zig",
    "src/validator/testdata/field_types_test.zig",
    "src/validator/testdata/messages_test.zig",
    "src/validator/testdata/catalog_test.zig",
    "src/validator/examples/pages_test.zig",
    "src/validator/examples/all_rules.zig",
    "src/validator/examples/all_rules_test.zig",
};

/// Tests built with ReleaseSafe whatever -Doptimize says, for behaviour that
/// differs between Debug and release builds.
pub const release_test_files = [_][]const u8{
    "src/validator/testdata/release_test.zig",
};

/// Programs built in Debug that must panic with the given text.
pub const panic_runs = [_]PanicRun{
    .{ .file = "src/validator/testdata/panic/self_malformed.zig", .stderr = "validator: self_malformed.Bad.validateSelf returned a malformed violation: field \"nope\" is not a field of self_malformed.Bad" },
    .{ .file = "src/validator/testdata/panic/self_reserved_code.zig", .stderr = "validator: self_reserved_code.Bad.validateSelf returned a malformed violation: code \"validation.fake\" is not a valid custom code" },
    .{ .file = "src/validator/testdata/panic/self_empty_message.zig", .stderr = "validator: self_empty_message.Bad.validateSelf returned a malformed violation: its message is not 1-512 bytes of valid UTF-8" },
    .{ .file = "src/validator/testdata/panic/self_comptime_field.zig", .stderr = "validator: self_comptime_field.Bad.validateSelf returned a malformed violation: field \"version\" is a comptime field of self_comptime_field.Bad; comptime fields are not validated" },
};

/// Compile-error fixtures: compiled only, never run.
pub const compile_errors = @import("compile_errors.zig").list;

/// A golden-vector file, `vectors/<name>.json`, and the rules whose records
/// it holds. The build fails when a listed rule has fewer than 10 records,
/// when a record's rule is not listed, and when a `.json` file in vectors/
/// has no entry here.
pub const VectorFile = struct { name: []const u8, rules: []const []const u8 };

/// The golden-vector files, one per documentation page.
pub const vector_files = [_]VectorFile{
    .{ .name = "common", .rules = &.{ "equals", "notEquals", "oneOf", "noneOf", "empty", "notEmpty" } },
    .{ .name = "numbers", .rules = &.{ "min", "max", "range", "positive", "nonNegative", "negative", "nonPositive", "divisibleBy", "finite" } },
    .{ .name = "lists", .rules = &.{ "minItems", "maxItems", "each", "custom" } },
};

/// A compiled example of src/validator/examples/, by file stem: a program
/// must print exactly `stdout`, a test (`stdout` null) must pass, and
/// README.md shows each file and each output verbatim (readme_test.zig).
pub const Example = struct { name: []const u8, stdout: ?[]const u8 = null, stderr: ?[]const u8 = null };

pub const examples = [_]Example{
    .{ .name = "overview", .stderr = "tags[1]: must not be empty (validation.not_empty)\n" },
    .{ .name = "getting_started", .stdout = "tags[1]: must not be empty (validation.not_empty)\n" },
    .{
        .name = "validate_self",
        .stdout =
        \\bookings[0]: must not be longer than 30 days (bookings.too_long)
        \\bookings[1].end_day: must not be before the start day (bookings.end_before_start)
        \\bookings[2].guests: must be greater than 0 (validation.positive)
        \\
        ,
    },
    .{
        .name = "with_message",
        .stdout =
        \\name: please fill in this field (validation.not_empty)
        \\age: age must be from 18 to 120 (validation.range)
        \\role: role must be one of: admin, editor (validation.one_of)
        \\tags: at most 2 tags (validation.max_items)
        \\height: must be a finite number (validation.finite)
        \\weight: weight must be a number (validation.finite)
        \\
        ,
    },
    .{ .name = "dto_test" },
};
