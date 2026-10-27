//! End-to-end tests of zefir-scheduler against the mongod servers of the
//! repository's docker-compose.yml, profile `mongo`: mongo-plain,
//! mongo-stall and mongo-restart. Every scenario runs on zio with one
//! executor and again with four, under a time limit, and sees only
//! `std.Io`.
//!
//! Every database that the tests make is named `scheduler_…`, so that it
//! never meets those of tests/mongo and tests/odm: `freshName` gives a new
//! one, and each test drops what it made.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const zio = @import("zio");
const core = @import("core");
const bson = @import("mongo-bson");
const mongo = @import("mongo");

/// The servers of docker-compose.yml.
pub const servers = struct {
    /// mongo-plain: no authentication, test commands on.
    pub const plain = "mongodb://127.0.0.1:27117";
    /// mongo-stall: the tests pause it by its container name, so that it
    /// stops answering.
    pub const stall = "mongodb://127.0.0.1:27119";
    pub const stall_container = "zefir-mongo-e2e-stall";
    /// mongo-restart: the tests restart it by its container name.
    pub const restart = "mongodb://127.0.0.1:27120";
    pub const restart_container = "zefir-mongo-e2e-restart";
};

/// How long one scenario may take on one runtime: the conformance suite
/// waits for the TTL monitor of mongod, and its checks have their own
/// limits.
const time_limit: Io.Duration = .fromSeconds(300);

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
/// instead of hanging it.
fn withinTimeLimit(io: Io, comptime scenario: fn (Io) anyerror!void) anyerror!void {
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

/// A context whose deadline is `duration` from now.
pub fn within(io: Io, duration: Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), duration));
}

var names: std.atomic.Value(u32) = .init(0);

/// `scheduler_<prefix>_<n>` in `buffer`: a database that no other one of
/// the run has, n counting from 1. A run that died may have left one of
/// the name: drop it before use.
pub fn freshName(buffer: []u8, prefix: []const u8) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buffer, "scheduler_{s}_{d}", .{ prefix, names.fetchAdd(1, .monotonic) + 1 });
}

/// A client of a server for what the tests do to it themselves: drop
/// databases, set parameters. Open it in place, on the `io` of the
/// scenario, and `close` it.
pub const Admin = struct {
    client: mongo.Client,
    ids: bson.ObjectId.Generator,

    pub fn open(a: *Admin, io: Io, uri: []const u8) !void {
        a.client = try .init(testing.allocator, io, .{ .uri = uri });
        errdefer a.client.deinit();
        a.ids = .init(io);
        var d: mongo.Diagnostics = .{};
        a.client.connect(io, within(io, .fromSeconds(30)), &d) catch |err| {
            std.debug.print("connect to {s}: {t}: {s}\n", .{ uri, err, d.message() });
            return err;
        };
    }

    pub fn close(a: *Admin) void {
        a.client.deinit();
    }

    /// Drops the database `name`; one that is not there is no error.
    pub fn dropDatabase(a: *Admin, io: Io, name: []const u8) !void {
        try a.at(name).drop(io, .of(within(io, .fromSeconds(30))), .{ .allocator = testing.allocator });
    }

    /// Runs `body` in `database`, and fails with the server's reason.
    pub fn command(a: *Admin, io: Io, database: []const u8, body: anytype) !void {
        var d: mongo.Diagnostics = .{};
        const reply = a.at(database).runCommand(io, .of(within(io, .fromSeconds(30))), body, .{ .allocator = testing.allocator, .diagnostics = &d }) catch |err| {
            std.debug.print("a command in {s}: {t}: {s}\n", .{ database, err, d.message() });
            return err;
        };
        reply.deinit();
    }

    fn at(a: *Admin, name: []const u8) mongo.Database {
        return .init(&a.client, name, &a.ids);
    }
};

/// Runs `docker` with `args` on std's test `Io`, whatever runtime the test
/// is on, and fails unless it succeeds. From a task of zio it holds that
/// task's executor until docker returns.
pub fn docker(args: []const []const u8) !void {
    var argv: [8][]const u8 = undefined;
    argv[0] = "docker";
    @memcpy(argv[1..][0..args.len], args);
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv[0 .. args.len + 1] });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    if (!result.term.success()) {
        std.debug.print("docker {s} failed: {s}\n", .{ args[0], result.stderr });
        return error.DockerFailed;
    }
}

test {
    testing.refAllDecls(@This());
    _ = @import("conformance.zig");
}
