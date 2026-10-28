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

/// What the scenarios of workers share, and the proxy between them and
/// mongod: the stress tests take them from here.
pub const fixture = @import("fixture.zig");
pub const Proxy = @import("Proxy.zig");

/// The servers of docker-compose.yml.
pub const servers = struct {
    /// mongo-plain: no authentication, test commands on.
    pub const plain = "mongodb://127.0.0.1:27117";
    pub const plain_port: u16 = 27117;
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

/// A context whose deadline is `duration` from now.
pub fn within(io: Io, duration: Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), duration));
}

/// `scheduler_<prefix>_<8 hex digits>` in `buffer`: a database that no
/// other one has, of this run or of another. The digits are random, so
/// that a run never meets what a run before it left: a database, or a
/// worker in a process of its own that still polls one.
pub fn freshName(io: Io, buffer: []u8, prefix: []const u8) error{NoSpaceLeft}![]const u8 {
    var bytes: [4]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bufPrint(buffer, "scheduler_{s}_{s}", .{ prefix, &std.fmt.bytesToHex(bytes, .lower) });
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
        (try a.reply(io, database, body)).deinit();
    }

    /// The reply of `body` in `database`, from `testing.allocator`; the
    /// caller `deinit`s it.
    pub fn reply(a: *Admin, io: Io, database: []const u8, body: anytype) !bson.OwnedDocument {
        var d: mongo.Diagnostics = .{};
        return a.at(database).runCommand(io, .of(within(io, .fromSeconds(30))), body, .{ .allocator = testing.allocator, .diagnostics = &d }) catch |err| {
            std.debug.print("a command in {s}: {t}: {s}\n", .{ database, err, d.message() });
            return err;
        };
    }

    /// The collection `name` of `database`, for what the tests write and
    /// read past the store.
    pub fn collection(a: *Admin, database: []const u8, name: []const u8) mongo.Collection {
        return a.at(database).collection(name);
    }

    /// Configures the fail point `failCommand` of the server to act on the
    /// next `times` commands that `data` names: `.{ .failCommands =
    /// .{"update"}, .appName = app, .closeConnection = true }`. The server
    /// needs enableTestCommands=1.
    pub fn failPoint(a: *Admin, io: Io, times: u32, data: anytype) !void {
        try a.command(io, "admin", .{ .configureFailPoint = "failCommand", .mode = .{ .times = @as(i32, @intCast(times)) }, .data = data });
    }

    pub fn failPointOff(a: *Admin, io: Io) void {
        a.command(io, "admin", .{ .configureFailPoint = "failCommand", .mode = "off" }) catch {};
    }

    /// Pings until the server answers, for 30 s at most: after a restart
    /// the connections of the pool are dead, and the pool then opens one
    /// at most every 500 ms.
    pub fn awaitAnswer(a: *Admin, io: Io) !void {
        const began = Io.Clock.awake.now(io);
        while (true) {
            if (a.at("admin").runCommand(io, .of(within(io, .fromSeconds(5))), .{ .ping = 1 }, .{ .allocator = testing.allocator })) |pong| {
                pong.deinit();
                return;
            } else |err| if (began.durationTo(Io.Clock.awake.now(io)).toSeconds() >= 30) return err;
            try io.sleep(.fromMilliseconds(100), .awake);
        }
    }

    fn at(a: *Admin, name: []const u8) mongo.Database {
        return .init(&a.client, name, &a.ids);
    }
};

/// Runs `docker` with `args` and returns what it printed, from
/// `testing.allocator`; fails unless docker succeeds. Docker runs on std's
/// test `Io`, in a task of its own, while the scenario waits for it on
/// `io`: a task of zio that ran it itself would hold its executor for as
/// long as docker runs, and with one executor stop the workers under test.
pub fn docker(io: Io, args: []const []const u8) ![]u8 {
    var argv: [8][]const u8 = undefined;
    argv[0] = "docker";
    @memcpy(argv[1..][0..args.len], args);
    var done: std.atomic.Value(bool) = .init(false);
    var task = try testing.io.concurrent(runDocker, .{ argv[0 .. args.len + 1], &done });
    const canceled = while (!done.load(.acquire)) {
        io.sleep(.fromMilliseconds(10), .awake) catch break true;
    } else false;
    const output = task.await(testing.io);
    if (canceled) {
        if (output) |text| testing.allocator.free(text) else |_| {}
        return error.Canceled;
    }
    return output;
}

fn runDocker(argv: []const []const u8, done: *std.atomic.Value(bool)) ![]u8 {
    defer done.store(true, .release);
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv });
    defer testing.allocator.free(result.stderr);
    errdefer testing.allocator.free(result.stdout);
    if (!result.term.success()) {
        std.debug.print("docker {s} failed: {s}\n", .{ argv[1], result.stderr });
        return error.DockerFailed;
    }
    return result.stdout;
}

/// Pauses `container`: mongod takes what comes and answers nothing.
pub fn pause(io: Io, container: []const u8) !void {
    testing.allocator.free(try docker(io, &.{ "pause", container }));
}

/// Unpauses `container` and waits until its health check passes again,
/// for `zig build e2e` waits for every server to be healthy.
pub fn unpause(io: Io, container: []const u8) !void {
    testing.allocator.free(try docker(io, &.{ "unpause", container }));
    try awaitHealthy(io, container);
}

/// Restarts `container` and waits until it is healthy again: a new
/// mongod, with an empty database, as the services keep their data in
/// memory.
pub fn restart(io: Io, container: []const u8) !void {
    testing.allocator.free(try docker(io, &.{ "restart", container }));
    try awaitHealthy(io, container);
}

/// Waits until the health check of `container` passes, for 60 s at most.
pub fn awaitHealthy(io: Io, container: []const u8) !void {
    const began = Io.Clock.awake.now(io);
    while (true) {
        const status = try docker(io, &.{ "inspect", "--format", "{{.State.Health.Status}}", container });
        defer testing.allocator.free(status);
        if (std.mem.eql(u8, std.mem.trim(u8, status, " \r\n"), "healthy")) return;
        if (began.durationTo(Io.Clock.awake.now(io)).toSeconds() >= 60) return error.TestNeverHealthy;
        try io.sleep(.fromMilliseconds(100), .awake);
    }
}

test {
    testing.refAllDecls(@This());
    _ = @import("conformance.zig");
    _ = @import("explain.zig");
    _ = @import("declared.zig");
    _ = @import("instances.zig");
    _ = @import("takeover.zig");
    _ = @import("kill.zig");
    _ = @import("faults.zig");
}
