//! What build.zig compiles for the compile checks of zefir.App, read by
//! `addAppCompileChecks`. Paths are relative to the repository root and
//! stay inside `src/`, the part of the package that `build.zig.zon` ships,
//! since a client's build runs zefir's build.zig too. Each file is
//! application code: a `test` block that imports "core" and names
//! `core.App(Root)` (or calls its `init` or `get`) for a graph that App
//! must refuse. Naming the type is enough: App checks the graph then.

/// A file that must fail to compile with an error whose message is
/// `expect`: the whole text after `error: ` to the end of the line.
pub const Fixture = struct { file: []const u8, expect: []const u8 };

const not_module = " is not a module: it has no `pub const module: zefir.app.Module`";
const untyped = ".module is not a zefir.app.Module; declare it as `pub const module: zefir.app.Module = .{ ... }`";
const values = "Root.values has *Recorder, *const Config, *const Logger";

/// Files in src/core/app/tests/compile_errors/.
pub const compile_errors = [_]Fixture{
    // The root and the module graph.
    .{ .file = dir ++ "root_not_module.zig", .expect = "zefir.App(Config): Config" ++ not_module },
    .{ .file = dir ++ "root_not_struct.zig", .expect = "zefir.App(u32): u32" ++ not_module },
    .{ .file = dir ++ "root_untyped.zig", .expect = "zefir.App(Root): Root" ++ untyped },
    .{ .file = dir ++ "cycle_modules.zig", .expect = "zefir.App(Root): module import cycle: A -> B -> C -> A" },
    .{ .file = dir ++ "import_self.zig", .expect = "zefir.App(Root): module import cycle: A -> A" },
    .{ .file = dir ++ "cycle_across_modules.zig", .expect = "zefir.App(Root): module import cycle: UsersM -> OrdersM -> UsersM" },
    .{ .file = dir ++ "import_not_module.zig", .expect = "zefir.App(Root): Root.imports: Config" ++ not_module },
    .{ .file = dir ++ "import_untyped.zig", .expect = "zefir.App(Root): Root.imports: A" ++ untyped },
    .{ .file = dir ++ "import_twice.zig", .expect = "zefir.App(Root): Root.imports: A is there twice" },
    .{ .file = dir ++ "module_field_typo.zig", .expect = "no field named 'provders' in struct 'app.Module'" },
    // Cycles of beans.
    .{ .file = dir ++ "cycle_beans.zig", .expect = "zefir.App(Root): dependency cycle: Root.X (.y) -> Root.Y (.z) -> Root.Z (.x) -> Root.X" },
    .{ .file = dir ++ "cycle_self.zig", .expect = "zefir.App(Root): Root.X (.next) needs X itself" },
    // Values.
    .{ .file = dir ++ "values_in_child.zig", .expect = "zefir.App(Root): A declares .values or .overrides, which only the root module Root declares" },
    .{ .file = dir ++ "values_not_pointer.zig", .expect = "zefir.App(Root): Root.values: u16 is not a pointer; a value is a ready object App takes by pointer: declare *const u16 and pass &x" },
    .{ .file = dir ++ "values_twice.zig", .expect = "zefir.App(Root): Root.values: *const Config and *Config are values of one type; a type is one value: give one a wrapper type" },
    .{ .file = dir ++ "init_value_undeclared.zig", .expect = "zefir.App(Root): App.init: value 3 (*const u16) is not declared: " ++ values ++ "; declare it there, or drop it" },
    .{ .file = dir ++ "init_value_missing.zig", .expect = "zefir.App(Root): App.init: Root.values declares *const Logger, but App.init got no such value; pass it: .{ ..., &x }" },
    .{ .file = dir ++ "init_value_twice.zig", .expect = "zefir.App(Root): App.init: values 1 and 3 are both Config; pass each value once" },
    .{ .file = dir ++ "init_value_const.zig", .expect = "zefir.App(Root): App.init: value 0 is *const Recorder, but Root.values declares *Recorder; pass a pointer to a var" },
    .{ .file = dir ++ "init_not_tuple.zig", .expect = "zefir.App(Root): App.init: the values must be a tuple of pointers, such as .{ &config, &logger }; got *Recorder" },
    .{ .file = dir ++ "init_value_not_pointer.zig", .expect = "zefir.App(Root): App.init: value 2 is a Logger; a value is a pointer: pass &x" },
    // Providers and their dependencies.
    .{ .file = dir ++ "provider_not_struct.zig", .expect = "zefir.App(Root): Root.providers: u32 is not a struct; a provider is a struct App builds with its init or by filling its fields" },
    .{ .file = dir ++ "provider_module.zig", .expect = "zefir.App(Root): Root.providers: A is a module; list it in .imports" },
    .{ .file = dir ++ "provider_unbuildable.zig", .expect = "zefir.App(Root): Root.Counter.count needs u32, and nothing Root sees provides it; App injects beans (structs) and values: " ++
        "declare *const u32 in Root.values and take a pointer, or give it a default" },
    .{ .file = dir ++ "provider_init_returns.zig", .expect = "zefir.App(Root): Root.providers: X.init returns *X; it must return X or !X" },
    .{ .file = dir ++ "missing.zig", .expect = "zefir.App(Root): Root.X.cache needs *Cache, and nothing Root sees provides it; add Cache to Root.providers (or a factory that returns it), " ++
        "import a module that exports it, or declare *const Cache in Root.values and pass it to App.init" },
    .{ .file = dir ++ "status_mutable.zig", .expect = "zefir.App(Root): Root.X.status is *zefir.app.Status, which is read-only: take *const zefir.app.Status" },
    .{ .file = dir ++ "value_mutable.zig", .expect = "zefir.App(Root): Root.X.config needs *Config, but Root.values declares *const Config; declare *Config to take it mutable, or take *const Config" },
    .{ .file = dir ++ "deps_nested.zig", .expect = "zefir.App(Root): Root.Report.init param 0.inner needs Inner, and nothing Root sees provides it; add Inner to Root.providers (or a factory that returns it), " ++
        "import a module that exports it, or declare *const Inner in Root.values and pass it to App.init" },
    // The bean contract and the marker.
    .{ .file = dir ++ "wrong_start.zig", .expect = "zefir.App(Root): Job.start" ++ wrong ++ "pub fn start(self: *Job, io: std.Io) !void" },
    .{ .file = dir ++ "wrong_wait.zig", .expect = "zefir.App(Root): Job.wait" ++ wrong ++ "pub fn wait(self: *Job, io: std.Io) !void" },
    .{ .file = dir ++ "wrong_request_stop.zig", .expect = "zefir.App(Root): Job.requestStop" ++ wrong ++ "pub fn requestStop(self: *Job, io: std.Io) void" },
    .{ .file = dir ++ "wrong_shutdown.zig", .expect = "zefir.App(Root): Job.shutdown" ++ wrong ++ "pub fn shutdown(self: *Job, io: std.Io, deadline: std.Io.Clock.Timestamp) !void" },
    .{ .file = dir ++ "wrong_is_ready.zig", .expect = "zefir.App(Root): Job.isReady" ++ wrong ++ "pub fn isReady(self: *const Job) bool" },
    .{ .file = dir ++ "wrong_deinit.zig", .expect = "zefir.App(Root): Job.deinit" ++ wrong ++ "pub fn deinit(self: *Job) void or pub fn deinit(self: *Job, io: std.Io) void" },
    .{ .file = dir ++ "marker_hint.zig", .expect = "zefir.App(Root): Transport.start" ++ wrong ++ "pub fn start(self: *Transport, io: std.Io) !void; " ++
        "if Transport.start belongs to another contract (a transport of rpc), declare `pub const app_lifecycle = false;`" },
    .{ .file = dir ++ "marker_value.zig", .expect = "zefir.App(Root): Root.providers: Transport.app_lifecycle is true; " ++
        "the marker only says false (App builds and frees the type, its owner starts and stops it): write false, or drop the declaration" },
    // Factories.
    .{ .file = dir ++ "factory_non_fn.zig", .expect = "zefir.App(Root): Root.factories: Tools.retries is not a function; a factories struct holds only pub fns, one per bean (make helpers private)" },
    .{ .file = dir ++ "factory_void.zig", .expect = "zefir.App(Root): Root.factories: Tools.setup returns void" ++ factory_returns },
    .{ .file = dir ++ "factory_error_void.zig", .expect = "zefir.App(Root): Root.factories: Tools.connect returns error{Down}!void" ++ factory_returns },
    .{ .file = dir ++ "factory_generic.zig", .expect = "zefir.App(Root): Root.factories: Tools.make: param 0 is anytype or generic; App gives each param by its type" },
    .{ .file = dir ++ "factory_empty.zig", .expect = "zefir.App(Root): Root.factories: Tools has no pub fn; each pub fn of a factories struct is a bean" },
    .{ .file = dir ++ "cycle_factory.zig", .expect = "zefir.App(Root): dependency cycle: Root.Repo (.db) -> Root.Factories.database (param 0) -> Root.Repo" },
    // Controllers and handlers.
    .{ .file = dir ++ "controller_not.zig", .expect = "zefir.App(Root): Root.controllers: Plain is not a controller: it does not declare `pub const http_routes`" },
    .{ .file = dir ++ "handler_not.zig", .expect = "zefir.App(Root): Root.handlers: Plain is not a handler: it does not declare `pub const rpc_handler`" },
    .{ .file = dir ++ "controller_lifecycle.zig", .expect = "zefir.App(Root): Root.Ctl declares deinit, but App drives no lifecycle on controllers and handlers (their server does); " ++
        "move what needs it into a provider" },
    .{ .file = dir ++ "controller_injected.zig", .expect = "zefir.App(Root): Reports.Peek.ctl needs *UsersController, a controller of UsersModule; " ++ not_injected },
    .{ .file = dir ++ "controllers_unreachable.zig", .expect = "zefir.App(Root): Reports.Servers.http param 2 takes zefir.app.Controllers(UsersModule), " ++
        "but Reports does not import that module (directly or through its imports); import it in Reports" },
    .{ .file = dir ++ "tuple_dep.zig", .expect = "zefir.App(Root): Root.X.pair is the tuple struct { u8, u8 }; App gives a tuple only as zefir.app.Controllers(M) or zefir.app.Handlers(M)" },
    .{ .file = dir ++ "cycle_controllers.zig", .expect = "zefir.App(Root): dependency cycle: Root.Servers.http (param 2) -> Root.Ctl (.server) -> Root.Servers.http" },
    // What a module sees, and its exports.
    .{ .file = dir ++ "not_imported.zig", .expect = "zefir.App(Root): Reports.Peek.users needs *UserService, which UsersModule exports, but Reports does not import UsersModule; " ++
        "add it: .imports = &.{ ..., UsersModule }" },
    .{ .file = dir ++ "not_exported.zig", .expect = "zefir.App(Root): Reports.Peek.repo needs *UserRepository, which is private to UsersModule; " ++
        "export it (UsersModule: .exports = &.{ ..., UserRepository })" },
    .{ .file = dir ++ "struct_param_bean.zig", .expect = "zefir.App(Root): Reports.Peek.init param 0 needs UserRepository, which is private to UsersModule; " ++
        "export it (UsersModule: .exports = &.{ ..., UserRepository })" },
    .{ .file = dir ++ "export_invisible.zig", .expect = "zefir.App(Root): Reports.exports: UserService is neither a provider or factory result of Reports nor an export of a module it imports" },
    .{ .file = dir ++ "export_controller.zig", .expect = "zefir.App(Root): Root.exports: Ctl is a controller; controllers and handlers are not exported: " ++
        "a server factory takes them as zefir.app.Controllers(M) or Handlers(M)" },
    .{ .file = dir ++ "export_module.zig", .expect = "zefir.App(Root): Root.exports: A is a module; a module exports beans: list the exports of A to pass on one by one" },
    .{ .file = dir ++ "export_value.zig", .expect = "zefir.App(Root): Root.exports: Config is a value of Root.values, which every module sees; drop it from .exports" },
    .{ .file = dir ++ "exports_twice.zig", .expect = "zefir.App(Root): Root.exports: X is there twice" },
    // One type, one bean.
    .{ .file = dir ++ "two_beans.zig", .expect = "zefir.App(Root): two beans of type Database: Root.Dbs.usersDb and Root.Dbs.analyticsDb; App injects by type, so a type is one bean: " ++
        "give each its own type, such as `pub const UsersDb = struct { database: Database };`, and take *UsersDb" },
    .{ .file = dir ++ "providers_twice.zig", .expect = "zefir.App(Root): Root.providers lists X twice" },
    .{ .file = dir ++ "controllers_twice.zig", .expect = "zefir.App(Root): Root.controllers lists Ctl twice" },
    .{ .file = dir ++ "value_is_bean.zig", .expect = "zefir.App(Root): Root.values declares *const Database, but InfraModule.Factories.database is a bean of that type; " ++
        "a type is one bean: drop one, or give it a wrapper type" },
    .{ .file = dir ++ "value_unused.zig", .expect = "zefir.App(Root): Root.values declares *const Config, but no bean takes it; drop it from Root.values and from App.init" },
    // Copies and options.
    .{ .file = dir ++ "bean_copy.zig", .expect = "zefir.App(Root): Reports.Stats.client takes Client by value, but App drives that bean (start, shutdown, deinit): " ++
        "a copy would be a second Client; take *Client" },
    .{ .file = dir ++ "options_as_deps.zig", .expect = "zefir.App(Root): Root.Cache.init param 1 is Cache.Options" ++ nothing_to_inject ++ "build Cache in a factory and pass its options there" },
    .{ .file = dir ++ "options_as_deps_factory.zig", .expect = "zefir.App(Root): Root.Tools.cache param 1 is Cache.Options" ++ nothing_to_inject ++ "write them inside the factory" },
    // get.
    .{ .file = dir ++ "get_unknown.zig", .expect = "zefir.App(Root): get(Foo): no bean of type Foo in Root" ++ get_rule },
    .{ .file = dir ++ "get_value.zig", .expect = "zefir.App(Root): get(Config): no bean of type Config in Root" ++ get_rule },
    // One controller, one server (design §5.8).
    .{ .file = dir ++ "controller_two_servers.zig", .expect = "zefir.App(AppModule): AdminModule.AdminController is served by both AppModule.Servers.httpServer (param 2) " ++
        "and AppModule.Servers.adminHttp (param 2); " ++ one_server ++ "AdminModule" },
    .{ .file = dir ++ "controller_equal_tuples.zig", .expect = "zefir.App(Root): UsersModule.UsersController is served by both Root.Servers.httpServer (param 0) " ++
        "and Root.Servers.adminHttp (param 0); " ++ one_server ++ "UsersModule" },
    .{ .file = dir ++ "controller_field_and_param.zig", .expect = "zefir.App(Root): UsersModule.UsersController is served by both Root.Panel (.controllers) " ++
        "and Root.Servers.httpServer (param 0); " ++ one_server ++ "UsersModule" },
    .{ .file = dir ++ "handler_two_servers.zig", .expect = "zefir.App(AppModule): OrdersModule.OrdersHandler is served by both AppModule.Servers.rpcServer (param 2) " ++
        "and AppModule.Servers.internalRpc (param 2); one handler is served by one rpc server: take Handlers of a module that does not reach OrdersModule" },
    // Overrides (design §5.9).
    .{ .file = dir ++ "override_unknown.zig", .expect = "zefir.App(Root): Root.overrides: Config is neither a module nor a bean of Root" },
    .{ .file = dir ++ "override_no_value.zig", .expect = "zefir.App(Root): UsersModule.UserService.repo needs *UserRepository, which Root overrides; " ++
        "declare *UserRepository in Root.values and pass the replacement to App.init" },
    .{ .file = dir ++ "override_unreached.zig", .expect = "zefir.App(Root): Root.overrides: InfraModule is a module Root does not reach through its imports" },
    .{ .file = dir ++ "override_controller.zig", .expect = "zefir.App(Root): Root.overrides: UsersController is a controller of UsersModule; only providers, factory results and modules are overridden" },
    .{ .file = dir ++ "override_visibility.zig", .expect = "zefir.App(Root): Reports.Peek.db needs *Database, which Root overrides in InfraModule; " ++
        "the value that takes its place is visible only where the bean would be: import InfraModule in Reports" },
    .{ .file = dir ++ "override_root.zig", .expect = "zefir.App(Root): Root.overrides: the root cannot override itself" },
    .{ .file = dir ++ "overrides_twice.zig", .expect = "zefir.App(Root): Root.overrides: UserRepository is there twice" },
    .{ .file = dir ++ "value_unused_override.zig", .expect = "zefir.App(Root): Root.values declares *Database, but no bean takes it; drop it from Root.values and from App.init" },
};

const nothing_to_inject = ", in which App has nothing to inject (every field has a default): these are options, not dependencies; ";
const get_rule = " (a value of Root.values is yours already; an overridden bean is not built)";
const one_server = "one controller is served by one server: take Controllers of a module that does not reach ";

const wrong = " has the wrong signature; expected ";
const factory_returns = "; a factory returns its bean, a struct (or an error union of one)";
const not_injected = "controllers and handlers are not injected: a server factory takes them as zefir.app.Controllers(M) or Handlers(M)";

const dir = "src/core/app/tests/compile_errors/";
