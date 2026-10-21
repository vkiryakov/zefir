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
};

const wrong = " has the wrong signature; expected ";

const dir = "src/core/app/tests/compile_errors/";
