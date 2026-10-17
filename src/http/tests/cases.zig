//! What build.zig compiles for the compile checks of zefir-http, read by
//! `addHttpCompileChecks`. Paths are relative to the repository root and
//! stay inside `src/`, the part of the package that `build.zig.zon` ships,
//! since a client's build runs zefir's build.zig too. Each file is client
//! code: a `test` block that imports "http" (and "validator") and calls the
//! API under check.

/// A file that must fail to compile with an error whose message is
/// `expect`. With `whole`, `expect` is the whole text after `error: ` to
/// the end of the line; without it, only the end of the line, for messages
/// that start with a name that depends on the file.
pub const Fixture = struct { file: []const u8, expect: []const u8, whole: bool = true };

/// Files in src/http/tests/compile_errors/.
pub const compile_errors = [_]Fixture{};

/// Files in src/http/tests/compile_ok/ that must compile.
pub const must_compile = [_][]const u8{};
