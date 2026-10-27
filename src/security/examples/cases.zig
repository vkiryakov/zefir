//! The examples of README.md, the guide of zefir-security. build.zig builds and
//! runs the programs and the tests, and checks the claims that must not
//! compile; readme_test.zig checks that README.md shows every file as it
//! is, every run as it printed and the message of every claims type that
//! does not compile.

/// A setting of a program, which it reads from the environment with confy.
pub const Setting = struct {
    /// The variable, such as `APP_AUTH_KEY_ID`.
    name: []const u8,
    /// Its value when the build runs the program.
    value: []const u8,
    /// How README.md writes it in the command, when not as `value`.
    shown: ?[]const u8 = null,
};

/// A program of the guide: it signs, verifies and serves in memory, and
/// logs with zefir-log as text.
pub const Program = struct {
    /// The file, without `.zig`.
    name: []const u8,
    /// The settings it reads. README.md shows its run as
    /// `$ <NAME>=<value> ... zig build run`, and the build runs it with
    /// them.
    env: []const Setting = &.{},
};

/// The private key of orders in the runs of this build: Ed25519 in
/// PKCS#8, as `openssl genpkey -algorithm ed25519` writes it. It is
/// published here, so it proves nothing: README.md says never to trust
/// it, and runs the programs with the reader's own key,
/// `"$(cat orders.pem)"`; they print the same with any key.
const orders_key =
    \\-----BEGIN PRIVATE KEY-----
    \\MC4CAQAwBQYDK2VwBCIEIMhtZbAEuSrkg7vHeYU/2RAvkPjq6goubPZ3RsrYBmNR
    \\-----END PRIVATE KEY-----
;

const signing_key: Setting = .{ .name = "APP_AUTH_SIGNING_KEY", .value = orders_key, .shown = "\"$(cat orders.pem)\"" };
const key_id: Setting = .{ .name = "APP_AUTH_KEY_ID", .value = "2026-10" };

/// The programs: `zig build test-security` runs them.
pub const programs = [_]Program{
    .{ .name = "minute", .env = &.{ signing_key, key_id } },
    .{ .name = "orders", .env = &.{ signing_key, key_id, .{ .name = "APP_USERS_ANN", .value = "ann-secret" } } },
};

/// The other files README.md shows as they are: the code of the services
/// and their tests.
pub const files = [_][]const u8{
    "LoginController",
    "auth",
    "errors",
    "OrdersController",
    "auth_test",
    "billing_api",
    "BillingHandler",
    "JwtAuthenticator",
    "rpc_auth_test",
};

/// The tests among `files`: `zig build test-security` runs them. The test of
/// the contract, billing_api, runs with its package.
pub const tests = [_][]const u8{ "auth_test", "rpc_auth_test" };

/// Claims that README.md says do not compile, and the message of each
/// after `error: `. Each file is compile_errors/<name>/auth.zig, named as
/// the file of orders that declares `Claims`, so the message names
/// `auth.Claims`.
pub const CompileError = struct { name: []const u8, expect: []const u8 };

pub const compile_errors = [_]CompileError{
    .{ .name = "exp", .expect = "jwt: auth.Claims.exp: \"exp\" is a registered claim, which jwt sets and checks itself (jwt.Registered); remove the field or give it another claim name" },
    .{ .name = "since", .expect = "jwt: auth.Claims.since: [3]u8 is not a claim type; a claim is bool, an integer, f32, f64, an enum, []const u8 or a struct, alone, as ?T or as []const T" },
};

/// The command README.md shows for a run of `program`.
pub fn command(comptime program: Program) []const u8 {
    comptime var line: []const u8 = "$ ";
    inline for (program.env) |setting| line = line ++ setting.name ++ "=" ++ (setting.shown orelse setting.value) ++ " ";
    return line ++ "zig build run";
}
