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
