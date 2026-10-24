//! The client of Mongo and its two databases, NATS and the transport of rpc
//! on it.

const std = @import("std");
const zefir = @import("zefir");
const mongo = zefir.mongo;
const bson = zefir.mongo_bson;
const nats = zefir.nats;
const rpc_nats = zefir.rpc_nats;
const Config = @import("Config.zig");

pub const InfraModule = struct {
    pub const module: zefir.app.Module = .{
        // The generator of _id: one for the application; its init takes
        // only io.
        .providers = &.{bson.ObjectId.Generator},
        .factories = &.{ Mongo, Nats },
        // What the modules that import InfraModule may take. The clients of
        // Mongo and NATS stay private: the rest of the code sees the
        // databases and the transport.
        .exports = &.{ ShopDb, AnalyticsDb, rpc_nats.Transport },
    };

    /// Each pub fn is a bean: its params are dependencies, its return type
    /// is the bean's type.
    pub const Mongo = struct {
        /// App starts the client (start = connect) before the servers and
        /// closes it after them.
        pub fn mongoClient(gpa: std.mem.Allocator, io: std.Io, config: *const Config) !mongo.Client {
            return .init(gpa, io, .{
                .uri = config.mongo.uri,
                .password = if (config.mongo.password) |password| password.expose() else null,
            });
        }
        pub fn shopDb(client: *mongo.Client, ids: *bson.ObjectId.Generator) ShopDb {
            return .{ .db = .init(client, "shop", ids) };
        }
        pub fn analyticsDb(client: *mongo.Client, ids: *bson.ObjectId.Generator) AnalyticsDb {
            return .{ .db = .init(client, "analytics", ids) };
        }
    };

    pub const Nats = struct {
        pub fn natsClient(gpa: std.mem.Allocator, io: std.Io, config: *const Config) !nats.Client {
            return .init(gpa, io, .{ .servers = &.{config.nats.url}, .name = "shop" });
        }
        /// The transport of rpc on NATS. Its start, drain and close belong
        /// to the rpc server: the type declares `app_lifecycle = false`,
        /// and App only builds and frees it.
        pub fn bus(gpa: std.mem.Allocator, client: *nats.Client) !rpc_nats.Transport {
            return .init(gpa, client, .{});
        }
    };
};

/// Two databases of one client. App injects by type, so each has a type of
/// its own.
pub const ShopDb = struct { db: mongo.Database };
pub const AnalyticsDb = struct { db: mongo.Database };
