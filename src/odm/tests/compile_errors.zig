//! Code that must not compile, one test per case of cases.zig, which
//! names the error each one stops with. `addOdmCompileChecks` in
//! build.zig compiles one test at a time, by its name, in a module rooted
//! at src/odm/compile_checks.zig; never import this file elsewhere.
//!
//! The fixtures are declared here, at the top of the file, so that Zig
//! names them `tests.compile_errors.X` in the messages. The public API
//! comes from ../root.zig: this file is in odm's directory, and a file
//! cannot be in two modules.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const odm = @import("../root.zig");
const Client = odm.Client;

/// The methods of the contract for a client of type `T`, which a fixture
/// takes one by one.
fn Methods(comptime T: type) type {
    return struct {
        pub fn connect(_: *T, _: Io, _: core.Context, _: ?*odm.Diagnostics) odm.DriverError!void {}
        pub fn ping(_: *T, _: Io, _: core.Context, _: ?*odm.Diagnostics) odm.DriverError!void {}
        pub fn close(_: *T, _: Io) void {}
        pub fn deinit(_: *T) void {}
        pub fn stats(_: *T) ?Client.PoolStats {
            return null;
        }
        pub fn insert(_: *T, _: Io, _: core.Context, _: *const Client.InsertRequest, _: Client.CallOptions) odm.DriverError!Client.InsertResult {
            return .{ .inserted = 0 };
        }
        pub fn update(_: *T, _: Io, _: core.Context, _: *const Client.UpdateRequest, _: Client.CallOptions) odm.DriverError!Client.UpdateResult {
            return .{ .matched = 0, .modified = 0 };
        }
        pub fn delete(_: *T, _: Io, _: core.Context, _: *const Client.DeleteRequest, _: Client.CallOptions) odm.DriverError!Client.DeleteResult {
            return .{ .deleted = 0 };
        }
        pub fn find(_: *T, _: Io, _: core.Context, _: *const Client.FindRequest, _: Client.CallOptions) odm.DriverError!odm.RawCursor {
            return error.Unavailable;
        }
        pub fn count(_: *T, _: Io, _: core.Context, _: *const Client.CountRequest, _: Client.CallOptions) odm.DriverError!u64 {
            return 0;
        }
    };
}

const NoInsert = struct {
    n: u8 = 0,
    pub const capabilities: odm.Capabilities = .{};
    pub const connect = Methods(NoInsert).connect;
    pub const ping = Methods(NoInsert).ping;
    pub const close = Methods(NoInsert).close;
    pub const deinit = Methods(NoInsert).deinit;
    pub const stats = Methods(NoInsert).stats;
};

test "compile error: a client without insert" {
    var client: NoInsert = .{};
    _ = Client.init(&client);
}

const OtherInsert = struct {
    n: u8 = 0,
    pub const capabilities: odm.Capabilities = .{};
    pub const connect = Methods(OtherInsert).connect;
    pub const ping = Methods(OtherInsert).ping;
    pub const close = Methods(OtherInsert).close;
    pub const deinit = Methods(OtherInsert).deinit;
    pub const stats = Methods(OtherInsert).stats;

    /// Without the options of the call.
    pub fn insert(_: *OtherInsert, _: Io, _: core.Context, _: *const Client.InsertRequest) odm.DriverError!Client.InsertResult {
        return .{ .inserted = 0 };
    }
};

test "compile error: insert of another signature" {
    var client: OtherInsert = .{};
    _ = Client.init(&client);
}

const NoAggregate = struct {
    n: u8 = 0,
    pub const capabilities: odm.Capabilities = .{ .aggregate = true };
    pub const connect = Methods(NoAggregate).connect;
    pub const ping = Methods(NoAggregate).ping;
    pub const close = Methods(NoAggregate).close;
    pub const deinit = Methods(NoAggregate).deinit;
    pub const stats = Methods(NoAggregate).stats;
    pub const insert = Methods(NoAggregate).insert;
    pub const update = Methods(NoAggregate).update;
    pub const delete = Methods(NoAggregate).delete;
    pub const find = Methods(NoAggregate).find;
};

test "compile error: aggregate in the capabilities, without the method" {
    var client: NoAggregate = .{};
    _ = Client.init(&client);
}

const HiddenCount = struct {
    n: u8 = 0,
    pub const capabilities: odm.Capabilities = .{};
    pub const connect = Methods(HiddenCount).connect;
    pub const ping = Methods(HiddenCount).ping;
    pub const close = Methods(HiddenCount).close;
    pub const deinit = Methods(HiddenCount).deinit;
    pub const stats = Methods(HiddenCount).stats;
    pub const insert = Methods(HiddenCount).insert;
    pub const update = Methods(HiddenCount).update;
    pub const delete = Methods(HiddenCount).delete;
    pub const find = Methods(HiddenCount).find;
    pub const count = Methods(HiddenCount).count;
};

test "compile error: the method count, without the capability" {
    var client: HiddenCount = .{};
    _ = Client.init(&client);
}

const SomeClient = struct { n: u8 = 0 };

test "compile error: Client.init of a client by value" {
    const client: SomeClient = .{};
    _ = Client.init(client);
}

test "compile error: Client.init of a constant client" {
    const client: SomeClient = .{};
    _ = Client.init(&client);
}

const NoCapabilities = struct {
    n: u8 = 0,
    pub const connect = Methods(NoCapabilities).connect;
};

test "compile error: a client without capabilities" {
    var client: NoCapabilities = .{};
    _ = Client.init(&client);
}

const NamelessDriver = struct {
    n: u8 = 0,

    pub fn open(_: *NamelessDriver, _: Io, _: *const odm.ConnectionConfig) odm.Driver.OpenError!Client {
        return error.Unsupported;
    }
};

test "compile error: a driver without a name" {
    var driver: NamelessDriver = .{};
    _ = odm.Driver.init(&driver);
}

const DriverWithoutOpen = struct {
    n: u8 = 0,
    pub const name = "without-open";
};

test "compile error: a driver without open" {
    var driver: DriverWithoutOpen = .{};
    _ = odm.Driver.init(&driver);
}

const CursorWithoutNext = struct {
    n: u8 = 0,

    pub fn deinit(_: *CursorWithoutNext, _: Io) void {}
};

test "compile error: a cursor without next" {
    var cursor: CursorWithoutNext = .{};
    _ = odm.RawCursor.init(&cursor);
}
