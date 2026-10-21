//! The shop of design §3 on the mocks: the infrastructure, the users, the
//! orders, and the root with its servers. Only the clients, the transport
//! and the servers have lifecycle methods; the services and the
//! repositories have none. The factories take the recorder the mocks write
//! into, where the real ones take their options.
const std = @import("std");
const zapp = @import("../../app.zig");
const mocks = @import("mocks.zig");

const mongo = mocks.mongo;
const nats = mocks.nats;
const rpc_nats = mocks.rpc_nats;
const http = mocks.http;
const rpc = mocks.rpc;
const Config = mocks.Config;
const Logger = mocks.Logger;
const Recorder = mocks.Recorder;

pub const InfraModule = struct {
    pub const module: zapp.Module = .{
        .providers = &.{mongo.bson.ObjectId.Generator},
        .factories = &.{ Mongo, Nats },
        // The clients stay private: the other modules see the databases and the transport.
        .exports = &.{ ShopDb, AnalyticsDb, rpc_nats.Transport },
    };

    pub const Mongo = struct {
        pub fn mongoClient(gpa: std.mem.Allocator, io: std.Io, config: *const Config, rec: *Recorder) !mongo.Client {
            return .init(gpa, io, rec, config.mongo_uri);
        }
        pub fn shopDb(client: *mongo.Client, ids: *mongo.bson.ObjectId.Generator) ShopDb {
            return .{ .db = .init(client, "shop", ids) };
        }
        pub fn analyticsDb(client: *mongo.Client, ids: *mongo.bson.ObjectId.Generator) AnalyticsDb {
            return .{ .db = .init(client, "analytics", ids) };
        }
    };

    pub const Nats = struct {
        pub fn natsClient(gpa: std.mem.Allocator, io: std.Io, rec: *Recorder) !nats.Client {
            return .init(gpa, io, rec);
        }
        pub fn bus(gpa: std.mem.Allocator, client: *nats.Client) !rpc_nats.Transport {
            return .init(gpa, client);
        }
    };
};

/// Two databases of one client: App injects by type, so each has a type of its own.
pub const ShopDb = struct { db: mongo.Database };
pub const AnalyticsDb = struct { db: mongo.Database };

pub const UsersModule = struct {
    pub const module: zapp.Module = .{
        .imports = &.{InfraModule},
        .providers = &.{ UserRepository, UserService },
        .controllers = &.{UsersController},
        // UserRepository stays private: other modules see the service only.
        .exports = &.{UserService},
    };
};

pub const UserRepository = struct {
    db: *ShopDb,
    /// How many users were looked up: a test sees whether its fake was used.
    lookups: u32 = 0,

    pub fn exists(r: *UserRepository, id: u64) bool {
        r.lookups += 1;
        return id != 0;
    }
};

pub const UserService = struct {
    repo: *UserRepository,
    logger: Logger,

    pub fn init(repo: *UserRepository, logger: *const Logger) UserService {
        return .{ .repo = repo, .logger = logger.* };
    }

    pub fn exists(s: *UserService, id: u64) bool {
        return s.repo.exists(id);
    }
};

pub const UsersController = struct {
    service: *UserService,
    /// Private to UsersModule: its own controller sees it.
    repo: *UserRepository,

    pub const http_routes = .{"GET /v1/users/{id}"};
};

pub const OrdersModule = struct {
    pub const module: zapp.Module = .{
        .imports = &.{ InfraModule, UsersModule },
        // The service comes first and takes the repository: App builds the
        // repository first.
        .providers = &.{ OrderService, OrderRepository },
        .controllers = &.{OrdersController},
        .handlers = &.{OrdersHandler},
        // ShopDb is InfraModule's: a re-export (design §5.3).
        .exports = &.{ OrderService, ShopDb },
    };
};

pub const OrderRepository = struct {
    db: *ShopDb,
    analytics: *AnalyticsDb,
};

pub const OrderService = struct {
    repo: *OrderRepository,
    users: *UserService,
    logger: Logger,

    pub fn init(deps: struct { repo: *OrderRepository, users: *UserService, logger: *const Logger }) OrderService {
        return .{ .repo = deps.repo, .users = deps.users, .logger = deps.logger.* };
    }

    /// Takes an order of a user who exists.
    pub fn place(s: *OrderService, user: u64) bool {
        return s.users.exists(user);
    }
};

pub const OrdersController = struct {
    service: *OrderService,

    pub const http_routes = .{"POST /v1/orders"};
};

pub const OrdersHandler = struct {
    service: *OrderService,

    pub const rpc_handler = .{ .api = "orders.v1" };
};

pub const AppModule = struct {
    pub const module: zapp.Module = .{
        .imports = &.{ InfraModule, UsersModule, OrdersModule },
        .factories = &.{Servers},
        .controllers = &.{HealthController},
        .values = &.{ *Recorder, *const Config, *const Logger },
    };

    pub const Servers = struct {
        /// Controllers(AppModule): the controllers of AppModule and of every
        /// module it reaches, the root's own last.
        pub fn httpServer(gpa: std.mem.Allocator, rec: *Recorder, controllers: zapp.Controllers(AppModule)) !http.Server {
            return .init(gpa, rec, .{ .controllers = controllers });
        }
        pub fn rpcServer(gpa: std.mem.Allocator, rec: *Recorder, transport: *rpc_nats.Transport, handlers: zapp.Handlers(AppModule)) !rpc.Server {
            _ = transport;
            return .init(gpa, rec, .{ .handlers = handlers });
        }
    };
};

pub const HealthController = struct {
    /// A built-in dependency: App's status, read-only.
    status: *const zapp.Status,

    pub const http_routes = .{ "GET /livez", "GET /readyz" };
};
