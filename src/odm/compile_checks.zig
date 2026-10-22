//! The root of the compile checks of zefir-odm, which `addOdmCompileChecks`
//! in build.zig builds once per case of tests/cases.zig. It sits in
//! src/odm/, so that a case may call the internal functions of odm as
//! well as its public API.

test {
    _ = @import("tests/compile_errors.zig");
}
