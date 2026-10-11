//! What build.zig compiles for the validator's tests, read by
//! `addValidatorTests`. Paths are relative to the repository root and stay
//! inside `src/`, the part of the package that `build.zig.zon` ships, since
//! a client's build runs zefir's build.zig too.

/// A file that must fail to compile with an error line that ends in `expect`.
/// `Step.Compile.expect_errors` with `.contains` matches the end of an error
/// line, so `expect` is the whole tail from "validator: ". `row` names the
/// catalog row the text comes from ("G-1", or "variant of G-13").
pub const Fixture = struct { file: []const u8, expect: []const u8, row: []const u8 };

/// A program that must end in a Debug panic whose stderr contains `stderr`.
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
};

/// Compile-error fixtures: compiled only, never run.
pub const compile_errors = @import("compile_errors.zig").list;

/// Golden-vector files in vectors/, by name without ".json".
pub const vector_files = [_][]const u8{};
