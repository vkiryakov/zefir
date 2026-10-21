//! The tests of zefir.App's graph and of `init`: modules, providers,
//! values, the order of creation and the rollback of a failed `init`.
const std = @import("std");
const testing = std.testing;
const zapp = @import("../../app.zig");
const mocks = @import("mocks.zig");

// Providers built by filling their fields, by an init, and by an init that
// takes a struct of dependencies; a value taken by copy.

const Repo = struct {
    config: *const mocks.Config,
    rec: *mocks.Recorder,
    hits: u32 = 0,
    comptime tag: u8 = 1,
};

const Service = struct {
    repo: *Repo,
    logger: *const mocks.Logger,

    pub fn init(repo: *Repo, logger: *const mocks.Logger) Service {
        return .{ .repo = repo, .logger = logger };
    }
};

const Report = struct {
    repo: *Repo,
    service: *Service,
    gpa: std.mem.Allocator,
    io: std.Io,
    status: *const zapp.Status,

    pub fn init(deps: struct { repo: *Repo, service: *Service, gpa: std.mem.Allocator, io: std.Io, status: *const zapp.Status }) Report {
        return .{ .repo = deps.repo, .service = deps.service, .gpa = deps.gpa, .io = deps.io, .status = deps.status };
    }
};

const Copy = struct { logger: mocks.Logger };

const Basics = struct {
    pub const module: zapp.Module = .{
        .providers = &.{ Repo, Service, Report, Copy },
        .values = &.{ *mocks.Recorder, *const mocks.Config, *const mocks.Logger },
    };
};

test "providers: fields, init params and a struct of dependencies; values by type, in any order" {
    var rec: mocks.Recorder = .init(testing.io);
    const config: mocks.Config = .{ .port = 9090 };
    var logger: mocks.Logger = .{ .id = 7 };
    var app = try zapp.App(Basics).init(testing.allocator, testing.io, .{ &logger, &rec, &config }, .{});
    defer app.deinit();
    try testing.expect(app.get(Repo).config == &config);
    try testing.expect(app.get(Repo).rec == &rec);
    try testing.expect(app.get(Service).repo == app.get(Repo));
    try testing.expect(app.get(Service).logger == &logger);
    try testing.expect(app.get(Report).service == app.get(Service));
    try testing.expect(app.get(Report).status == &app.internal.block.status);
    try testing.expect(app.get(Report).gpa.ptr == testing.allocator.ptr);
    try testing.expectEqual(0, app.get(Repo).hits); // a field with a default is no dependency
    logger.id = 8;
    try testing.expectEqual(7, app.get(Copy).logger.id); // a value taken by copy
    try testing.expectEqualStrings("build order: Basics.Repo, Basics.Service, Basics.Report, Basics.Copy", app.internal.build_order);
}

/// A provider whose init records its module.
fn Recording(comptime who: []const u8) type {
    return struct {
        rec: *mocks.Recorder,

        pub fn init(rec: *mocks.Recorder) @This() {
            rec.add("init", who);
            return .{ .rec = rec };
        }
    };
}

const C = struct {
    pub const module: zapp.Module = .{ .providers = &.{Recording("C")} };
};
const A = struct {
    pub const module: zapp.Module = .{ .imports = &.{C}, .providers = &.{Recording("A")} };
};
const B = struct {
    pub const module: zapp.Module = .{ .imports = &.{C}, .providers = &.{Recording("B")} };
};
const Diamond = struct {
    pub const module: zapp.Module = .{
        .imports = &.{ A, B },
        .providers = &.{Recording("Root")},
        .values = &.{*mocks.Recorder},
    };
};

test "imports come first, depth-first, each module once" {
    var rec: mocks.Recorder = .init(testing.io);
    var app = try zapp.App(Diamond).init(testing.allocator, testing.io, .{&rec}, .{});
    defer app.deinit();
    try rec.expect("init", &.{ "C", "A", "B", "Root" });
}

const Top = struct { mid: *Mid };
const Mid = struct { low: *Low };
const Low = struct { rec: *mocks.Recorder };
const Free = struct { rec: *mocks.Recorder };

const Ordered = struct {
    pub const module: zapp.Module = .{
        .providers = &.{ Top, Mid, Low, Free },
        .values = &.{*mocks.Recorder},
    };
};

test "the order inside a module follows dependencies; ties keep the list order" {
    var rec: mocks.Recorder = .init(testing.io);
    var app = try zapp.App(Ordered).init(testing.allocator, testing.io, .{&rec}, .{});
    defer app.deinit();
    try testing.expectEqualStrings("build order: Ordered.Low, Ordered.Mid, Ordered.Top, Ordered.Free", app.internal.build_order);
    try testing.expect(app.get(Top).mid == app.get(Mid));
    try testing.expect(app.get(Mid).low == app.get(Low));
}

/// A provider that records its init and its deinit; its init fails when `fails`.
fn Built(comptime who: []const u8, comptime fails: bool) type {
    return struct {
        rec: *mocks.Recorder,

        pub fn init(rec: *mocks.Recorder) !@This() {
            rec.add("init", who);
            if (fails) return error.InitFailed;
            return .{ .rec = rec };
        }

        pub fn deinit(self: *@This()) void {
            self.rec.add("deinit", who);
        }
    };
}

const Rollback = struct {
    pub const module: zapp.Module = .{
        .providers = &.{ Built("First", false), Built("Second", false), Built("Third", true), Built("Fourth", false) },
        .values = &.{*mocks.Recorder},
    };
};

test "an init that fails destroys what it built, in reverse, and returns its error" {
    var rec: mocks.Recorder = .init(testing.io);
    try testing.expectError(error.InitFailed, zapp.App(Rollback).init(testing.allocator, testing.io, .{&rec}, .{}));
    try rec.expect("init", &.{ "First", "Second", "Third" });
    try rec.expect("deinit", &.{ "Second", "First" });
}

const Probe = struct {
    status: *const zapp.Status,
    rec: *mocks.Recorder,
};

const Probed = struct {
    pub const module: zapp.Module = .{
        .providers = &.{Probe},
        .values = &.{*mocks.Recorder},
    };
};

/// Returns the App by value: the App moves, its block does not.
fn make(rec: *mocks.Recorder) !zapp.App(Probed) {
    return zapp.App(Probed).init(testing.allocator, testing.io, .{rec}, .{});
}

test "a bean's lifecycle methods make its entry; deinit(self) and deinit(self, io) both run" {
    const Plain = struct { rec: *mocks.Recorder };
    const Full = struct {
        rec: *mocks.Recorder,

        pub fn start(_: *@This(), _: std.Io) !void {}
        pub fn wait(_: *@This(), _: std.Io) !void {}
        pub fn requestStop(_: *@This(), _: std.Io) void {}
        pub fn shutdown(_: *@This(), _: std.Io, _: std.Io.Clock.Timestamp) !void {}
        pub fn isReady(_: *const @This()) bool {
            return true;
        }
        pub fn deinit(self: *@This(), _: std.Io) void {
            self.rec.add("deinit", "Full");
        }
    };
    const Short = struct {
        rec: *mocks.Recorder,

        pub fn deinit(self: *@This()) void {
            self.rec.add("deinit", "Short");
        }
    };
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ Plain, Full, Short }, .values = &.{*mocks.Recorder} };
    };
    var rec: mocks.Recorder = .init(testing.io);
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{&rec}, .{});
    {
        errdefer app.deinit();
        const entries = &app.internal.block.entries;
        try testing.expectEqual(2, entries.len);
        try testing.expectEqualStrings("Root.Full", entries[0].name);
        try testing.expectEqualStrings("Root.Short", entries[1].name);
        try testing.expect(entries[0].ptr == @as(*anyopaque, app.get(Full)));
        const vt = entries[0].vtable;
        try testing.expect(vt.start != null and vt.wait != null and vt.requestStop != null);
        try testing.expect(vt.shutdown != null and vt.isReady != null and vt.deinit != null);
        try testing.expect(entries[1].vtable.start == null and entries[1].vtable.deinit != null);
    }
    app.deinit();
    try rec.expect("deinit", &.{ "Short", "Full" });
}

test "a marker type: App builds and frees it, and drives nothing else" {
    // A transport of rpc: its start and isReady belong to the rpc server.
    const Transport = struct {
        rec: *mocks.Recorder,

        pub const app_lifecycle = false;

        pub fn start(_: *@This(), _: std.Io, _: u8) !void {}
        pub fn isReady(_: *@This()) bool {
            return true;
        }
        pub fn deinit(self: *@This(), _: std.Io) void {
            self.rec.add("deinit", "Transport");
        }
    };
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{Transport}, .values = &.{*mocks.Recorder} };
    };
    var rec: mocks.Recorder = .init(testing.io);
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{&rec}, .{});
    {
        errdefer app.deinit();
        const entries = &app.internal.block.entries;
        try testing.expectEqual(1, entries.len);
        try testing.expect(entries[0].vtable.start == null);
        try testing.expect(entries[0].vtable.isReady == null);
        try testing.expect(entries[0].vtable.deinit != null);
    }
    app.deinit();
    try rec.expect("deinit", &.{"Transport"});
}

test "*const Status stays valid when the App value moves" {
    var rec: mocks.Recorder = .init(testing.io);
    var app = try make(&rec);
    defer app.deinit();
    const status = app.get(Probe).status;
    try testing.expect(status == &app.internal.block.status);
    try testing.expectEqual(zapp.State.created, status.state());
    try testing.expect(!status.isReady());
}
