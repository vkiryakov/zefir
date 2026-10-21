//! Debug build: `App.run` and App's log, in a process of their own.
//! build.zig runs this program in three modes and checks the exit code and
//! the lines on stderr:
//!
//! - `stop`: a task requests the stop once the App runs, and Deaf's
//!   shutdown never returns: run writes that Root.Deaf did not stop in time
//!   and ends the process with code 1;
//! - `rollback`: Second's start fails, and First's shutdown never returns:
//!   the same, for Root.First;
//! - `breaks`: Broken stops by itself once the App runs, and Fragile's
//!   shutdown fails: run returns error.Broken, and the program exits with
//!   code 2.
//!
//! A panic exits with code 3, and a run longer than ten seconds with 4.
const std = @import("std");
const core = @import("core");

/// Prints the panic message and exits with code 3 instead of aborting.
pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

/// App's log, one plain line per record, so that build.zig can match it.
pub const std_options: std.Options = .{ .logFn = plainLog };

fn plainLog(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    std.debug.print(level.asText() ++ "(" ++ @tagName(scope) ++ "): " ++ format ++ "\n", args);
}

const Mode = enum { stop, rollback, breaks };
var mode: Mode = .stop;

/// No one opens it: a shutdown that waits on it never returns.
var never: std.Io.Event = .unset;

const First = struct {
    pub fn start(_: *First, _: std.Io) !void {}
    pub fn shutdown(_: *First, io: std.Io, _: std.Io.Clock.Timestamp) !void {
        if (mode == .rollback) never.waitUncancelable(io);
    }
};

const Second = struct {
    pub fn start(_: *Second, _: std.Io) !void {
        return error.StartFailed;
    }
    pub fn shutdown(_: *Second, _: std.Io, _: std.Io.Clock.Timestamp) !void {}
};

const Deaf = struct {
    pub fn start(_: *Deaf, _: std.Io) !void {}
    pub fn shutdown(_: *Deaf, io: std.Io, _: std.Io.Clock.Timestamp) !void {
        never.waitUncancelable(io);
    }
};

const Fragile = struct {
    pub fn shutdown(_: *Fragile, _: std.Io, _: std.Io.Clock.Timestamp) !void {
        return error.ShutdownFailed;
    }
};

/// Breaks once the App runs, as a server whose transport fails.
const Broken = struct {
    status: *const core.app.Status,

    pub fn wait(broken: *Broken, io: std.Io) !void {
        while (broken.status.state() == .starting) try io.sleep(.fromMilliseconds(1), .awake);
        return error.Broken;
    }
};

const stop_case = struct {
    const Root = struct {
        pub const module: core.app.Module = .{ .providers = &.{ First, Deaf } };
    };
};

const rollback_case = struct {
    const Root = struct {
        pub const module: core.app.Module = .{ .providers = &.{ First, Second } };
    };
};

const breaks_case = struct {
    const Root = struct {
        pub const module: core.app.Module = .{ .providers = &.{ First, Fragile, Broken } };
    };
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    mode = std.meta.stringToEnum(Mode, if (args.len > 1) args[1] else "") orelse {
        std.debug.print("usage: app-run-timeout stop|rollback|breaks\n", .{});
        std.process.exit(64);
    };
    _ = try init.io.concurrent(exitAfter, .{ init.io, std.Io.Duration.fromSeconds(10) });
    switch (mode) {
        .stop => try runApp(stop_case.Root, init, true),
        .rollback => try runApp(rollback_case.Root, init, false),
        .breaks => try runApp(breaks_case.Root, init, false),
    }
}

fn runApp(comptime Root: type, init: std.process.Init, comptime stop_when_running: bool) !void {
    const io = init.io;
    var app = try core.App(Root).init(init.gpa, io, .{}, .{ .shutdown_timeout = .fromMilliseconds(50) });
    if (stop_when_running) _ = try io.concurrent(Stopper(Root).run, .{ io, &app });
    app.run() catch |err| {
        std.debug.print("run returned error.{s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    std.debug.print("run returned\n", .{});
    std.process.exit(0);
}

fn Stopper(comptime Root: type) type {
    return struct {
        /// Requests the stop once the App runs.
        fn run(io: std.Io, app: *core.App(Root)) void {
            while (app.state() != .running) io.sleep(.fromMilliseconds(1), .awake) catch return;
            app.requestStop();
        }
    };
}

/// Ends a run that hangs: exit code 4, instead of a build that never ends.
fn exitAfter(io: std.Io, limit: std.Io.Duration) void {
    io.sleep(limit, .awake) catch return;
    std.debug.print("the program ran longer than its time limit\n", .{});
    std.process.exit(4);
}
