//! What build.zig compiles for the compile checks of zefir-jwt, read by
//! `addJwtCompileChecks`. Paths are relative to the repository root and
//! stay inside `src/`, the part of the package that `build.zig.zon` ships,
//! since a client's build runs zefir's build.zig too. Each file is client
//! code: a `test` block that imports "jwt" (and "validator") and checks a
//! claims type, with `jwt.assertClaims` or through `verify` and `sign`.

/// A file that must fail to compile with an error whose message is
/// `expect`: the whole text after `error: ` to the end of the line.
pub const Fixture = struct { file: []const u8, expect: []const u8 };

const claim_types = "a claim is bool, an integer, f32, f64, an enum, []const u8 or a struct, alone, as ?T or as []const T";
const registered = "is a registered claim, which jwt sets and checks itself (jwt.Registered); remove the field or give it another claim name";

/// Files in src/jwt/tests/compile_errors/.
pub const compile_errors = [_]Fixture{
    // Types.
    .{ .file = dir ++ "not_struct.zig", .expect = "jwt: u32: claims are a struct, or void when jwt.Registered is enough" },
    .{ .file = dir ++ "unsupported_type.zig", .expect = "jwt: unsupported_type.Claims.codes: [3]u8 is not a claim type; " ++ claim_types },
    .{ .file = dir ++ "pointer.zig", .expect = "jwt: pointer.Claims.counter: *u8 is not a claim type; " ++ claim_types },
    .{ .file = dir ++ "wide_integer.zig", .expect = "jwt: wide_integer.Claims.total: u128 has 128 bits; a claim integer has 1 to 64, such as u64 or i64" },
    .{ .file = dir ++ "double_optional.zig", .expect = "jwt: double_optional.Claims.level: ??u8 is an optional of an optional, which JSON null cannot tell apart; use ?u8" },
    .{ .file = dir ++ "recursive.zig", .expect = "jwt: recursive.Claims.children[]: recursive.Claims contains itself; claims nest only as deep as their type, so give each level a type of its own" },
    // Names.
    .{ .file = dir ++ "registered_name.zig", .expect = "jwt: registered_name.Claims.exp: \"exp\" " ++ registered },
    .{ .file = dir ++ "registered_rename.zig", .expect = "jwt: registered_rename.Claims.issuer: \"iss\" " ++ registered },
    .{ .file = dir ++ "registered_claim_name.zig", .expect = "jwt: registered_claim_name.Claims.audience: \"aud\" " ++ registered },
    .{ .file = dir ++ "names_and_rename.zig", .expect = "jwt: names_and_rename.Claims.is_root: both claim_names and v.rename name the field; keep one of them" },
    .{ .file = dir ++ "empty_name.zig", .expect = "jwt: empty_name.Claims.claim_names.code: a claim name is a non-empty string of UTF-8, such as \"https://shop.example.com/code\"" },
    .{ .file = dir ++ "duplicate_name.zig", .expect = "jwt: duplicate_name.Claims: role and admin_role are both the claim \"role\"; give each field a claim name of its own" },
    .{ .file = dir ++ "name_of_missing_field.zig", .expect = "jwt: name_of_missing_field.Claims.claim_names.is_admin: name_of_missing_field.Claims has no field is_admin" },
    // Rules: the validator's own message.
    .{ .file = dir ++ "bad_rule.zig", .expect = "validator: bad_rule.Claims.field_rules.count: max_length expects a string, field is u64" },
};

const dir = "src/jwt/tests/compile_errors/";

/// Files in src/jwt/tests/compile_ok/ that must compile.
pub const must_compile = [_][]const u8{
    "src/jwt/tests/compile_ok/all_types.zig",
    "src/jwt/tests/compile_ok/void_claims.zig",
    "src/jwt/tests/compile_ok/nested_registered_names.zig",
};
