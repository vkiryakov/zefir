//! The shared shapes of the compile-error fixtures of zefir.App: the ready
//! objects a root declares in `.values`, the shapes of a client, a database
//! handle and a server, and a module of users. Each fixture is application
//! code that imports "core" and these.
const std = @import("std");
const core = @import("core");

pub const Recorder = struct { len: usize = 0 };
pub const Config = struct { port: u16 = 8080 };
pub const Logger = struct { id: u32 = 0 };

/// A provider that takes the three values, so that a root which declares
/// them gives each to a bean.
pub const Uses = struct {
    rec: *Recorder,
    config: *const Config,
    logger: *const Logger,
};

/// A handle passed by value, as `mongo.Database` is.
pub const Database = struct { name: []const u8 = "" };

/// A server over a tuple of pointers to controllers, as `http.Server` is.
pub const Server = struct {
    count: usize,

    pub fn init(controllers: anytype) Server {
        return .{ .count = controllers.len };
    }
    pub fn start(_: *Server, _: std.Io) !void {}
    pub fn deinit(_: *Server) void {}
};

/// A module of users: a private repository, an exported service and a
/// controller that takes both.
pub const UsersModule = struct {
    pub const module: core.app.Module = .{
        .providers = &.{ UserRepository, UserService },
        .controllers = &.{UsersController},
        .exports = &.{UserService},
    };
};

pub const UserRepository = struct { lookups: u32 = 0 };
pub const UserService = struct { repo: *UserRepository };

pub const UsersController = struct {
    service: *UserService,
    repo: *UserRepository,

    pub const http_routes = .{"GET /users/{id}"};
};
