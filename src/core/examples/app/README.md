# zefir.App: an application container for zefir services

**One place that builds a service and runs it.** A service is made of
parts: clients of databases and of NATS, repositories, services, an HTTP
server, an rpc server. Each part needs some of the others, they must start
in the right order and stop in the reverse one, and all of it within the
time that Kubernetes gives a pod after SIGTERM. zefir.App does this for
you. You split the service into *modules*, structs that declare what they
are made of; App builds every part once, gives each the parts it asks for
by their types, starts what has to start, watches the servers, and stops
everything within one deadline. The whole graph is checked when the
service compiles: a dependency that nothing provides, a part that a module
does not see, a cycle, each is a compile error that names the module, the
part and the fix.

> [!IMPORTANT]
> **Not implemented yet (TODO):**
>
> - **A context of the application.** App gives its beans no context of its
>   own, such as one that cancels background work at the stop. The servers
>   cancel their requests themselves when they stop, and a bean with work
>   of its own ends it in its `shutdown`.
> - **A restart.** An App runs once: after its stop, `start` returns
>   `error.InvalidState`. Another run is another App.
> - **A deadline of App's own for the start.** Each bean bounds its own
>   `start`: an HTTP server only binds its port, `mongo.Client` waits up to
>   its `start_timeout`, `nats.Client` up to its `connect_timeout`, an rpc
>   server on NATS up to 5 s for its subscriptions.
> - **Lazy beans.** `init` builds every bean of every module the root
>   reaches, whether or not anything takes it.

The root module of the shop that this guide builds, and the two lines of
its `main` that hand it to App:

```zig
pub const AppModule = struct {
    pub const module: zefir.app.Module = .{
        .imports = &.{ users.UsersModule, orders.OrdersModule },
        .providers = &.{ShopErrors},
        .factories = &.{ Bus, Servers },
        .controllers = &.{HealthController},
        // Ready objects from main: App hands them out, and never starts or
        // destroys them.
        .values = &.{ *const Config, *const log.Logger },
    };
```

```zig
var app = try zefir.App(AppModule).init(init.gpa, io, .{ &config, &logger }, .{});
defer app.deinit();
```

## Contents

- [Installation](#installation)
- [Why App](#why-app)
- [The shop](#the-shop)
- [A run](#a-run)
- [What App does with the shop](#what-app-does-with-the-shop)
- [Modules](#modules)
- [Dependencies](#dependencies)
- [Order](#order)
- [Two databases and two servers](#two-databases-and-two-servers)
- [Servers](#servers)
- [Testing a module](#testing-a-module)
- [Signals](#signals)
- [If a server does not stop](#if-a-server-does-not-stop)
- [When the build stops](#when-the-build-stops)
- [What your editor completes](#what-your-editor-completes)

## Installation

Add Zefir to your `build.zig.zon`; App ships since v0.10.0:

```sh
zig fetch --save git+https://github.com/vkiryakov/zefir#dev
```

This guide is on the `dev` branch, so the command fetches its latest commit; `--save` pins that commit. For the latest release, v0.11.0, fetch `#v0.11.0` instead.

The shop runs on zio. zio has no release for Zig 0.17 yet, so pin the
commit Zefir is tested with:

```sh
zig fetch --save git+https://github.com/lalinsky/zio#d15034f1a4d9ddaa42829aae8f7e02d37cd1093a
```

Then import the umbrella module `zefir` in `build.zig`: App lives in
zefir-core, and the shop uses http, rpc, confy and log as well, all of them
parts of the umbrella. The tests of the shop need no zio:

```zig
// build.zig of the shop
const zefir = b.dependency("zefir", .{ .target = target, .optimize = optimize });
const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });

const exe = b.addExecutable(.{
    .name = "shop",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zefir", .module = zefir.module("zefir") },
            .{ .name = "zio", .module = zio.module("zio") },
        },
    }),
});
b.installArtifact(exe);
b.step("run", "Run the shop").dependOn(&b.addRunArtifact(exe).step);

const tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/shop_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zefir", .module = zefir.module("zefir") }},
    }),
});
b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
```

> [!TIP]
> App is also `zefir.module("zefir-core")`: with it imported as `core`, it
> is `core.App` and `core.app`, the same types as `zefir.App` and
> `zefir.app`.

## Why App

Without App, `main` builds the service by hand. It makes the client of the
database and connects it, makes the repositories and the services on top
of it, the controllers, the server, starts the server, waits for a signal,
stops the server, closes the client, and frees everything in the reverse
order. Every new part adds lines in three places of `main`, and a line in
the wrong place shows only at run time: a server that starts before the
database it needs, or a client closed while the last requests still use
it.

With App, `main` stays short and the order comes from the declarations:

- **Each part says what it needs, and only that.** A service asks for its
  repository by a field or a param; App finds the repository, builds it
  first, and passes it in.
- **Modules group what belongs together** and decide what others may take:
  the users' module shares its service, and keeps its store to itself.
- **The order is never written down.** App builds a part after what it
  takes, starts in that order, and stops and frees in the reverse one.
- **Servers and clients are parts like any other.** `http.Server`,
  `rpc.Server`, `nats.Client` and `mongo.Client` have the methods App
  calls, so App starts them, watches them and stops them, with no code
  around them.
- **Mistakes stop the build.** A dependency nobody provides, a part a
  module does not see, two parts of one type, a cycle: each is a compile
  error with the fix in its message.

## The shop

The service of this guide is a small shop. Users sign up, and they place
orders; another service of the shop's company asks for a user over rpc;
Kubernetes asks `/readyz` whether the shop takes work. It has two servers,
HTTP for the users and rpc for the other services, and two stores, one for
the users and one for the orders. It keeps everything in memory, so that it
runs alone: no database and no NATS are needed. A shop of the same shape
against NATS and MongoDB is [in the repository on GitHub](https://github.com/vkiryakov/zefir/tree/dev/tests/app/shop).

The shop is three modules. `AppModule` is the root: the module that `main`
gives to App, which reaches the others through its imports.

```text
AppModule                 the root: the servers, the rpc transport, the
│                         errors of HTTP, the health checks; the config and
│                         the logger come from main
├── UsersModule           UsersDb, UserService, UsersController,
│                         UsersHandler; others may take UserService
└── OrdersModule          OrdersDb, OrderService, OrdersController
    └── UsersModule       its UserService checks the user of an order
```

The files, each as it is.

### Config.zig

The settings: only the port, which confy reads from `SHOP_PORT`.

```zig
//! The settings of the shop, read from the environment by confy: each
//! field from the variable of its name with the prefix SHOP_.

/// The port of the HTTP server, SHOP_PORT.
port: u16 = 8080,
```

### Store.zig

A store of records in memory. It has the lifecycle of a client of a
database: App calls its `start` before the servers take requests, and its
`shutdown` after the servers have stopped, so no request writes into a
closed store.

```zig
//! A store of records in memory, with the lifecycle of a client of a
//! database: `start` opens it, where a client would connect; `shutdown`
//! closes it, where a client would close its connections by the deadline;
//! `deinit` frees its memory. Each record is a number and a text under an
//! id the store gives, 1, 2, and so on: a stand-in for the documents of a
//! real database.

const std = @import("std");

const Store = @This();

gpa: std.mem.Allocator,
/// Guards the fields below: the servers run their requests on many tasks.
mutex: std.Io.Mutex = .init,
records: std.ArrayList(Record) = .empty,
open: bool = false,

/// What the number means is up to the module that keeps the records: the
/// orders keep the id of their user in it.
pub const Record = struct {
    number: u64 = 0,
    text: []const u8,
};

pub fn init(gpa: std.mem.Allocator) Store {
    return .{ .gpa = gpa };
}

/// Opens the store.
pub fn start(store: *Store, io: std.Io) !void {
    try store.mutex.lock(io);
    defer store.mutex.unlock(io);
    store.open = true;
}

/// Closes the store: from now on it refuses every call with
/// `error.Unavailable`.
pub fn shutdown(store: *Store, io: std.Io, deadline: std.Io.Clock.Timestamp) !void {
    _ = deadline; // Closing a store in memory takes no time.
    try store.mutex.lock(io);
    defer store.mutex.unlock(io);
    store.open = false;
}

pub fn deinit(store: *Store) void {
    for (store.records.items) |record| store.gpa.free(record.text);
    store.records.deinit(store.gpa);
}

/// Keeps a copy of `record` and returns its id.
pub fn insert(store: *Store, io: std.Io, record: Record) !u64 {
    const text = try store.gpa.dupe(u8, record.text);
    errdefer store.gpa.free(text);
    try store.mutex.lock(io);
    defer store.mutex.unlock(io);
    if (!store.open) return error.Unavailable;
    try store.records.append(store.gpa, .{ .number = record.number, .text = text });
    return store.records.items.len;
}

/// The record `id`, its text copied into `arena`; null when there is none.
pub fn find(store: *Store, io: std.Io, arena: std.mem.Allocator, id: u64) !?Record {
    try store.mutex.lock(io);
    defer store.mutex.unlock(io);
    if (!store.open) return error.Unavailable;
    if (id == 0 or id > store.records.items.len) return null;
    const record = store.records.items[id - 1];
    return .{ .number = record.number, .text = try arena.dupe(u8, record.text) };
}
```

### users_api.zig

The contract of the users over rpc: the method `getUser`, its types, and
its error. A service that calls the shop imports the same file.

```zig
//! The contract of the users over rpc, as the guide of zefir-rpc writes
//! one: what the shop serves, and what the services that call it import.

const zefir = @import("zefir");
const rpc = zefir.rpc;

pub const User = struct {
    id: u64,
    name: []const u8,
};

pub const GetUserRequest = struct { id: u64 };

pub const UsersApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
    .errors = .{
        .UserNotFound = .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" },
    },
});
```

### users.zig

The users' module. Its four parts are four kinds of beans, the parts App
builds:

- `UsersDb`, a **provider** with `init`: App calls `init`, whose params are
  its dependencies (here the allocator App holds), and later `start`,
  `shutdown` and `deinit`.
- `UserService`, a provider with `init` too: it takes the store and the
  logger.
- `UsersController`, a **controller** of HTTP, marked by `http_routes`; it
  has no `init`, so App fills its fields.
- `UsersHandler`, a **handler** of rpc, marked by `rpc_handler`.

```zig
//! The users of the shop: their store, their service, the HTTP controller
//! that signs them up and shows them, and the rpc handler that other
//! services call.

const std = @import("std");
const zefir = @import("zefir");
const http = zefir.http;
const rpc = zefir.rpc;
const log = zefir.log;
const Store = @import("Store.zig");
const api = @import("users_api.zig");

pub const UsersModule = struct {
    pub const module: zefir.app.Module = .{
        .providers = &.{ UsersDb, UserService },
        .controllers = &.{UsersController},
        .handlers = &.{UsersHandler},
        // What other modules may take. UsersDb stays private: they see
        // the service only.
        .exports = &.{UserService},
    };
};

pub const User = api.User;

/// The store of the users. The orders have a Store too, and App gives
/// every dependency by its type, so each store has a type of its own: a
/// wrapper that passes the lifecycle of its Store on.
pub const UsersDb = struct {
    store: Store,

    pub fn init(gpa: std.mem.Allocator) UsersDb {
        return .{ .store = .init(gpa) };
    }
    pub fn start(db: *UsersDb, io: std.Io) !void {
        return db.store.start(io);
    }
    pub fn shutdown(db: *UsersDb, io: std.Io, deadline: std.Io.Clock.Timestamp) !void {
        return db.store.shutdown(io, deadline);
    }
    pub fn deinit(db: *UsersDb) void {
        db.store.deinit();
    }
};

/// With init: its params are its dependencies.
pub const UserService = struct {
    db: *UsersDb,
    logger: log.Logger,

    pub fn init(db: *UsersDb, logger: *const log.Logger) UserService {
        return .{ .db = db, .logger = logger.scoped("users") };
    }

    pub fn signUp(service: *UserService, io: std.Io, name: []const u8) !User {
        const id = try service.db.store.insert(io, .{ .text = name });
        service.logger.info("User signed up", .{ .id = id, .name = name });
        return .{ .id = id, .name = name };
    }

    /// The user `id`; its name lives in `arena`.
    pub fn find(service: *UserService, io: std.Io, arena: std.mem.Allocator, id: u64) !User {
        const record = try service.db.store.find(io, arena, id) orelse return error.UserNotFound;
        return .{ .id = id, .name = record.text };
    }
};

/// An HTTP controller: `http_routes` marks it. Without init: App fills its
/// fields, each a dependency.
pub const UsersController = struct {
    service: *UserService,

    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{
            .signUp = http.post("", .{}),
            .get = http.get("/{id}", .{}),
        },
    });

    pub const SignUpRequest = struct { name: []const u8 };

    pub fn signUp(self: *UsersController, ctx: *http.Context) !http.Json(User) {
        const body = try ctx.json(SignUpRequest);
        return .{ .value = try self.service.signUp(ctx.io(), body.name), .status = 201 };
    }

    pub fn get(self: *UsersController, ctx: *http.Context) !http.Json(User) {
        const path = try ctx.path(struct { id: u64 });
        return .{ .value = try self.service.find(ctx.io(), ctx.allocator(), path.id) };
    }
};

/// An rpc handler: `rpc_handler` marks it.
pub const UsersHandler = struct {
    service: *UserService,

    pub const rpc_handler = rpc.implement(api.UsersApi, .{});

    pub fn getUser(self: *UsersHandler, ctx: *rpc.Context, req: api.GetUserRequest) !User {
        return self.service.find(ctx.io(), ctx.allocator(), req.id);
    }
};
```

### orders.zig

The orders' module imports `UsersModule` to take its `UserService`: an
order is placed only for a user who exists. `OrderService.init` takes a
struct whose fields are its dependencies; App fills it by the fields'
types, and the names make the call easy to read.

```zig
//! The orders of the shop: their store, their service, which asks the
//! users' service whether the user exists, and the HTTP controller that
//! takes and shows them.

const std = @import("std");
const zefir = @import("zefir");
const http = zefir.http;
const log = zefir.log;
const Store = @import("Store.zig");
const users = @import("users.zig");

pub const OrdersModule = struct {
    pub const module: zefir.app.Module = .{
        // UserService, which UsersModule exports.
        .imports = &.{users.UsersModule},
        // The service comes first and takes the store: App builds the store
        // first, since a bean comes after what it takes.
        .providers = &.{ OrderService, OrdersDb },
        .controllers = &.{OrdersController},
    };
};

pub const Order = struct {
    id: u64,
    user_id: u64,
    item: []const u8,
};

/// The store of the orders: a type of its own, as UsersDb is.
pub const OrdersDb = struct {
    store: Store,

    pub fn init(gpa: std.mem.Allocator) OrdersDb {
        return .{ .store = .init(gpa) };
    }
    pub fn start(db: *OrdersDb, io: std.Io) !void {
        return db.store.start(io);
    }
    pub fn shutdown(db: *OrdersDb, io: std.Io, deadline: std.Io.Clock.Timestamp) !void {
        return db.store.shutdown(io, deadline);
    }
    pub fn deinit(db: *OrdersDb) void {
        db.store.deinit();
    }
};

/// A struct param: its fields are the dependencies, so init asks for them
/// by name.
pub const OrderService = struct {
    db: *OrdersDb,
    users: *users.UserService,
    logger: log.Logger,

    pub fn init(deps: struct {
        db: *OrdersDb,
        users: *users.UserService,
        logger: *const log.Logger,
    }) OrderService {
        return .{ .db = deps.db, .users = deps.users, .logger = deps.logger.scoped("orders") };
    }

    /// An order of the user `user_id`, who must exist: else
    /// `error.UserNotFound`.
    pub fn place(service: *OrderService, io: std.Io, arena: std.mem.Allocator, user_id: u64, item: []const u8) !Order {
        const user = try service.users.find(io, arena, user_id);
        const id = try service.db.store.insert(io, .{ .number = user_id, .text = item });
        service.logger.info("Order placed", .{ .id = id, .user = user.name, .item = item });
        return .{ .id = id, .user_id = user_id, .item = item };
    }

    /// The order `id`; its item lives in `arena`.
    pub fn find(service: *OrderService, io: std.Io, arena: std.mem.Allocator, id: u64) !Order {
        const record = try service.db.store.find(io, arena, id) orelse return error.OrderNotFound;
        return .{ .id = id, .user_id = record.number, .item = record.text };
    }
};

pub const OrdersController = struct {
    service: *OrderService,

    pub const http_routes = http.routes(.{
        .prefix = "/v1/orders",
        .methods = .{
            .place = http.post("", .{}),
            .get = http.get("/{id}", .{}),
        },
    });

    pub const PlaceRequest = struct { user_id: u64, item: []const u8 };

    pub fn place(self: *OrdersController, ctx: *http.Context) !http.Json(Order) {
        const body = try ctx.json(PlaceRequest);
        return .{ .value = try self.service.place(ctx.io(), ctx.allocator(), body.user_id, body.item), .status = 201 };
    }

    pub fn get(self: *OrdersController, ctx: *http.Context) !http.Json(Order) {
        const path = try ctx.path(struct { id: u64 });
        return .{ .value = try self.service.find(ctx.io(), ctx.allocator(), path.id) };
    }
};
```

### health.zig

The health checks. `*const zefir.app.Status` is the state of App, which
any bean may take: `/readyz` answers 503 until App has started everything,
and again from the first step of the stop, so that Kubernetes sends no new
requests to a shop that stops.

```zig
//! The health checks of the shop, for the load balancer and Kubernetes:
//! /livez says the process runs, /readyz whether it takes work.

const zefir = @import("zefir");
const http = zefir.http;

pub const HealthController = struct {
    /// A built-in dependency: the state of App, read-only.
    status: *const zefir.app.Status,

    pub const http_routes = http.routes(.{ .methods = .{
        .live = http.get("/livez", .{}),
        .ready = http.get("/readyz", .{}),
    } });

    pub const Health = struct { status: []const u8 };

    pub fn live(_: *HealthController, _: *http.Context) !http.Json(Health) {
        return .{ .value = .{ .status = "ok" } };
    }

    /// 503 until App has started everything, and from the first step of its
    /// stop on.
    pub fn ready(self: *HealthController, _: *http.Context) !http.Json(Health) {
        if (!self.status.isReady()) return .{ .value = .{ .status = "not ready" }, .status = 503 };
        return .{ .value = .{ .status = "ok" } };
    }
};
```

### app_module.zig

The root. `Bus` and `Servers` are **factories**: structs whose every `pub
fn` is a bean, with the function's params as its dependencies and its
return type as the bean's type. Factories build what needs options, such
as servers. `zefir.app.Controllers(AppModule)` is the tuple of the
controllers of `AppModule` and of the modules it imports, which the HTTP
server serves; `zefir.app.Handlers(AppModule)` is the same for the rpc
server. `ShopErrors` turns the errors `UserNotFound` and `OrderNotFound`
into 404: a provider without fields, which the factory of the HTTP server
takes like any other bean.

```zig
//! The root module of the shop: the two servers and what they take, and
//! the ready objects that `main` hands to App.

const std = @import("std");
const zefir = @import("zefir");
const http = zefir.http;
const rpc = zefir.rpc;
const log = zefir.log;
const Config = @import("Config.zig");
const users = @import("users.zig");
const orders = @import("orders.zig");
const HealthController = @import("health.zig").HealthController;

pub const AppModule = struct {
    pub const module: zefir.app.Module = .{
        .imports = &.{ users.UsersModule, orders.OrdersModule },
        .providers = &.{ShopErrors},
        .factories = &.{ Bus, Servers },
        .controllers = &.{HealthController},
        // Ready objects from main: App hands them out, and never starts or
        // destroys them.
        .values = &.{ *const Config, *const log.Logger },
    };

    /// Each pub fn of a factories struct is a bean: its params are its
    /// dependencies, its return type is the bean's type.
    pub const Bus = struct {
        /// The transport of rpc, in memory, so that the shop runs alone.
        /// Its start and stop belong to the rpc server: App only builds it
        /// and frees it.
        pub fn memory(gpa: std.mem.Allocator) !rpc.testing.MemoryTransport {
            return .init(gpa, .{});
        }
    };

    pub const Servers = struct {
        /// Controllers(AppModule) is a tuple of pointers to the controllers
        /// of AppModule and of every module it imports.
        pub fn httpServer(
            gpa: std.mem.Allocator,
            config: *const Config,
            errors: *ShopErrors,
            controllers: zefir.app.Controllers(AppModule),
        ) !http.Server {
            return .init(gpa, .{ .controllers = controllers, .error_handler = errors }, .{
                .listen = .{ .port = config.port }, // the server makes its own http.native.Backend
                .prefix = "/api",
                .request_timeout = .fromSeconds(10),
            });
        }

        /// Handlers(AppModule), the handlers of AppModule and of every module
        /// it imports: here UsersHandler.
        pub fn rpcServer(gpa: std.mem.Allocator, bus: *rpc.testing.MemoryTransport, handlers: zefir.app.Handlers(AppModule)) !rpc.Server {
            return .init(gpa, .{ .handlers = handlers }, .{ .transport = bus.serverTransport() });
        }
    };
};

/// What the errors of the shop answer over HTTP: 404 for a user or an order
/// that is not there, the statuses of zefir-http for its own errors. A
/// provider without fields, which the factory of the server takes.
pub const ShopErrors = struct {
    pub fn mapError(err: anyerror) http.ErrorResponse(http.Problem) {
        return switch (err) {
            error.UserNotFound => notFound("users.not_found", "User not found"),
            error.OrderNotFound => notFound("orders.not_found", "Order not found"),
            else => .fallback(err, .{ .title = http.defaultTitle(err), .status = http.defaultStatus(err), .code = http.defaultCode(err) }),
        };
    }

    fn notFound(code: []const u8, title: []const u8) http.ErrorResponse(http.Problem) {
        return .{ .status = 404, .body = .{ .title = title, .status = 404, .code = code } };
    }
};
```

### main.zig

`main` reads the settings and makes the logger and the runtime: the
objects that live longer than App. Then it builds App, hands it the config
and the logger as **values** (ready objects that App gives out but never
starts or frees), connects the signals and runs App until it stops.

```zig
//! The shop: settings from the environment through confy, a logger, a zio
//! runtime, and App, which builds the rest out of the modules. Ctrl+C or
//! SIGTERM stops it gracefully.
//!
//! It keeps everything in memory and runs alone: it needs no database and
//! no NATS.
//!
//! Settings, from the environment:
//!
//!   SHOP_PORT   the port of the HTTP server; 8080 by default

const std = @import("std");
const zio = @import("zio");
const zefir = @import("zefir");
const Config = @import("Config.zig");
const AppModule = @import("app_module.zig").AppModule;

/// zefir and App write to std.log; this sends their records to the logger.
pub const std_options: std.Options = .{ .logFn = zefir.log.stdLogFn };

pub fn main(init: std.process.Init) !void {
    var config: Config = undefined;
    zefir.confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "SHOP_",
        .sources = &.{.osEnv()},
    });

    // The logger outlives the runtime, so it is made before it, on
    // `init.io`, through which the tasks of the runtime may log too.
    const logger: zefir.log.Logger = try .init(init.gpa, init.io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();

    // One runtime for the shop, an executor per CPU core.
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    // The ready objects, a tuple of pointers: App matches them against
    // AppModule.module.values by type, in any order. It builds the rest.
    var app = try zefir.App(AppModule).init(init.gpa, io, .{ &config, &logger }, .{});
    defer app.deinit();

    // SIGTERM and Ctrl+C begin a graceful stop. Signals are zio's: std.Io
    // has none.
    var on_terminate = try io.concurrent(stopOnSignal, .{ &app, .terminate });
    defer on_terminate.cancel(io) catch {};
    var on_interrupt = try io.concurrent(stopOnSignal, .{ &app, .interrupt });
    defer on_interrupt.cancel(io) catch {};

    // Starts every bean, waits until the stop is over, and returns.
    try app.run();
}

/// Waits for the signal `kind`, then asks App to stop. The type of App is
/// named as it is: zefir.App(AppModule).
fn stopOnSignal(app: *zefir.App(AppModule), kind: zio.SignalKind) !void {
    var signal = try zio.Signal.init(kind);
    // After it, a second Ctrl+C ends the process at once.
    defer signal.deinit();
    try signal.wait();
    // From any task; it never waits, and a second call does nothing.
    app.requestStop();
}
```

## A run

```text
$ zig build run
2026-10-22T02:25:05.505Z INFO  [zefir_app] UsersModule.UsersDb started
2026-10-22T02:25:05.505Z INFO  [zefir_app] OrdersModule.OrdersDb started
2026-10-22T02:25:05.506Z INFO  [zefir_app] AppModule.Servers.httpServer started
2026-10-22T02:25:05.506Z INFO  [zefir_app] AppModule.Servers.rpcServer started
```

App writes each start to the log: first the stores, then the HTTP server,
which binds its port, and the rpc server last. Once the last one has
started, the shop is ready:

```text
$ curl -i localhost:8080/api/readyz
HTTP/1.1 200 OK
content-type: application/json
Date: Thu, 22 Oct 2026 02:25:05 GMT
Content-Length: 15

{"status":"ok"}
```

Ann signs up, and the store gives her the id 1:

```text
$ curl -i localhost:8080/api/v1/users --json '{"name":"Ann"}'
HTTP/1.1 201 Created
content-type: application/json
Date: Thu, 22 Oct 2026 02:25:05 GMT
Content-Length: 21

{"id":1,"name":"Ann"}
```

```text
$ curl -i localhost:8080/api/v1/users/1
HTTP/1.1 200 OK
content-type: application/json
Date: Thu, 22 Oct 2026 02:25:05 GMT
Content-Length: 21

{"id":1,"name":"Ann"}
```

She orders tea. `OrderService` asks `UserService`, the export of the
other module, whether user 1 exists, then keeps the order:

```text
$ curl -i localhost:8080/api/v1/orders --json '{"user_id":1,"item":"Green tea"}'
HTTP/1.1 201 Created
content-type: application/json
Date: Thu, 22 Oct 2026 02:25:05 GMT
Content-Length: 39

{"id":1,"user_id":1,"item":"Green tea"}
```

An order of user 2, who has not signed up, gets the 404 of `ShopErrors`:

```text
$ curl -i localhost:8080/api/v1/orders --json '{"user_id":2,"item":"Coffee"}'
HTTP/1.1 404 Not Found
content-type: application/problem+json
Date: Thu, 22 Oct 2026 02:25:05 GMT
Content-Length: 97

{"type":"about:blank","title":"User not found","status":404,"code":"users.not_found","errors":[]}
```

```text
$ curl -i localhost:8080/api/v1/orders/1
HTTP/1.1 200 OK
content-type: application/json
Date: Thu, 22 Oct 2026 02:25:05 GMT
Content-Length: 39

{"id":1,"user_id":1,"item":"Green tea"}
```

Ctrl+C in the terminal of the shop. App stops the two servers together,
then the stores, the last built first, and `run` returns:

```text
$ zig build run
2026-10-22T02:25:05.505Z INFO  [zefir_app] UsersModule.UsersDb started
2026-10-22T02:25:05.505Z INFO  [zefir_app] OrdersModule.OrdersDb started
2026-10-22T02:25:05.506Z INFO  [zefir_app] AppModule.Servers.httpServer started
2026-10-22T02:25:05.506Z INFO  [zefir_app] AppModule.Servers.rpcServer started
2026-10-22T02:25:05.510Z INFO  [users] User signed up id=1 name=Ann
2026-10-22T02:25:05.511Z INFO  [orders] Order placed id=1 user=Ann item="Green tea"
^C
2026-10-22T02:25:05.513Z INFO  [zefir_app] stopping
2026-10-22T02:25:05.513Z INFO  [zefir_app] AppModule.Servers.rpcServer stopped
2026-10-22T02:25:05.513Z INFO  [zefir_app] AppModule.Servers.httpServer stopped
2026-10-22T02:25:05.513Z INFO  [zefir_app] OrdersModule.OrdersDb stopped
2026-10-22T02:25:05.513Z INFO  [zefir_app] UsersModule.UsersDb stopped
2026-10-22T02:25:05.513Z INFO  [zefir_app] stopped
```

## What App does with the shop

**Building** (`init`). Modules in the order of their imports, each once,
the root last; inside a module, each bean after the beans it takes. App
writes this order to `std.log` at debug, as one record, here wrapped:

```text
build order: UsersModule.UsersDb, UsersModule.UserService, UsersModule.UsersController,
UsersModule.UsersHandler, OrdersModule.OrdersDb, OrdersModule.OrderService,
OrdersModule.OrdersController, AppModule.ShopErrors, AppModule.Bus.memory,
AppModule.HealthController, AppModule.Servers.httpServer, AppModule.Servers.rpcServer
```

`OrdersModule` lists `OrderService` before `OrdersDb`, and App builds the
store first, since the service takes it. `HealthController` comes before
the HTTP server, which serves it. `UsersModule` is imported by both other
modules, and built once.

**Starting** (`start`, the first half of `run`). The beans that have
`start`, in the order they were built: `UsersDb`, `OrdersDb`, `httpServer`,
`rpcServer`. Each `start` returns once its bean is ready. App then watches
the two servers through their `wait`.

**Stopping** (`requestStop`, which a signal or your code calls):

```text
requestStop (a signal, a server that broke, or your code)
   │
   ├─ phase 1: requestStop to every bean that has it, at once:
   │           httpServer and rpcServer take nothing new
   │
   └─ phase 2: shutdown, one deadline for all
        the servers together, each in a task of its own:
          httpServer (lets its requests end), rpcServer (lets its calls end)
        then the others, the last built first: OrdersDb → UsersDb
   │
   └─ freeing (deinit), the last built first, in app.deinit():
        rpcServer, httpServer, Bus.memory, OrdersDb, UsersDb
```

The servers are the beans with `requestStop`. Each gets the deadline as
the stop begins, so a server slow to stop takes no time from the other;
App writes their lines once both have stopped, the last built first. The
stores, which the servers use, close after them.

The memory transport, `Bus.memory`, is neither started nor stopped by App:
the rpc server starts and closes it. App frees it after the server, since it
was built before.

## Modules

A module is any struct that declares `pub const module: zefir.app.Module`.
The root is the module you pass to `zefir.App(Root)`; App reaches the
others through `.imports`, and builds each module once, however many
modules import it. Write the type after the name: then `.{ ... }` is a
`zefir.app.Module`, your editor completes its fields, and a typo such as
`.provders` is a compile error on your line.

| Field | What it holds | Who declares it |
|---|---|---|
| `imports` | modules whose exports the beans of this module take | any module |
| `providers` | types App builds: by their `init`, whose params are dependencies, or by filling their fields, each a dependency | any module |
| `factories` | structs whose every `pub fn` is a bean | any module |
| `controllers` | controllers of HTTP: types with `pub const http_routes` | any module |
| `handlers` | handlers of rpc: types with `pub const rpc_handler` | any module |
| `exports` | what the modules that import this one may take | any module |
| `values` | the types of the ready objects `init` takes, as pointers | the root only |
| `overrides` | modules and beans App does not build, for tests | the root only |

Every field is a list of types, empty by default.

## Dependencies

A bean's dependencies are the params of its `init` or of its factory
function, the fields of a provider, controller or handler without `init`,
and the fields of a struct param of `init` or of a factory. App gives each
by its type:

| A bean asks for | It gets |
|---|---|
| `std.mem.Allocator` | the allocator App was given |
| `std.Io` | the `io` App was given |
| `*const zefir.app.Status` | the state of App, read-only |
| `zefir.app.Controllers(M)`, `zefir.app.Handlers(M)` | a tuple of pointers to the controllers (handlers) of module M and of every module M reaches |
| `*T` or `*const T` | the bean of type T, or the value of type T from `.values`; a value as `*T` only when the root declares `*T` |
| `T` | a copy of the bean or the value of type T |
| a struct that is not a bean | a struct of dependencies, filled by these same rules |

- **A field with a default value is not a dependency**: App leaves it as it
  is.
- **A module sees** its own beans, the exports of the modules it imports,
  and the values of the root. The exports of an import's imports are not
  seen, unless the import exports them again. A controller sees the
  private beans of its module.
- **A copy of a bean that App starts or frees is a compile error**: it
  would be a second server or a second client. Take a pointer. A copy of a
  plain value, such as `mongo.Database` or `log.Logger`, is fine.
- **Controllers and handlers are never taken by beans.** A server factory
  takes them, all at once, as `Controllers(M)` or `Handlers(M)`.

**Two rules of Zig for names.** A function of a factories struct may not
have the name of something its file already declares: `pub fn http` next
to `const http = zefir.http;` is Zig's error "ambiguous reference". And a
param may not have the name of a function of the same struct: a param
`client` next to a `pub fn client` is "function parameter shadows
declaration". That is why the shop's factory functions are `httpServer`
and `rpcServer`, and a client of MongoDB's is `mongoClient`.

## Order

1. **Modules:** the imports first, depth first, in the order of
   `.imports`, each module once; the root last.
2. **Inside a module:** the providers, then the factories (the structs in
   the order of the list, their functions in the order they are
   declared), then the controllers, then the handlers. A bean that takes a
   bean of its own module that is not built yet pulls it up: so a provider
   may take the result of a factory of its module, and a server factory
   pulls up the controllers of its module.
3. **A cycle** cannot be built: it is a compile error with the whole path,
   such as `Root.X (.y) -> Root.Y (.z) -> Root.Z (.x) -> Root.X`.
4. **Start** in the order of building; **stop** the servers together,
   then the rest in the reverse order; **free** in the reverse order.

## Two databases and two servers

App gives every dependency by its type, so a type is one bean in the whole
application: two factory functions that return the same type are a compile
error:

```text
error: zefir.App(Root): two beans of type Database: Root.Dbs.usersDb and Root.Dbs.analyticsDb; App injects by type, so a type is one bean: give each its own type, such as `pub const UsersDb = struct { database: Database };`, and take *UsersDb
```

The fix is a type of its own for each. The shop does this with its two
stores: `UsersDb` and `OrdersDb` each hold a `Store`, and pass on the
methods of its lifecycle, `start`, `shutdown` and `deinit`, one line each.
Two databases on one client of MongoDB are wrappers without methods,
`pub const ShopDb = struct { db: mongo.Database };`, since a database has
no lifecycle of its own: its client has.

A second HTTP server, say for an admin port, is a wrapper too: `pub const
AdminHttp = struct { server: http.Server }` with the six methods of the
contract (see [Servers](#servers)), each calling the server's, and a
factory that returns it.

Which controllers each server gets follows one rule: **one controller, one
server**. `Controllers(M)` holds the controllers of M and of every module
M reaches, so a public server that takes `Controllers(AppModule)`, where
`AppModule` imports the admin's module, would serve the admin's routes on
the public port too. That is a compile error:

```text
error: zefir.App(AppModule): AdminModule.AdminController is served by both AppModule.Servers.httpServer (param 2) and AppModule.Servers.adminHttp (param 2); one controller is served by one server: take Controllers of a module that does not reach AdminModule
```

Give the public server a module of its own that does not reach the admin's,
and each server a health controller of its own type:

```text
AppModule           Servers.httpServer takes Controllers(PublicModule),
│                   Servers.adminHttp takes Controllers(AdminModule)
├── PublicModule    HealthController
│   ├── UsersModule     UsersController
│   └── OrdersModule    OrdersController
└── AdminModule     AdminController, AdminHealthController
```

The same goes for handlers and two rpc servers. The shop has one server of
each kind, which the rule does not touch.

## Servers

App drives a bean by the methods it declares. All are optional but the way
to build it:

| Method | What it means to App | Who has it |
|---|---|---|
| `init(...)`, the fields, or a factory | build, without I/O and without tasks | every bean |
| `start(self: *T, io: std.Io) !void` | connect, bind a port; return once ready, or with an error and nothing left running | servers, `mongo.Client`, `nats.Client`, the stores of the shop |
| `wait(self: *T, io: std.Io) !void` | wait while it works; a return without a stop request is a breakdown | servers, `nats.Client` |
| `requestStop(self: *T, io: std.Io) void` | take no new work; never wait | servers |
| `shutdown(self: *T, io: std.Io, deadline: std.Io.Clock.Timestamp) !void` | end what is at work and close, by the deadline; else `error.ShutdownTimeout` | what holds connections or tasks |
| `isReady(self: *const T) bool` | whether it takes work now | servers |
| `deinit(self: *T) void` or `deinit(self: *T, io: std.Io) void` | free the memory | what has memory to free |

- **The methods must be `pub`.** App sees only the public declarations of
  a type: a private `fn start` is never called.
- **A method of one of these names with another signature** is a compile
  error that shows the signature App expects (see [When the build
  stops](#when-the-build-stops)).
- **A type whose methods of these names mean something else** declares
  `pub const app_lifecycle = false;`. App then only builds it and calls its
  `deinit`. The transports of rpc do this: `rpc.testing.MemoryTransport`
  of the shop, and `rpc_nats.Transport`, whose server starts and closes
  them.
- **The servers and clients of Zefir are beans as they are:**
  `http.Server`, `rpc.Server`, `nats.Client` and `mongo.Client`. A factory
  returns them; App does the rest. The guides of
  [http](../../../http/examples/README.md#under-zefirapp),
  [rpc](../../../rpc/examples/README.md#under-zefirapp),
  [rpc-nats](../../../rpc-nats/examples/README.md#under-zefirapp),
  [nats](../../../nats/examples/README.md#under-zefirapp) and
  [mongo](../../../mongo/examples/README.md#under-zefirapp) show each under
  App.
- **A server that stops by itself stops the App.** When the `wait` of a
  bean returns while App runs, with an error or without one, App stops all
  the others; `run` and `wait` then return that bean's error (or
  `error.UnexpectedStop`), and `app.failure()` names the bean and the step.
  When the client of NATS gives up, the rpc server on it ends too, and
  either may be the one named.
- **The stop has one budget,** `shutdown_timeout` in the options of
  `init`, 25 s by default, which fits the 30 s Kubernetes gives a pod. The
  servers, the beans with `requestStop`, get their `shutdown` together,
  each in a task of its own, so each has the whole budget; then the other
  beans get theirs one at a time, the last built first. The servers of
  Zefir return from `shutdown` 250 ms before the deadline, so that the
  beans after them have time.

The methods of App:

| Method | What it does |
|---|---|
| `init(gpa, io, values, options)` | builds every bean, without I/O; when one fails, frees those built before it and returns its error |
| `run()` | `start`, then `wait`; for `main` |
| `start()` | starts the beans in order and returns once all are ready; when one fails, stops those already started and returns its error |
| `wait()` | waits for the end of the stop: `{}` after `requestStop`, the error of a bean that stopped by itself, or `error.ShutdownTimeout` |
| `requestStop()` | begins the stop; from any task, never waits, and a second call does nothing |
| `shutdown()` | `requestStop`, then `wait` |
| `deinit()` | frees the beans, the last built first; a running App is stopped first |
| `state()` | `created`, `starting`, `running`, `stopping`, `stopped` or `failed` |
| `isReady()` | running, and every bean with `isReady` is ready |
| `failure()` | the first cause of the stop: the bean, the step and the error; null when all went well |
| `get(T)` | the bean of type T, for tests and `main` |

## Testing a module

A test builds a part of the application with a root of its own. Its
`.overrides` lists modules and beans that App does not build, and its
`.values` gives an object of the test in the place of each: here, a store
of users that the test fills itself, under the real `OrdersModule` and
`UsersModule`.

```zig
//! The tests of the shop: OrdersModule with a store of users that the test
//! fills itself, and the graph of the whole shop.

const std = @import("std");
const zefir = @import("zefir");
const users = @import("users.zig");
const orders = @import("orders.zig");

const testing = std.testing;

/// A root of the test: the real OrdersModule, and through it the real
/// UsersModule, but App does not build the users' store. The test passes a
/// store of its own, a value of `.values`, which takes its place.
const OrdersTest = struct {
    pub const module: zefir.app.Module = .{
        .imports = &.{orders.OrdersModule},
        .overrides = &.{users.UsersDb},
        .values = &.{ *users.UsersDb, *const zefir.log.Logger },
    };
};

test "an order of a user who exists, and of one who does not" {
    const io = testing.io;
    var users_db: users.UsersDb = .init(testing.allocator);
    defer users_db.deinit();
    try users_db.start(io);
    const ann = try users_db.store.insert(io, .{ .text = "Ann" });

    // The records of the services go to a buffer, not to stdout.
    var buffer: [1024]u8 = undefined;
    var records: std.Io.Writer = .fixed(&buffer);
    const logger: zefir.log.Logger = try .init(testing.allocator, io, .{ .format = .text, .output = .{ .writer = &records } });
    defer logger.deinit();

    var app = try zefir.App(OrdersTest).init(testing.allocator, io, .{ &users_db, &logger }, .{});
    defer app.deinit();
    // Opens the store of the orders; the store of the users is the test's.
    try app.start();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // app.get is for tests: name the type, and the editor completes its
    // fields and methods.
    const service: *orders.OrderService = app.get(orders.OrderService);
    const order = try service.place(io, arena, ann, "Green tea");
    try testing.expectEqual(ann, order.user_id);
    try testing.expectEqualStrings("Green tea", (try service.find(io, arena, order.id)).item);
    try testing.expectError(error.UserNotFound, service.place(io, arena, ann + 1, "Coffee"));
}

test "the graph of the shop" {
    // Zig checks only the code that a build reaches: naming the type of the
    // shop's App checks its whole graph, and starts nothing.
    _ = zefir.App(@import("app_module.zig").AppModule);
}
```

- **`app.get(T)`** gives the bean of type T. Write the type in the
  declaration, `const service: *orders.OrderService =
  app.get(orders.OrderService);`, and your editor completes the fields and
  methods of `service`.
- **`test "the graph of the shop"`** starts nothing. Zig compiles only the
  code a build reaches, and naming the type `zefir.App(AppModule)` makes App
  check the whole graph of the shop when `zig build test` compiles the
  test.

## Signals

App does not catch signals: `std.Io` has none, and App runs on any
`std.Io`. On zio, `zio.Signal` waits for one, and `main` connects them
itself, as the shop's [`main.zig`](#mainzig) does: a task waits for
SIGTERM, another for Ctrl+C, and each asks App to stop.

- After its signal, the task's `defer signal.deinit()` gives the signal its
  default action back: a second Ctrl+C ends the process at once.
- `app.requestStop()` is safe from any task and any thread, but not from
  inside a handler of a signal; a task that waits on `zio.Signal` is an
  ordinary task.

## If a server does not stop

A task in Zig cannot be killed: a server cancels its requests, and a
request ends when its code next looks at the cancelation. A handler that
never does holds its server past the deadline. Then the tasks of the
beans may still use their memory, so freeing it would be a bug, and the
honest way out is to end the process. `run` does this: it writes which bean
did not stop, to the log and straight to stderr, and exits with code 1.

This program runs the HTTP server in memory, with a handler deaf to its
cancelation, and plays a client and Ctrl+C:

```zig
//! A server that cannot stop: its handler is deaf to its cancelation and
//! holds a request forever. A task plays the client and, once the request
//! is in the handler, Ctrl+C. When the stop runs out of time, `run` writes
//! which bean did not stop and ends the process with code 1. The server
//! runs on the backend of zefir-http in memory, so the program needs no
//! network.

const std = @import("std");
const zefir = @import("zefir");
const http = zefir.http;

/// App writes each step to std.log, at info; this program has no logger of
/// its own, so std.log writes to stderr.
pub const std_options: std.Options = .{ .log_level = .info };

/// What the program sees of the request: a root value.
const Probe = struct { entered: std.Io.Event = .unset };

/// `GET /report`, which never ends.
const ReportController = struct {
    probe: *Probe,

    pub const http_routes = http.routes(.{ .methods = .{ .report = http.get("/report", .{}) } });

    pub fn report(self: *ReportController, ctx: *http.Context) !void {
        self.probe.entered.set(ctx.io());
        // Deaf to its cancelation: nothing ends this wait.
        var never: std.Io.Event = .unset;
        never.waitUncancelable(ctx.io());
    }
};

pub const AppModule = struct {
    pub const module: zefir.app.Module = .{
        .providers = &.{http.testing.Backend},
        .controllers = &.{ReportController},
        .factories = &.{Servers},
        .values = &.{*Probe},
    };

    pub const Servers = struct {
        pub fn httpServer(gpa: std.mem.Allocator, backend: *http.testing.Backend, controllers: zefir.app.Controllers(AppModule)) !http.Server {
            return .init(gpa, .{ .controllers = controllers }, .{ .listen = .{ .backend = backend.backend() } });
        }
    };
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var probe: Probe = .{};
    // A stop of 200 ms: less than the 250 ms a server keeps for its own
    // end, so the server gives up at once instead of near the deadline.
    var app = try zefir.App(AppModule).init(init.gpa, io, .{&probe}, .{ .shutdown_timeout = .fromMilliseconds(200) });
    defer app.deinit();

    var client = try io.concurrent(requestReport, .{ &app, io });
    defer client.cancel(io) catch {};
    var ctrl_c = try io.concurrent(pressCtrlC, .{ &app, &probe, io });
    defer ctrl_c.cancel(io) catch {};

    // Never returns: the stop runs out of time, and run ends the process.
    try app.run();
}

/// The client: once App runs, a request of the report.
fn requestReport(app: *zefir.App(AppModule), io: std.Io) !void {
    while (!app.isReady()) try io.sleep(.fromMilliseconds(1), .awake);
    const backend: *http.testing.Backend = app.get(http.testing.Backend);
    var res = try backend.request(io, .{ .method = .GET, .target = "/report" });
    res.deinit();
}

/// What Ctrl+C does in a service, once the request is in the handler.
fn pressCtrlC(app: *zefir.App(AppModule), probe: *Probe, io: std.Io) !void {
    try probe.entered.wait(io);
    app.requestStop();
}
```

Its step in `build.zig`, next to those of the shop:

```zig
// build.zig of the shop
const stuck = b.addExecutable(.{
    .name = "stuck",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/stuck.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zefir", .module = zefir.module("zefir") }},
    }),
});
b.step("stuck", "Run a server that does not stop").dependOn(&b.addRunArtifact(stuck).step);
```

And its run:

```text
$ zig build stuck
info(zefir_app): AppModule.Servers.httpServer started
info(zefir_app): stopping
warning(zefir_app): AppModule.Servers.httpServer did not stop cleanly: error.ShutdownTimeout
error(zefir_app): AppModule.Servers.httpServer did not stop in time; the process exits with code 1
AppModule.Servers.httpServer did not stop in time; the process exits with code 1
```

The program has no logger, so `std.log` writes App's records to stderr.
The HTTP server gives up 250 ms before the deadline and returns
`error.ShutdownTimeout`, and App ends the process.

- **Without `run`**, when your code calls `start` and `wait` itself, they
  return `error.ShutdownTimeout`: `wait` when the stop ran out of time, and
  `start` when it failed and stopping what had started ran out of time.
  End the process then: `deinit` frees nothing that a task may still use.
- **rpc on NATS** closes its transport within the transport's own limits,
  which the deadline does not cut: a close that takes long near the
  deadline makes the stop late too.

## When the build stops

The files below are App's own compile checks, from
`src/core/app/tests/compile_errors/` of the repository: each must fail to
compile with the message after it. They import zefir-core directly and
write `core.App` and `core.app`; an application writes `zefir.App` and
`zefir.app`, the same types.

A dependency that no module the bean's module sees provides:

```zig
//! Must not compile: a dependency nothing the module sees provides.
const core = @import("core");

const Cache = struct { hits: u32 };
const X = struct { cache: *Cache };

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{X} };
};

test {
    _ = core.App(Root);
}
```

```text
error: zefir.App(Root): Root.X.cache needs *Cache, and nothing Root sees provides it; add Cache to Root.providers (or a factory that returns it), import a module that exports it, or declare *const Cache in Root.values and pass it to App.init
```

A cycle, with its whole path:

```zig
//! Must not compile: three providers that take each other in a ring.
const core = @import("core");

const X = struct { y: *Y };
const Y = struct { z: *Z };
const Z = struct { x: *X };

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{ X, Y, Z } };
};

test {
    _ = core.App(Root);
}
```

```text
error: zefir.App(Root): dependency cycle: Root.X (.y) -> Root.Y (.z) -> Root.Z (.x) -> Root.X
```

A method of the contract with another signature, here a `shutdown` without
a deadline:

```zig
//! Must not compile: a bean with the shutdown of rpc and http before App, without a deadline.
const std = @import("std");
const core = @import("core");

const Job = struct {
    pub fn shutdown(_: *Job, _: std.Io) !void {}
};

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{Job} };
};

test {
    _ = core.App(Root);
}
```

```text
error: zefir.App(Root): Job.shutdown has the wrong signature; expected pub fn shutdown(self: *Job, io: std.Io, deadline: std.Io.Clock.Timestamp) !void
```

## What your editor completes

ZLS 0.17 completes App's names in a package that gets Zefir through
`build.zig`:

| Where you write | What it completes |
|---|---|
| `pub const module: zefir.app.Module = .{ . }` | the fields of a module that are not written yet |
| `.providers = &.{ UserRep }` | the types of the file |
| `.imports = &.{ users. }` | the declarations of that file |
| `zefir.app.` | `Controllers`, `Handlers`, `Module`, `Options`, `State`, `Status`, … |
| `zefir.App(AppModule).init(…, .{ . })` | `shutdown_timeout` |
| `deps.` in `init(deps: struct { … })` | the fields of the struct |
| `.{ . }`, the options of `http.Server.init` | `listen`, `prefix`, `static`, `request_timeout`, … |

It does not complete:

- **after `app.get(T).`**: name the type, `const service:
  *orders.OrderService = app.get(orders.OrderService);`, and it completes
  `service.`;
- **after `controllers.`** of `Controllers(M)`: the tuple is handed to the
  server as it is;
- **the parts of a server**, `.controllers`, `.middleware`,
  `.error_handler`, `.strict_errors`, `.handlers` and `.authenticator`,
  which `init` takes as `anytype`: a typo there is a compile error that
  lists them.
