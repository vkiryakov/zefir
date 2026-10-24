//! The users of the shop: their repository, their service and their HTTP
//! controller.

const std = @import("std");
const zefir = @import("zefir");
const http = zefir.http;
const log = zefir.log;
const mongo = zefir.mongo;
const bson = zefir.mongo_bson;
const infra = @import("infra.zig");

pub const UsersModule = struct {
    pub const module: zefir.app.Module = .{
        .imports = &.{infra.InfraModule},
        .providers = &.{ UserRepository, UserService },
        .controllers = &.{UsersController},
        // UserRepository stays private: other modules see the service only.
        .exports = &.{UserService},
    };
};

pub const User = struct { id: u64, name: []const u8 };

/// Without init: App fills the fields, each a dependency.
pub const UserRepository = struct {
    db: *infra.ShopDb, // an export of InfraModule

    /// How a user lies in the collection "users": BSON has no u64.
    const Document = struct { _id: i64, name: []const u8 };

    /// The user `id`, or null; its strings live in `arena`.
    pub fn find(repo: *UserRepository, io: std.Io, op: mongo.OperationContext, arena: std.mem.Allocator, id: u64) !?User {
        const key = std.math.cast(i64, id) orelse return null;
        const doc = try repo.db.db.collection("users").findOne(io, op, .{ ._id = key }, .{ .allocator = arena }) orelse return null;
        const user = try bson.decode(Document, arena, doc.raw(), .{});
        return .{ .id = id, .name = user.name };
    }
};

/// With init: its params are dependencies.
pub const UserService = struct {
    repo: *UserRepository,
    logger: log.Logger,

    pub fn init(repo: *UserRepository, logger: *const log.Logger) UserService {
        return .{ .repo = repo, .logger = logger.scoped("users") };
    }

    pub fn find(service: *UserService, io: std.Io, op: mongo.OperationContext, arena: std.mem.Allocator, id: u64) !?User {
        return service.repo.find(io, op, arena, id);
    }
};

/// An HTTP controller: http gives its label, `http_routes`.
pub const UsersController = struct {
    service: *UserService,

    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .get = http.get("/{id}", .{}) },
    });

    /// The user, or 404 with null.
    pub fn get(self: *UsersController, ctx: *http.Context) !http.Json(?User) {
        const path = try ctx.path(struct { id: u64 });
        const user = self.service.find(ctx.io(), .of(ctx.operation()), ctx.allocator(), path.id) catch |err| {
            self.service.logger.warn("Users unavailable", .{ .reason = err });
            return error.Unavailable;
        };
        return .{ .value = user, .status = if (user == null) 404 else 200 };
    }
};
