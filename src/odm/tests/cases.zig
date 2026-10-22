//! The compile checks of zefir-odm, read by `addOdmCompileChecks` in
//! build.zig. Each case compiles the test of tests/compile_errors.zig
//! whose name holds `name`, and passes only when the build fails with
//! the error `expect`: the whole message after "error: ". A type that
//! tests/compile_errors.zig declares is named `tests.compile_errors.X`.
//!
//! Every name starts with "compile error: ", which no other test of the
//! module holds: the filter of a case matches any test whose name holds
//! it, and the module of the checks holds the tests of odm too.

/// One compile check: the test it compiles and the error it must fail with.
pub const Case = struct { name: []const u8, expect: []const u8 };

const insert = "pub fn insert(self: *@This(), io: std.Io, ctx: core.Context, request: *const odm.Client.InsertRequest, options: odm.Client.CallOptions) odm.DriverError!odm.Client.InsertResult";
const aggregate = "pub fn aggregate(self: *@This(), io: std.Io, ctx: core.Context, request: *const odm.Client.AggregateRequest, options: odm.Client.CallOptions) odm.DriverError!odm.RawCursor";
const open = "pub fn open(self: *@This(), io: std.Io, config: *const odm.ConnectionConfig) odm.Driver.OpenError!odm.Client";
const next = "pub fn next(self: *@This(), io: std.Io, ctx: core.Context, d: ?*odm.Diagnostics) odm.DriverError!?bson.RawDocument";

pub const compile_errors = [_]Case{
    // The driver contract: odm.Client.init.
    .{ .name = "compile error: a client without insert", .expect = "odm.Client.init: tests.compile_errors.NoInsert has no method insert; expected " ++ insert },
    .{ .name = "compile error: insert of another signature", .expect = "odm.Client.init: tests.compile_errors.OtherInsert.insert has another signature; expected " ++ insert },
    .{ .name = "compile error: aggregate in the capabilities, without the method", .expect = "odm.Client.init: tests.compile_errors.NoAggregate.capabilities.aggregate is true, but tests.compile_errors.NoAggregate has no method aggregate; expected " ++ aggregate },
    .{ .name = "compile error: the method count, without the capability", .expect = "odm.Client.init: tests.compile_errors.HiddenCount has a method count, but capabilities.count is false" },
    .{ .name = "compile error: Client.init of a client by value", .expect = "odm.Client.init: pass a pointer to the client, e.g. &client; got tests.compile_errors.SomeClient" },
    .{ .name = "compile error: Client.init of a constant client", .expect = "odm.Client.init: the client must be mutable, declared with var; got *const tests.compile_errors.SomeClient" },
    .{ .name = "compile error: a client without capabilities", .expect = "odm.Client.init: tests.compile_errors.NoCapabilities has no pub const capabilities: odm.Capabilities" },
    // odm.Driver.init and odm.RawCursor.init.
    .{ .name = "compile error: a driver without a name", .expect = "odm.Driver.init: tests.compile_errors.NamelessDriver has no pub const name: []const u8" },
    .{ .name = "compile error: a driver without open", .expect = "odm.Driver.init: tests.compile_errors.DriverWithoutOpen has no method open; expected " ++ open },
    .{ .name = "compile error: a cursor without next", .expect = "odm.RawCursor.init: tests.compile_errors.CursorWithoutNext has no method next; expected " ++ next },
};
