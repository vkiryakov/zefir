//! zefir.app — the application container: `zefir.App(Root)` builds an
//! application out of modules, by type, and drives the lifecycle of what it
//! built.
//!
//! ```zig
//! pub const AppModule = struct {
//!     pub const module: zefir.app.Module = .{
//!         .imports = &.{ InfraModule, UsersModule },
//!         .factories = &.{Servers},
//!         .values = &.{ *const Config, *const log.Logger },
//!     };
//! };
//!
//! var app = try zefir.App(AppModule).init(gpa, io, .{ &config, &logger }, .{});
//! defer app.deinit();
//! ```
//!
//! A module is a struct that declares `pub const module: zefir.app.Module`.
//! App builds the beans of every module the root reaches through
//! `.imports`, once each: its providers, the results of its factories, its
//! controllers and its handlers. A bean takes its dependencies as fields,
//! as params of its `init` or of its factory, or as the fields of a struct
//! param; App gives each by its type. The graph is checked when the type
//! `zefir.App(Root)` is named: a dependency nothing provides, a bean a
//! module does not see and a cycle are compile errors that name the module,
//! the entry and the fix.
//!
//! Unlike the other parts of core, App holds memory, runs tasks and reads
//! the clock: it is the root of an application.

const std = @import("std");
const contract = @import("app/contract.zig");
const graph = @import("app/graph.zig");
const container = @import("app/container.zig");

/// What a module declares: `pub const module: zefir.app.Module = .{ ... }`.
/// Every list holds types; an empty list is the default.
pub const Module = struct {
    /// Modules whose exports the beans of this module take.
    imports: []const type = &.{},
    /// Types App builds: with their `init`, whose params are dependencies,
    /// or without one by filling their fields, each a dependency.
    providers: []const type = &.{},
    /// Structs whose every pub fn is a bean: the params are dependencies,
    /// the return type (or the payload of its error union) is the bean's type.
    factories: []const type = &.{},
    /// Controllers of http, types that declare `pub const http_routes`: App
    /// builds them like providers, and a server factory takes them as
    /// `zefir.app.Controllers(M)`.
    controllers: []const type = &.{},
    /// Handlers of rpc, types that declare `pub const rpc_handler`: a server
    /// factory takes them as `zefir.app.Handlers(M)`.
    handlers: []const type = &.{},
    /// What importers may take: providers and factory results of this
    /// module, or exports of the modules it imports.
    exports: []const type = &.{},
    /// The root only: the pointer types of the ready objects `App.init`
    /// takes, such as `*const Config`. Every module sees them.
    values: []const type = &.{},
    /// The root only, for tests: modules and beans App does not build; a
    /// value of `.values` takes the place of each such bean or export.
    overrides: []const type = &.{},
};

pub const Options = struct {
    /// The budget of the whole shutdown, from its start to the end of the
    /// last bean's shutdown, shared by every bean. It fits the 30 s that
    /// Kubernetes gives a pod, with room to spare.
    shutdown_timeout: std.Io.Duration = .fromSeconds(25),
};

/// The first cause of a stop or of a failure: which bean, in which step.
pub const Failure = struct {
    /// The bean's label: "InfraModule.Mongo.mongoClient", "UsersModule.UserService".
    bean: []const u8,
    step: Step,
    err: anyerror,

    pub const Step = enum { start, wait, shutdown };
};

pub const State = contract.State;
pub const Status = contract.Status;
pub const Controllers = graph.Controllers;
pub const Handlers = graph.Handlers;
pub const App = container.App;

test {
    _ = @import("app/names.zig");
    _ = @import("app/wait.zig");
    _ = @import("app/tests/app_tests.zig");
    _ = @import("app/tests/lifecycle_tests.zig");
}
