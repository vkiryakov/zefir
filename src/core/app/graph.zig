//! The module graph of zefir.App, and the tuples of controllers and
//! handlers a server factory takes.
const Module = @import("../app.zig").Module;
const names = @import("names.zig");

const pre = names.pre;
const name = names.name;

/// A module of the graph: its type and the graph indices of its imports.
pub const Mod = struct { T: type, imports: []const usize };

/// The modules X reaches through `.imports`, X included: imports first,
/// depth-first in `.imports` order, each module once, X last. X and every
/// import are checked to be modules first.
pub fn modulesOf(comptime X: type) []const Mod {
    return ModulesOf(X).value;
}

fn ModulesOf(comptime X: type) type {
    return struct {
        const value = computeModules(X);
    };
}

fn computeModules(comptime X: type) []const Mod {
    @setEvalBranchQuota(names.eval_quota);
    checkModule(X, X, null);
    var done: []const Mod = &.{};
    _ = visit(X, X, &.{}, &done);
    return done;
}

/// Places T after its imports. `done` marks the modules placed, so a module
/// imported by many is visited once; `path` holds the modules on the way
/// from X to T, for the text of a cycle.
fn visit(comptime X: type, comptime T: type, comptime path: []const type, comptime done: *[]const Mod) usize {
    for (done.*, 0..) |m, i| if (m.T == T) return i;
    for (path, 0..) |P, i| if (P == T) @compileError(pre(X) ++ "module import cycle: " ++ names.chain(path[i..] ++ &[_]type{T}));
    const list = T.module.imports;
    var imports: []const usize = &.{};
    for (list, 0..) |I, n| {
        checkModule(X, I, T);
        if (names.contains(list[0..n], I)) @compileError(pre(X) ++ name(T) ++ ".imports: " ++ name(I) ++ " is there twice");
        imports = imports ++ &[_]usize{visit(X, I, path ++ &[_]type{T}, done)};
    }
    done.* = done.* ++ &[_]Mod{.{ .T = T, .imports = imports }};
    return done.*.len - 1;
}

/// T, the root X itself (`from` null) or an entry of `from.imports`, must
/// declare `pub const module: zefir.app.Module`.
fn checkModule(comptime X: type, comptime T: type, comptime from: ?type) void {
    const where = if (from) |F| name(F) ++ ".imports: " else "";
    if (!names.isModule(T))
        @compileError(pre(X) ++ where ++ names.typeName(T) ++ " is not a module: it has no `pub const module: zefir.app.Module`");
    if (@TypeOf(T.module) != Module)
        @compileError(pre(X) ++ where ++ name(T) ++ ".module is not a zefir.app.Module; declare it as `pub const module: zefir.app.Module = .{ ... }`");
}

/// The tuple of pointers to the controllers of module M, for a factory
/// param: `controllers: zefir.app.Controllers(AppModule)`.
pub fn Controllers(comptime M: type) type {
    return ListTuple(M, "controllers");
}

/// Like `Controllers`, for the handlers of rpc.
pub fn Handlers(comptime M: type) type {
    return ListTuple(M, "handlers");
}

fn ListTuple(comptime M: type, comptime list: []const u8) type {
    var types: []const type = &.{};
    for (@field(M.module, list)) |C| types = types ++ &[_]type{*C};
    return @Tuple(types);
}
