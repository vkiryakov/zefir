//! The tests of zefir.App's graph and of `init`: modules, providers,
//! factories, controllers and handlers, values, visibility, the order of
//! creation and the rollback of a failed `init`.
const std = @import("std");
const testing = std.testing;
const zapp = @import("../../app.zig");
const mocks = @import("mocks.zig");
const shop = @import("shop.zig");
const two = @import("two_servers.zig");

test "providers: fields, init params and a struct of dependencies; values by type, in any order" {
    // Built by filling its fields; a field with a default and a comptime field are no dependencies.
    const Repo = struct {
        config: *const mocks.Config,
        rec: *mocks.Recorder,
        hits: u32 = 0,
        comptime tag: u8 = 1,
    };
    // Built by its init, whose params are dependencies.
    const Service = struct {
        repo: *Repo,
        logger: *const mocks.Logger,

        pub fn init(repo: *Repo, logger: *const mocks.Logger) @This() {
            return .{ .repo = repo, .logger = logger };
        }
    };
    // Built by an init that takes a struct of dependencies, built-ins among them.
    const Report = struct {
        repo: *Repo,
        service: *Service,
        gpa: std.mem.Allocator,
        io: std.Io,
        status: *const zapp.Status,

        pub fn init(deps: struct { repo: *Repo, service: *Service, gpa: std.mem.Allocator, io: std.Io, status: *const zapp.Status }) @This() {
            return .{ .repo = deps.repo, .service = deps.service, .gpa = deps.gpa, .io = deps.io, .status = deps.status };
        }
    };
    // A value taken by copy.
    const Copy = struct { logger: mocks.Logger };
    const Basics = struct {
        pub const module: zapp.Module = .{
            .providers = &.{ Repo, Service, Report, Copy },
            .values = &.{ *mocks.Recorder, *const mocks.Config, *const mocks.Logger },
        };
    };
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

fn expectNames(expected: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try testing.expectEqualStrings(e, g);
}

test "the shop of design §3: build order, shared beans, Controllers and Handlers" {
    var rec: mocks.Recorder = .init(testing.io);
    const config: mocks.Config = .{};
    // A value with a deinit: App must not destroy it.
    const logger: mocks.Logger = .{ .id = 1, .rec = &rec };
    var app = try zapp.App(shop.AppModule).init(testing.allocator, testing.io, .{ &rec, &config, &logger }, .{});
    {
        errdefer app.deinit();
        try testing.expectEqualStrings("build order: InfraModule.Generator, InfraModule.Mongo.mongoClient, InfraModule.Mongo.shopDb, " ++
            "InfraModule.Mongo.analyticsDb, InfraModule.Nats.natsClient, InfraModule.Nats.bus, UsersModule.UserRepository, " ++
            "UsersModule.UserService, UsersModule.UsersController, OrdersModule.OrderRepository, OrdersModule.OrderService, " ++
            "OrdersModule.OrdersController, OrdersModule.OrdersHandler, AppModule.HealthController, AppModule.Servers.httpServer, " ++
            "AppModule.Servers.rpcServer", app.internal.build_order);
        // One bean per type, shared through exports.
        try testing.expect(app.get(shop.OrderService).users == app.get(shop.UserService));
        try testing.expect(app.get(shop.UserRepository).db == app.get(shop.ShopDb));
        try testing.expect(app.get(shop.OrderRepository).analytics == app.get(shop.AnalyticsDb));
        try testing.expectEqualStrings("shop", app.get(shop.ShopDb).db.name);
        try testing.expectEqualStrings("analytics", app.get(shop.AnalyticsDb).db.name);
        try testing.expect(app.get(shop.ShopDb).db.ids == app.get(mocks.mongo.bson.ObjectId.Generator));
        // Controllers(AppModule) and Handlers(AppModule): modules in creation order, the root's own last.
        const server = app.get(mocks.http.Server);
        try expectNames(&.{ "UsersController", "OrdersController", "HealthController" }, server.names);
        try testing.expect(server.item(shop.UsersController, 0) == app.get(shop.UsersController));
        try testing.expect(server.item(shop.HealthController, 2) == app.get(shop.HealthController));
        // A private bean, seen by its module's controller.
        try testing.expect(app.get(shop.UsersController).repo == app.get(shop.UserRepository));
        try expectNames(&.{"OrdersHandler"}, app.get(mocks.rpc.Server).names);
        try testing.expect(app.get(mocks.rpc.Server).item(shop.OrdersHandler, 0).service == app.get(shop.OrderService));
        try testing.expect(app.get(shop.HealthController).status == &app.internal.block.status);
    }
    app.deinit();
    // In reverse creation order; the transport too, which only its deinit
    // makes an entry. The logger, a value, is not destroyed.
    try rec.expect("deinit", &.{ "rpc.Server", "http.Server", "Transport", "nats.Client", "mongo.Client" });
}

test "a provider takes a factory result of its own module" {
    const Database = struct { name: []const u8 };
    const Repo = struct { db: *Database };
    const Tools = struct {
        pub fn database() Database {
            return .{ .name = "local" };
        }
    };
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{Repo}, .factories = &.{Tools} };
    };
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{}, .{});
    defer app.deinit();
    try testing.expectEqualStrings("build order: Root.Tools.database, Root.Repo", app.internal.build_order);
    try testing.expect(app.get(Repo).db == app.get(Database));
}

const ReportService = struct {
    db: *shop.ShopDb,
    orders: *shop.OrderService,
};

/// Imports only OrdersModule, which re-exports InfraModule's ShopDb.
const Reports = struct {
    pub const module: zapp.Module = .{
        .imports = &.{shop.OrdersModule},
        .providers = &.{ReportService},
        .values = &.{ *mocks.Recorder, *const mocks.Config, *const mocks.Logger },
    };
};

test "a re-export passes one bean on" {
    var rec: mocks.Recorder = .init(testing.io);
    const config: mocks.Config = .{};
    const logger: mocks.Logger = .{ .id = 1 };
    var app = try zapp.App(Reports).init(testing.allocator, testing.io, .{ &rec, &config, &logger }, .{});
    defer app.deinit();
    try testing.expect(app.get(ReportService).db == app.get(shop.ShopDb));
    try testing.expect(app.get(ReportService).orders == app.get(shop.OrderService));
}

test "Controllers and Handlers: imports first, the root's own last, structural" {
    comptime {
        std.debug.assert(zapp.Controllers(shop.UsersModule) == @Tuple(&.{*shop.UsersController}));
        std.debug.assert(zapp.Controllers(shop.AppModule) == @Tuple(&.{ *shop.UsersController, *shop.OrdersController, *shop.HealthController }));
        std.debug.assert(zapp.Handlers(shop.AppModule) == @Tuple(&.{*shop.OrdersHandler}));
        // A module's tuple holds the controllers of every module it reaches.
        std.debug.assert(zapp.Controllers(shop.OrdersModule) == @Tuple(&.{ *shop.UsersController, *shop.OrdersController }));
        // Structural: two modules that reach the same controllers give one type.
        std.debug.assert(zapp.Controllers(shop.InfraModule) == zapp.Handlers(shop.UsersModule));
    }
}

/// Field-less beans: zero-size, as a health controller without a status is.
const Nothing = struct {};

const Ping = struct {
    pub const http_routes = .{"GET /ping"};

    pub fn ping(_: *Ping) u32 {
        return 7;
    }
};

const Pong = struct {
    pub const rpc_handler = .{ .api = "pong.v1" };

    pub fn pong(_: *Pong) u32 {
        return 8;
    }
};

const Tiny = struct {
    pub const module: zapp.Module = .{
        .providers = &.{Nothing},
        .factories = &.{Servers},
        .controllers = &.{Ping},
        .handlers = &.{Pong},
        .values = &.{*mocks.Recorder},
    };

    pub const Servers = struct {
        pub fn httpServer(gpa: std.mem.Allocator, rec: *mocks.Recorder, controllers: zapp.Controllers(Tiny)) !mocks.http.Server {
            return .init(gpa, rec, .{ .controllers = controllers });
        }
        pub fn rpcServer(gpa: std.mem.Allocator, rec: *mocks.Recorder, handlers: zapp.Handlers(Tiny)) !mocks.rpc.Server {
            return .init(gpa, rec, .{ .handlers = handlers });
        }
    };
};

test "field-less controllers, handlers and providers: the server calls through its pointers" {
    comptime std.debug.assert(@sizeOf(Nothing) == 0 and @sizeOf(Ping) == 0 and @sizeOf(Pong) == 0);
    var rec: mocks.Recorder = .init(testing.io);
    var app = try zapp.App(Tiny).init(testing.allocator, testing.io, .{&rec}, .{});
    defer app.deinit();
    try testing.expectEqualStrings("build order: Tiny.Nothing, Tiny.Ping, Tiny.Servers.httpServer, Tiny.Pong, Tiny.Servers.rpcServer", app.internal.build_order);
    // The servers keep the controller and the handler as *anyopaque and call through them.
    try testing.expectEqual(7, app.get(mocks.http.Server).item(Ping, 0).ping());
    try testing.expectEqual(8, app.get(mocks.rpc.Server).item(Pong, 0).pong());
    _ = app.get(Nothing);
}

test "two servers, each with the controllers of its own module" {
    var rec: mocks.Recorder = .init(testing.io);
    const config: mocks.Config = .{};
    const logger: mocks.Logger = .{ .id = 1 };
    var app = try zapp.App(two.AppModule).init(testing.allocator, testing.io, .{ &rec, &config, &logger }, .{});
    defer app.deinit();
    // The public server: what PublicModule reaches, the health controller last.
    try expectNames(&.{ "UsersController", "OrdersController", "HealthController" }, app.get(mocks.http.Server).names);
    // The admin's: its own controllers only, its own health among them.
    const admin = app.get(two.AdminHttp);
    try expectNames(&.{ "AdminController", "AdminHealthController" }, admin.server.names);
    try testing.expect(admin.server.item(two.AdminController, 0) == app.get(two.AdminController));
    try testing.expect(app.get(two.AdminController).db == app.get(shop.ShopDb));
    try expectNames(&.{"OrdersHandler"}, app.get(mocks.rpc.Server).names);
}

test "two rpc servers with separate Handlers" {
    var rec: mocks.Recorder = .init(testing.io);
    const config: mocks.Config = .{};
    const logger: mocks.Logger = .{ .id = 1 };
    var app = try zapp.App(two.RpcModule).init(testing.allocator, testing.io, .{ &rec, &config, &logger }, .{});
    defer app.deinit();
    try expectNames(&.{"OrdersHandler"}, app.get(mocks.rpc.Server).names);
    const internal = app.get(two.InternalRpc);
    try expectNames(&.{"StatsHandler"}, internal.server.names);
    try testing.expect(internal.server.item(two.StatsHandler, 0).analytics == app.get(shop.AnalyticsDb));
}
