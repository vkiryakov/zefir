//! What build.zig compiles for the compile checks of zefir-openapi, read
//! by `addOpenapiCompileChecks`. Paths are relative to the repository root
//! and stay inside `src/`, the part of the package that `build.zig.zon`
//! ships, since a client's build runs zefir's build.zig too. Each file is
//! application code: it imports "zefir", declares its types with their
//! `pub const openapi`, and references those in a `test` block, since Zig
//! compiles only what is used.

/// A file that must fail to compile with an error whose message is
/// `expect`: the whole text after `error: ` to the end of the line.
pub const Fixture = struct { file: []const u8, expect: []const u8 };

/// Files in src/openapi/tests/compile_errors/.
pub const compile_errors = [_]Fixture{};
