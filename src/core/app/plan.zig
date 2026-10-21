//! The plan of zefir.App, computed when the type `zefir.App(Root)` is
//! named: every bean of the modules the root reaches, where each of its
//! dependencies comes from, and the order App builds them in.
//!
//! The order (design §5.4): modules as the graph places them, imports
//! first; inside a module App walks its beans in declaration order and
//! places each after the beans of the same module it takes, depth first. A
//! bean met again on its own path is a cycle, reported with the path.
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
    /// "UsersModule.UserService": the module and the bean's type.
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
    for (g) |m| count += m.T.module.providers.len;
    var decl: [count]Bean = undefined;
    var n: usize = 0;
    for (g, 0..) |m, k| {
        mods[k].first = n;
        for (m.T.module.providers) |T| {
            checkProvider(Root, m.T, T);
            decl[n] = .{ .T = T, .kind = .provider, .module = k, .label = name(m.T) ++ "." ++ name(T) };
            n += 1;
        }
        mods[k].end = n;
    }

    // What each module sees: its own beans, and the values of the root.
    var globals: []const Cand = &.{};
    for (Root.module.values, 0..) |V, i| globals = globals ++ &[_]Cand{.{ .T = names.dataPointer(V).?.child, .src = .{ .value = i } }};
    for (&mods) |*mp| {
        var vis: []const Cand = &.{};
        for (mp.first..mp.end) |i| vis = vis ++ &[_]Cand{.{ .T = decl[i].T, .src = .{ .bean = i } }};
        mp.visible = vis;
    }

    // Where every dependency comes from.
    const final_mods = mods;
    for (&decl) |*b| b.sources = beanSources(.{ .Root = Root, .mods = &final_mods, .beans = &decl, .globals = globals, .k = b.module }, b.*);

    // The creation order, and the beans in it.
    const order = orderOf(Root, &final_mods, &decl);
    var pos: [count]usize = undefined;
    for (order, 0..) |d, c| pos[d] = c;
    var beans: [count]Bean = undefined;
    for (order, 0..) |d, c| {
        beans[c] = decl[d];
        beans[c].sources = remap(decl[d].sources, &pos);
    }

    // Entries: the beans App calls a method of.
    var entry_count: usize = 0;
    for (&beans) |*b| if (contract.needsEntry(b.T)) {
        b.entry = entry_count;
        entry_count += 1;
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

const Ctx = struct {
    Root: type,
    mods: []const ModPlan,
    beans: []const Bean,
    globals: []const Cand,
    /// The module of the bean that asks.
    k: usize,
};

fn beanSources(comptime ctx: Ctx, comptime b: Bean) []const Source {
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
/// dependencies; a struct inside one is an ordinary dependency.
fn depSource(comptime ctx: Ctx, comptime P: type, comptime who: []const u8, comptime top: bool) Source {
    if (P == std.mem.Allocator) return .gpa;
    if (P == std.Io) return .io;
    if (P == *const contract.Status) return .status;
    if (P == *contract.Status) @compileError(pre(ctx.Root) ++ who ++ " is *zefir.app.Status, which is read-only: take *const zefir.app.Status");
    if (names.dataPointer(P)) |ptr| return ref(ctx, ptr.child, if (ptr.attrs.@"const") .const_ptr else .ptr, who);
    if (top and names.isPlainStruct(P) and findCand(ctx.mods[ctx.k].visible, P) == null and findCand(ctx.globals, P) == null)
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

/// Nothing the module of ctx sees provides T.
fn missing(comptime ctx: Ctx, comptime T: type, comptime how: How, comptime who: []const u8) noreturn {
    const p = pre(ctx.Root) ++ who ++ " needs " ++ depName(T, how);
    const here = name(ctx.mods[ctx.k].T);
    if (!names.isContainer(T)) @compileError(p ++ ", and nothing " ++ here ++ " sees provides it; App injects beans (structs) and values: declare *const " ++
        typeName(T) ++ " in " ++ name(ctx.Root) ++ ".values and take a pointer, or give it a default");
    @compileError(p ++ ", and nothing " ++ here ++ " sees provides it; add " ++ typeName(T) ++ " to " ++ here ++ ".providers (or a factory that returns it), import a module that exports it, or declare *const " ++
        typeName(T) ++ " in " ++ name(ctx.Root) ++ ".values and pass it to App.init");
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
        else => s,
    };
    const final = out;
    return &final;
}
