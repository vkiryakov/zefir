//! End-to-end tests of zefir-odm against the mongod servers of the
//! repository's docker-compose.yml, profile `mongo`: mongo-plain and
//! mongo-auth. Every scenario runs on zio with one executor and again with
//! four, under a time limit, and sees only `std.Io`.
//!
//! Every database and user that the tests make is named `odm_…`, so that
//! they never meet those of tests/mongo: `freshName` gives a new one, and
//! each test drops what it made, through an `Admin`.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const zio = @import("zio");
const core = @import("core");
const bson = @import("mongo-bson");
const mongo = @import("mongo");

/// The servers of docker-compose.yml.
pub const servers = struct {
    /// mongo-plain: no authentication, test commands on for fail points.
    pub const plain = "mongodb://127.0.0.1:27117";
    /// mongo-auth: --auth with the users of tests/mongo/init/users.js, test
    /// commands on.
    pub const auth = "mongodb://127.0.0.1:27118";
    /// The root user of mongo-auth, which makes and drops the users of the
    /// tests.
    pub const root_user = "sha256";
    pub const root_password = "sha256-pass";
};

/// How long one scenario may take on one runtime.
const time_limit: Io.Duration = .fromSeconds(120);

/// Runs `scenario` on zio with one executor, then with four.
pub fn onZio(comptime scenario: fn (Io) anyerror!void) !void {
    for ([_]u8{ 1, 4 }) |executors| {
        const runtime = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(executors) });
        defer runtime.deinit();
        withinTimeLimit(runtime.io(), scenario) catch |err| {
            std.debug.print("with {d} executor(s): {t}\n", .{ executors, err });
            return err;
        };
    }
}

/// Runs `scenario` in a task of its own and cancels it when it takes
/// longer than `time_limit`: a server that stops answering fails the test
/// instead of hanging it. The stress tests run their scenarios through it
/// too.
pub fn withinTimeLimit(io: Io, comptime scenario: fn (Io) anyerror!void) anyerror!void {
    const Race = union(enum) {
        done: anyerror!void,
        timer: Io.Cancelable!void,
    };
    var results: [2]Race = undefined;
    var select: Io.Select(Race) = .init(io, &results);
    try select.concurrent(.done, scenario, .{io});
    select.concurrent(.timer, Io.sleep, .{ io, time_limit, .awake }) catch |err| {
        while (select.cancel()) |_| {}
        return err;
    };
    const first = try select.await();
    while (select.cancel()) |_| {}
    return switch (first) {
        .done => |result| result,
        .timer => error.TestTimedOut,
    };
}

/// A context whose deadline is `duration` from now, for the calls of odm.
pub fn within(io: Io, duration: Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), duration));
}

var names: std.atomic.Value(u32) = .init(0);

/// `odm_<prefix>_<n>` in `buffer`: a name for a database or a user that no
/// other one of the run has, with n counting from 1. A run that died may
/// have left one of the name: drop it before use.
pub fn freshName(buffer: []u8, prefix: []const u8) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buffer, "odm_{s}_{d}", .{ prefix, names.fetchAdd(1, .monotonic) + 1 });
}

/// A client for what the tests do to a server itself: drop databases, make
/// and drop users, configure the fail point `failCommand`. Open it in
/// place, on the `io` of the scenario, and `close` it.
pub const Admin = struct {
    client: mongo.Client,
    ids: bson.ObjectId.Generator,

    /// A client of mongo-plain, without a user.
    pub fn openPlain(a: *Admin, io: Io) !void {
        return a.open(io, servers.plain, null);
    }

    /// A client of mongo-auth, as its root user.
    pub fn openAuth(a: *Admin, io: Io) !void {
        return a.open(io, "mongodb://" ++ servers.root_user ++ "@127.0.0.1:27118/admin", servers.root_password);
    }

    fn open(a: *Admin, io: Io, uri: []const u8, password: ?[]const u8) !void {
        a.client = try .init(testing.allocator, io, .{ .uri = uri, .password = password });
        errdefer a.client.deinit();
        a.ids = .init(io);
        var d: mongo.Diagnostics = .{};
        a.client.connect(io, op(io).ctx, &d) catch |err| {
            std.debug.print("connect to {s}: {t}: {s}\n", .{ uri, err, d.message() });
            return err;
        };
    }

    pub fn close(a: *Admin) void {
        a.client.deinit();
    }

    /// Drops the database `name`; one that is not there is no error.
    pub fn dropDatabase(a: *Admin, io: Io, name: []const u8) !void {
        try a.at(name).drop(io, op(io), .{ .allocator = testing.allocator });
    }

    /// `dropDatabase` for a `defer` at the end of a test: a failure is
    /// printed, not returned.
    pub fn dropDatabaseAtEnd(a: *Admin, io: Io, name: []const u8) void {
        a.dropDatabase(io, name) catch |err| std.debug.print("drop of the database {s}: {t}\n", .{ name, err });
    }

    /// Makes `user` with `password` in `database`, with `roles`: a list of
    /// `.{ .role = "readWrite", .db = "odm_a" }`.
    pub fn createUser(a: *Admin, io: Io, database: []const u8, user: []const u8, password: []const u8, roles: anytype) !void {
        try a.command(io, database, .{ .createUser = user, .pwd = password, .roles = roles });
    }

    /// `createUser`, after the drop of a user of the name that a run that
    /// died left.
    pub fn freshUser(a: *Admin, io: Io, database: []const u8, user: []const u8, password: []const u8, roles: anytype) !void {
        try a.dropUserIfAny(io, database, user);
        try a.createUser(io, database, user, password, roles);
    }

    pub fn dropUser(a: *Admin, io: Io, database: []const u8, user: []const u8) !void {
        try a.command(io, database, .{ .dropUser = user });
    }

    /// Drops `user` of `database`; one that is not there (code 11,
    /// UserNotFound) is no error.
    pub fn dropUserIfAny(a: *Admin, io: Io, database: []const u8, user: []const u8) !void {
        var d: mongo.Diagnostics = .{};
        const reply = a.at(database).runCommand(io, op(io), .{ .dropUser = user }, .{ .allocator = testing.allocator, .diagnostics = &d }) catch |err| {
            if (err == error.CommandFailed and d.server != null and d.server.?.code == 11) return;
            std.debug.print("the drop of the user {s} of {s}: {t}: {s}\n", .{ user, database, err, d.message() });
            return err;
        };
        reply.deinit();
    }

    /// `dropUserIfAny` for a `defer` at the end of a test: a failure is
    /// printed, not returned.
    pub fn dropUserAtEnd(a: *Admin, io: Io, database: []const u8, user: []const u8) void {
        a.dropUserIfAny(io, database, user) catch {};
    }

    /// Gives `user` of `database` a new password, in place: the server
    /// refuses the old one from now on, to every new connection.
    pub fn changePassword(a: *Admin, io: Io, database: []const u8, user: []const u8, password: []const u8) !void {
        try a.command(io, database, .{ .updateUser = user, .pwd = password });
    }

    /// The collection `name` of `database`, for what the tests write and
    /// read past odm, as another writer would.
    pub fn collection(a: *Admin, database: []const u8, name: []const u8) mongo.Collection {
        return a.at(database).collection(name);
    }

    /// Configures `failCommand` to act on the next command that `data`
    /// names, once: `.{ .failCommands = .{"find"}, .appName = app,
    /// .blockConnection = true, .blockTimeMS = 5000 }`. The server needs
    /// enableTestCommands=1.
    pub fn failPoint(a: *Admin, io: Io, data: anytype) !void {
        try a.command(io, "admin", .{ .configureFailPoint = "failCommand", .mode = .{ .times = 1 }, .data = data });
    }

    pub fn failPointOff(a: *Admin, io: Io) void {
        a.command(io, "admin", .{ .configureFailPoint = "failCommand", .mode = "off" }) catch {};
    }

    fn command(a: *Admin, io: Io, database_name: []const u8, body: anytype) !void {
        var d: mongo.Diagnostics = .{};
        const reply = a.at(database_name).runCommand(io, op(io), body, .{ .allocator = testing.allocator, .diagnostics = &d }) catch |err| {
            std.debug.print("a command in {s}: {t}: {s}\n", .{ database_name, err, d.message() });
            return err;
        };
        reply.deinit();
    }

    fn at(a: *Admin, name: []const u8) mongo.Database {
        return .init(&a.client, name, &a.ids);
    }
};

/// The context of a call of an `Admin`, and of the calls that the tests
/// make through its collections: 30 s.
pub fn op(io: Io) mongo.OperationContext {
    return .of(within(io, .fromSeconds(30)));
}

test {
    testing.refAllDecls(@This());
    _ = @import("conformance.zig");
    _ = @import("tenants.zig");
    _ = @import("rotation.zig");
    _ = @import("documents.zig");
    _ = @import("lifecycle.zig");
}

test "an Admin of mongo-auth makes a user that writes to its database, and drops both" {
    try onZio(userRound);
}

fn userRound(io: Io) !void {
    var admin: Admin = undefined;
    try admin.openAuth(io);
    defer admin.close();
    var buffer: [64]u8 = undefined;
    const name = try freshName(&buffer, "user");
    try admin.dropDatabase(io, name);
    try admin.createUser(io, name, name, "odm-user-pass", .{.{ .role = "readWrite", .db = name }});
    var uri_buffer: [128]u8 = undefined;
    const uri = try std.fmt.bufPrint(&uri_buffer, "mongodb://{s}@127.0.0.1:27118/{s}", .{ name, name });
    {
        var client: mongo.Client = try .init(testing.allocator, io, .{ .uri = uri, .password = "odm-user-pass" });
        defer client.deinit();
        try client.connect(io, op(io).ctx, null);
        var ids: bson.ObjectId.Generator = .init(io);
        const db: mongo.Database = .init(&client, name, &ids);
        var inserted = try db.collection("things").insertOne(io, op(io), .{ .n = @as(i32, 1) }, .{ .allocator = testing.allocator });
        inserted.deinit(testing.allocator);
    }
    try admin.dropUser(io, name, name);
    try admin.dropDatabase(io, name);
}
