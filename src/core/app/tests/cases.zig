//! What build.zig compiles for the compile checks of zefir.App, read by
//! `addAppCompileChecks`. Paths are relative to the repository root and
//! stay inside `src/`, the part of the package that `build.zig.zon` ships,
//! since a client's build runs zefir's build.zig too. Each file is
//! application code: a `test` block that imports "core" and names
//! `core.App(Root)` (or calls its `init` or `get`) for a graph that App
//! must refuse.

/// A file that must fail to compile with an error whose message is
/// `expect`: the whole text after `error: ` to the end of the line.
pub const Fixture = struct { file: []const u8, expect: []const u8 };

/// Files in src/core/app/tests/compile_errors/.
pub const compile_errors = [_]Fixture{};
