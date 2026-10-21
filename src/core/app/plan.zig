//! The plan of zefir.App, computed when the type `zefir.App(Root)` is
//! named: every bean of the modules the root reaches, what each module sees
//! and exports, where each dependency comes from, and the order App builds
//! the beans in.
//!
//! The order (design §5.4): modules as the graph places them, imports
//! first; inside a module App walks its beans in declaration order
//! (providers; factories, structs in list order and functions in
//! declaration order; controllers; handlers) and places each after the
//! beans of the same module it takes, depth first. A bean met again on its
//! own path is a cycle, reported with the path.
const std = @import("std");
const contract = @import("contract.zig");
const graph = @import("graph.zig");
const names = @import("names.zig");

const pre = names.pre;
const name = names.name;
const typeName = names.typeName;
const num = names.num;

pub const Kind = enum { provider, factory, controller, handler };

pub const Bean = struct {
    T: type,
    kind: Kind,
    /// The index of the bean's module in the graph.
    module: usize,
    /// A factory result: the factories struct and the name of the function.
    Holder: type = void,
    fn_name: [:0]const u8 = "",
    /// "UsersModule.UserService", "InfraModule.Mongo.mongoClient".
    label: []const u8,
    sources: []const Source = &.{},
    /// The bean's index among the entries, when App calls a method of it.
    entry: ?usize = null,
};

pub const How = enum { ptr, const_ptr, copy };

/// Where one dependency (a field or a param) comes from.
pub const Source = union(enum) {
    gpa,
    io,
    status,
    /// A field with a default value, or a comptime field: App leaves it as declared.
    default,
    bean: Ref,
    value: Ref,
    /// A struct param whose fields are dependencies.
    deps: Deps,
    /// `Controllers(M)` or `Handlers(M)`: pointers to these beans, in order.
    list: []const usize,
};

/// A bean (its index in the plan) or a value (its index in `Root.module.values`).
pub const Ref = struct { i: usize, how: How };
pub const Deps = struct { P: type, fields: []const Source };

/// What a module may take by type: a bean or a value of the root.
pub const Cand = struct { T: type, src: union(enum) { bean: usize, value: usize } };

pub const ModPlan = struct {
    T: type,
    imports: []const usize,
    /// Its beans are `beans[first..end]` in declaration order.
    first: usize = 0,
    end: usize = 0,
    /// Its controllers and handlers, in list order.
    controllers: []const usize = &.{},
    handlers: []const usize = &.{},
    /// What its importers see.
    exports: []const Cand = &.{},
    /// What its beans see: its providers and factory results, then the
    /// exports of its imports.
    visible: []const Cand = &.{},
};

pub const Plan = struct {
    /// In creation order; sources point to creation indices.
    beans: []const Bean,
    entry_count: usize,
    /// "build order: " and the labels in creation order, joined by ", ".
    build_order: []const u8,
};

pub fn planOf(comptime Root: type) Plan {
    return PlanOf(Root).value;
}

fn PlanOf(comptime Root: type) type {
    return struct {
        const value = computePlan(Root);
    };
}

/// Beans meet in buckets by the hash of their type's name, so that finding
/// the bean of a type is not a walk over all of them.
const bucket_count = 256;
const Buckets = [bucket_count][]const usize;

fn bucketOf(comptime T: type) usize {
    return std.hash.Fnv1a_32.hash(@typeName(T)) % bucket_count;
}

fn computePlan(comptime Root: type) Plan {
    @setEvalBranchQuota(names.eval_quota);
    const g = graph.modulesOf(Root);
    const p = pre(Root);
    var mods: [g.len]ModPlan = undefined;
    for (g, 0..) |m, k| {
        mods[k] = .{ .T = m.T, .imports = m.imports };
        if (m.T != Root and (m.T.module.values.len > 0 or m.T.module.overrides.len > 0))
            @compileError(p ++ name(m.T) ++ " declares .values or .overrides, which only the root module " ++ name(Root) ++ " declares");
    }
    checkValues(Root);

    // The beans, module by module, each module's in declaration order.
    var count: usize = 0;
    for (g) |m| {
        const M = m.T.module;
        count += M.providers.len + M.controllers.len + M.handlers.len;
        for (M.factories) |F| count += checkFactories(Root, m.T, F);
    }
    var decl: [count]Bean = undefined;
    var n: usize = 0;
    for (g, 0..) |m, k| {
        const M = m.T;
        mods[k].first = n;
        for (M.module.providers) |T| {
            checkProvider(Root, M, T);
            decl[n] = .{ .T = T, .kind = .provider, .module = k, .label = name(M) ++ "." ++ name(T) };
            n += 1;
        }
        for (M.module.factories) |F| for (names.fieldsOf(F).decl_names) |d| {
            const T = names.Payload(@typeInfo(@TypeOf(@field(F, d))).@"fn".return_type.?);
            decl[n] = .{ .T = T, .kind = .factory, .module = k, .Holder = F, .fn_name = d, .label = name(M) ++ "." ++ name(F) ++ "." ++ d };
            n += 1;
        };
        for ([_]Kind{ .controller, .handler }) |kind| {
            const list = if (kind == .controller) M.module.controllers else M.module.handlers;
            for (list) |T| {
                checkServed(Root, M, T, kind);
                if (kind == .controller) mods[k].controllers = mods[k].controllers ++ &[_]usize{n} else mods[k].handlers = mods[k].handlers ++ &[_]usize{n};
                decl[n] = .{ .T = T, .kind = kind, .module = k, .label = name(M) ++ "." ++ name(T) };
                n += 1;
            }
        }
        mods[k].end = n;
    }
    var buckets: Buckets = @splat(&.{});
    for (decl, 0..) |b, i| buckets[bucketOf(b.T)] = buckets[bucketOf(b.T)] ++ &[_]usize{i};
    const final_buckets = buckets;

    // What each module sees and exports; its imports come before it.
    var globals: []const Cand = &.{};
    for (Root.module.values, 0..) |V, i| globals = globals ++ &[_]Cand{.{ .T = names.dataPointer(V).?.child, .src = .{ .value = i } }};
    for (0..mods.len) |k| {
        const M = mods[k].T;
        var vis: []const Cand = &.{};
        for (mods[k].first..mods[k].end) |i| if (decl[i].kind == .provider or decl[i].kind == .factory) {
            vis = vis ++ &[_]Cand{.{ .T = decl[i].T, .src = .{ .bean = i } }};
        };
        for (mods[k].imports) |j| for (mods[j].exports) |c| {
            if (findCand(vis, c.T) == null) vis = vis ++ &[_]Cand{c};
        };
        mods[k].visible = vis;
        const at = p ++ name(M) ++ ".exports: ";
        for (M.module.exports, 0..) |E, e| {
            if (names.contains(M.module.exports[0..e], E)) @compileError(at ++ typeName(E) ++ " is there twice");
            if (findCand(vis, E)) |c| {
                mods[k].exports = mods[k].exports ++ &[_]Cand{c};
                continue;
            }
            if (beanIn(&decl, &final_buckets, E)) |i| if (decl[i].kind == .controller or decl[i].kind == .handler)
                @compileError(at ++ typeName(E) ++ " is a " ++ @tagName(decl[i].kind) ++ "; controllers and handlers are not exported: a server factory takes them as zefir.app.Controllers(M) or Handlers(M)");
            if (findCand(globals, E) != null)
                @compileError(at ++ typeName(E) ++ " is a value of " ++ name(Root) ++ ".values, which every module sees; drop it from .exports");
            if (names.isModule(E))
                @compileError(at ++ name(E) ++ " is a module; a module exports beans: list the exports of " ++ name(E) ++ " to pass on one by one");
            @compileError(at ++ typeName(E) ++ " is neither a provider or factory result of " ++ name(M) ++ " nor an export of a module it imports");
        }
    }

    // Where every dependency comes from.
    const final_mods = mods;
    for (&decl) |*b| {
        const ctx: Ctx = .{ .Root = Root, .mods = &final_mods, .beans = &decl, .buckets = &final_buckets, .globals = globals, .k = b.module };
        b.sources = beanSources(ctx, b.*);
    }

    // The creation order, and the beans in it.
    const order = orderOf(Root, &final_mods, &decl);
    var pos: [count]usize = undefined;
    for (order, 0..) |d, c| pos[d] = c;
    var beans: [count]Bean = undefined;
    for (order, 0..) |d, c| {
        beans[c] = decl[d];
        beans[c].sources = remap(decl[d].sources, &pos);
    }

    // Entries: the providers and factory results App calls a method of,
    // each method with its signature checked. Controllers and handlers have
    // no lifecycle: their server calls them.
    var entry_count: usize = 0;
    for (&beans) |*b| switch (b.kind) {
        .controller, .handler => for (contract.lifecycle_names) |m| if (@hasDecl(b.T, m))
            @compileError(p ++ b.label ++ " declares " ++ m ++ ", but App drives no lifecycle on controllers and handlers (their server does); move what needs it into a provider"),
        .provider, .factory => {
            contract.checkMethods(Root, b.T, if (b.kind == .provider) name(final_mods[b.module].T) ++ ".providers" else b.label);
            if (contract.needsEntry(b.T)) {
                b.entry = entry_count;
                entry_count += 1;
            }
        },
    };

    var build_order: []const u8 = "build order:";
    for (beans, 0..) |b, i| build_order = build_order ++ (if (i == 0) " " else ", ") ++ b.label;
    const final_beans = beans;
    return .{ .beans = &final_beans, .entry_count = entry_count, .build_order = build_order };
}

fn checkValues(comptime Root: type) void {
    const vs = Root.module.values;
    const at = pre(Root) ++ name(Root) ++ ".values: ";
    for (vs, 0..) |V, i| {
        const ptr = names.dataPointer(V) orelse
            @compileError(at ++ typeName(V) ++ " is not a pointer; a value is a ready object App takes by pointer: declare *const " ++ typeName(V) ++ " and pass &x");
        for (vs[0..i]) |W| if (names.dataPointer(W).?.child == ptr.child)
            @compileError(at ++ typeName(W) ++ " and " ++ typeName(V) ++ " are values of one type; a type is one value: give one a wrapper type");
    }
}

fn checkProvider(comptime Root: type, comptime M: type, comptime T: type) void {
    const at = pre(Root) ++ name(M) ++ ".providers: ";
    if (names.isModule(T)) @compileError(at ++ name(T) ++ " is a module; list it in .imports");
    if (!names.isPlainStruct(T)) @compileError(at ++ typeName(T) ++ " is not a struct; a provider is a struct App builds with its init or by filling its fields");
    if (@hasDecl(T, "init")) checkInit(Root, M, "providers", T);
}

/// A controller declares `http_routes`, a handler `rpc_handler`: the labels
/// zefir-http and zefir-rpc define. Their server checks the rest.
fn checkServed(comptime Root: type, comptime M: type, comptime T: type, comptime kind: Kind) void {
    const list = if (kind == .controller) "controllers" else "handlers";
    const label = if (kind == .controller) "http_routes" else "rpc_handler";
    const at = pre(Root) ++ name(M) ++ "." ++ list ++ ": ";
    if (!names.isPlainStruct(T) or !@hasDecl(T, label))
        @compileError(at ++ typeName(T) ++ " is not a " ++ @tagName(kind) ++ ": it does not declare `pub const " ++ label ++ "`");
    if (@hasDecl(T, "init")) checkInit(Root, M, list, T);
}

fn checkInit(comptime Root: type, comptime M: type, comptime list: []const u8, comptime T: type) void {
    const at = pre(Root) ++ name(M) ++ "." ++ list ++ ": " ++ name(T) ++ ".init ";
    const info = @typeInfo(@TypeOf(T.init));
    if (info != .@"fn") @compileError(at ++ "is not a function; App calls init to build " ++ name(T));
    const f = info.@"fn";
    for (f.param_types, 0..) |P, k| if (P == null) @compileError(at ++ "param " ++ num(k) ++ " is anytype or generic; App gives each param by its type");
    if (f.is_generic) @compileError(at ++ "is generic (a param is comptime); App gives each param by its type");
    const R = f.return_type orelse @compileError(at ++ "has a generic return type");
    if (names.Payload(R) != T) @compileError(at ++ "returns " ++ typeName(R) ++ "; it must return " ++ name(T) ++ " or !" ++ name(T));
}

/// The number of beans of a factories struct, after checking every pub
/// declaration of it: each is a function, and each returns its bean.
fn checkFactories(comptime Root: type, comptime M: type, comptime F: type) usize {
    const at = pre(Root) ++ name(M) ++ ".factories: ";
    if (!names.isPlainStruct(F)) @compileError(at ++ typeName(F) ++ " is not a struct of factory functions");
    const decls = names.fieldsOf(F).decl_names;
    if (decls.len == 0) @compileError(at ++ name(F) ++ " has no pub fn; each pub fn of a factories struct is a bean");
    for (decls) |d| {
        const who = at ++ name(F) ++ "." ++ d;
        const info = @typeInfo(@TypeOf(@field(F, d)));
        if (info != .@"fn") @compileError(who ++ " is not a function; a factories struct holds only pub fns, one per bean (make helpers private)");
        const f = info.@"fn";
        for (f.param_types, 0..) |P, k| if (P == null) @compileError(who ++ ": param " ++ num(k) ++ " is anytype or generic; App gives each param by its type");
        if (f.is_generic) @compileError(who ++ " is generic (a param is comptime); App gives each param by its type");
        const R = f.return_type orelse @compileError(who ++ " has a generic return type");
        switch (@typeInfo(names.Payload(R))) {
            .@"struct" => |s| if (!s.is_tuple) continue,
            .@"union", .@"enum" => continue,
            else => {},
        }
        @compileError(who ++ " returns " ++ typeName(R) ++ "; a factory returns its bean, a struct (or an error union of one)");
    }
    return decls.len;
}

const Ctx = struct {
    Root: type,
    mods: []const ModPlan,
    beans: []const Bean,
    buckets: *const Buckets,
    globals: []const Cand,
    /// The module of the bean that asks.
    k: usize,
};

/// The bean of type T, wherever it is: its declaration index.
fn beanIn(comptime beans: []const Bean, comptime buckets: *const Buckets, comptime T: type) ?usize {
    for (buckets[bucketOf(T)]) |i| if (beans[i].T == T) return i;
    return null;
}

fn beanSources(comptime ctx: Ctx, comptime b: Bean) []const Source {
    if (b.kind == .factory) return paramSources(ctx, @TypeOf(@field(b.Holder, b.fn_name)), b.label);
    if (names.hasInitFn(b.T)) return paramSources(ctx, @TypeOf(b.T.init), b.label ++ ".init");
    return fieldSources(ctx, b.T, b.label);
}

fn paramSources(comptime ctx: Ctx, comptime F: type, comptime label: []const u8) []const Source {
    const params = @typeInfo(F).@"fn".param_types;
    var out: [params.len]Source = undefined;
    for (params, 0..) |P, k| out[k] = depSource(ctx, P.?, label ++ " param " ++ num(k), true);
    const final = out;
    return &final;
}

fn fieldSources(comptime ctx: Ctx, comptime T: type, comptime label: []const u8) []const Source {
    const s = names.fieldsOf(T);
    var out: [s.field_names.len]Source = undefined;
    for (s.field_names, s.field_types, s.field_attrs, 0..) |field, FT, a, k| {
        out[k] = if (a.@"comptime" or a.default_value_ptr != null) .default else depSource(ctx, FT, label ++ "." ++ field, false);
    }
    const final = out;
    return &final;
}

/// `top`: a param of init or of a factory, which may be a struct of
/// dependencies; a struct inside one is an ordinary dependency. A struct
/// of a bean's type is that bean, never a struct of dependencies.
fn depSource(comptime ctx: Ctx, comptime P: type, comptime who: []const u8, comptime top: bool) Source {
    if (P == std.mem.Allocator) return .gpa;
    if (P == std.Io) return .io;
    if (P == *const contract.Status) return .status;
    if (P == *contract.Status) @compileError(pre(ctx.Root) ++ who ++ " is *zefir.app.Status, which is read-only: take *const zefir.app.Status");
    if (names.isTuple(P)) return .{ .list = listOf(ctx, P, who) };
    if (names.dataPointer(P)) |ptr| return ref(ctx, ptr.child, if (ptr.attrs.@"const") .const_ptr else .ptr, who);
    if (top and names.isPlainStruct(P) and findCand(ctx.mods[ctx.k].visible, P) == null and findCand(ctx.globals, P) == null and
        beanIn(ctx.beans, ctx.buckets, P) == null)
        return .{ .deps = .{ .P = P, .fields = fieldSources(ctx, P, who) } };
    return ref(ctx, P, .copy, who);
}

fn ref(comptime ctx: Ctx, comptime T: type, comptime how: How, comptime who: []const u8) Source {
    const c = findCand(ctx.mods[ctx.k].visible, T) orelse (findCand(ctx.globals, T) orelse missing(ctx, T, how, who));
    switch (c.src) {
        .bean => |i| return .{ .bean = .{ .i = i, .how = how } },
        .value => |v| {
            const V = ctx.Root.module.values[v];
            if (how == .ptr and names.dataPointer(V).?.attrs.@"const")
                @compileError(pre(ctx.Root) ++ who ++ " needs *" ++ typeName(T) ++ ", but " ++ name(ctx.Root) ++ ".values declares " ++ typeName(V) ++
                    "; declare *" ++ typeName(T) ++ " to take it mutable, or take *const " ++ typeName(T));
            return .{ .value = .{ .i = v, .how = how } };
        },
    }
}

/// Why nothing the module of ctx sees provides T: a controller, a bean of
/// a module it does not import, a private bean, or nothing anywhere.
fn missing(comptime ctx: Ctx, comptime T: type, comptime how: How, comptime who: []const u8) noreturn {
    const p = pre(ctx.Root) ++ who ++ " needs " ++ depName(T, how);
    const here = name(ctx.mods[ctx.k].T);
    if (beanIn(ctx.beans, ctx.buckets, T)) |i| {
        const b = ctx.beans[i];
        const owner = name(ctx.mods[b.module].T);
        if (b.kind == .controller or b.kind == .handler)
            @compileError(p ++ ", a " ++ @tagName(b.kind) ++ " of " ++ owner ++ "; controllers and handlers are not injected: a server factory takes them as zefir.app.Controllers(M) or Handlers(M)");
        if (findCand(ctx.mods[b.module].exports, T) != null)
            @compileError(p ++ ", which " ++ owner ++ " exports, but " ++ here ++ " does not import " ++ owner ++ "; add it: .imports = &.{ ..., " ++ owner ++ " }");
        const imported = for (ctx.mods[ctx.k].imports) |j| {
            if (j == b.module) break true;
        } else false;
        @compileError(p ++ ", which is private to " ++ owner ++ "; export it (" ++ owner ++ ": .exports = &.{ ..., " ++ typeName(T) ++ " })" ++
            (if (imported) "" else " and import " ++ owner ++ " in " ++ here));
    }
    if (!names.isContainer(T)) @compileError(p ++ ", and nothing " ++ here ++ " sees provides it; App injects beans (structs) and values: declare *const " ++
        typeName(T) ++ " in " ++ name(ctx.Root) ++ ".values and take a pointer, or give it a default");
    @compileError(p ++ ", and nothing " ++ here ++ " sees provides it; add " ++ typeName(T) ++ " to " ++ here ++ ".providers (or a factory that returns it), import a module that exports it, or declare *const " ++
        typeName(T) ++ " in " ++ name(ctx.Root) ++ ".values and pass it to App.init");
}

/// The beans of `Controllers(M)` or `Handlers(M)`, for M the module of ctx
/// or a module it reaches; the tuples are told apart by type alone.
fn listOf(comptime ctx: Ctx, comptime P: type, comptime who: []const u8) []const usize {
    const g = graph.modulesOf(ctx.Root);
    const here = name(ctx.mods[ctx.k].T);
    var matched: ?[]const u8 = null;
    for (ctx.mods, 0..) |m, j| {
        const list: ?[]const u8 = if (P == graph.Controllers(m.T)) "controllers" else if (P == graph.Handlers(m.T)) "handlers" else null;
        if (list) |l| {
            if (matched == null) matched = (if (l[0] == 'c') "Controllers(" else "Handlers(") ++ name(m.T) ++ ")";
            if (j == ctx.k or graph.reaches(g, ctx.k, j)) {
                var out: []const usize = &.{};
                for (graph.modulesOf(m.T)) |sm| {
                    const jj = for (ctx.mods, 0..) |mm, i| {
                        if (mm.T == sm.T) break i;
                    } else unreachable;
                    out = out ++ @field(ctx.mods[jj], l);
                }
                return out;
            }
        }
    }
    if (matched) |x| @compileError(pre(ctx.Root) ++ who ++ " takes zefir.app." ++ x ++ ", but " ++ here ++
        " does not import that module (directly or through its imports); import it in " ++ here);
    @compileError(pre(ctx.Root) ++ who ++ " is the tuple " ++ typeName(P) ++ "; App gives a tuple only as zefir.app.Controllers(M) or zefir.app.Handlers(M)");
}

fn depName(comptime T: type, comptime how: How) []const u8 {
    return switch (how) {
        .ptr => "*" ++ typeName(T),
        .const_ptr => "*const " ++ typeName(T),
        .copy => typeName(T),
    };
}

fn findCand(comptime list: []const Cand, comptime T: type) ?Cand {
    for (list) |c| if (c.T == T) return c;
    return null;
}

/// The beans one source points to.
fn targets(comptime s: Source) []const usize {
    return switch (s) {
        .bean => |r| &.{r.i},
        .list => |l| l,
        .deps => |d| blk: {
            var out: []const usize = &.{};
            for (d.fields) |f| out = out ++ targets(f);
            break :blk out;
        },
        else => &.{},
    };
}

/// An edge of the visit: bean `to` of the same module, taken by the source at `at`.
const Edge = struct { to: usize, at: usize };

/// The creation order, as declaration indices: modules in graph order; in
/// each, its beans in declaration order, each after the beans of its module
/// it takes. Beans of other modules are placed already: a module comes
/// after its imports.
fn orderOf(comptime Root: type, comptime mods: []const ModPlan, comptime beans: []const Bean) [beans.len]usize {
    var edges: [beans.len][]const Edge = undefined;
    for (mods) |mp| for (mp.first..mp.end) |i| {
        var out: []const Edge = &.{};
        for (beans[i].sources, 0..) |s, at| for (targets(s)) |t| if (t >= mp.first and t < mp.end) {
            out = out ++ &[_]Edge{.{ .to = t, .at = at }};
        };
        edges[i] = out;
    };
    var order: [beans.len]usize = undefined;
    var n: usize = 0;
    var placed: [beans.len]bool = @splat(false);
    var on_path: [beans.len]bool = @splat(false);
    // The visit's stack: a bean, and how many of its edges it has followed.
    var stack: [beans.len]usize = undefined;
    var next: [beans.len]usize = undefined;
    for (mods) |mp| for (mp.first..mp.end) |start| {
        if (placed[start]) continue;
        var depth: usize = 1;
        stack[0] = start;
        next[0] = 0;
        on_path[start] = true;
        while (depth > 0) {
            const top = stack[depth - 1];
            if (next[depth - 1] < edges[top].len) {
                const e = edges[top][next[depth - 1]];
                next[depth - 1] += 1;
                if (placed[e.to]) continue;
                if (e.to == top) @compileError(pre(Root) ++ beans[top].label ++ edgeLabel(beans[top], e.at) ++ " needs " ++ name(beans[top].T) ++ " itself");
                if (on_path[e.to]) {
                    var text: []const u8 = "";
                    const from = for (stack[0..depth], 0..) |s, l| {
                        if (s == e.to) break l;
                    } else unreachable;
                    for (from..depth) |l| {
                        const b = beans[stack[l]];
                        text = text ++ b.label ++ edgeLabel(b, edges[stack[l]][next[l] - 1].at) ++ " -> ";
                    }
                    @compileError(pre(Root) ++ "dependency cycle: " ++ text ++ beans[e.to].label);
                }
                on_path[e.to] = true;
                stack[depth] = e.to;
                next[depth] = 0;
                depth += 1;
            } else {
                depth -= 1;
                on_path[top] = false;
                placed[top] = true;
                order[n] = top;
                n += 1;
            }
        }
    };
    return order;
}

/// " (.repo)", " (param 2)" or " (.init param 0)": where bean b takes the
/// dependency of its source `at`.
fn edgeLabel(comptime b: Bean, comptime at: usize) []const u8 {
    if (b.kind == .factory) return " (param " ++ num(at) ++ ")";
    if (names.hasInitFn(b.T)) return " (.init param " ++ num(at) ++ ")";
    return " (." ++ names.fieldsOf(b.T).field_names[at] ++ ")";
}

/// The sources with bean indices of the declaration order turned into
/// those of the creation order.
fn remap(comptime sources: []const Source, comptime pos: []const usize) []const Source {
    var out: [sources.len]Source = undefined;
    for (sources, 0..) |s, k| out[k] = switch (s) {
        .bean => |r| .{ .bean = .{ .i = pos[r.i], .how = r.how } },
        .deps => |d| .{ .deps = .{ .P = d.P, .fields = remap(d.fields, pos) } },
        .list => |l| blk: {
            var mapped: [l.len]usize = undefined;
            for (l, 0..) |i, x| mapped[x] = pos[i];
            const final = mapped;
            break :blk .{ .list = &final };
        },
        else => s,
    };
    const final = out;
    return &final;
}
