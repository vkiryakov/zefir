//! How zefir.App builds what its plan lists: the block of memory that holds
//! every bean, the values of `init` matched by type, and one function per
//! bean, called in creation order.
const std = @import("std");
const contract = @import("contract.zig");
const lifecycle = @import("lifecycle.zig");
const names = @import("names.zig");
const plan = @import("plan.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const pre = names.pre;
const name = names.name;
const typeName = names.typeName;
const num = names.num;

/// App's one allocation: the beans in creation order, the entries of the
/// beans App calls methods of, the status beans may read, and the lifecycle
/// with a watch per entry. Every address in it stays valid until App frees
/// it.
pub fn BlockOf(comptime Root: type) type {
    @setEvalBranchQuota(names.eval_quota);
    const p = plan.planOf(Root);
    var types: [p.beans.len]type = undefined;
    for (p.beans, 0..) |b, i| types[i] = b.T;
    const final = types;
    return struct {
        beans: @Tuple(&final),
        entries: [p.entry_count]contract.Entry,
        status: contract.Status,
        runtime: lifecycle.Runtime,
        watches: [p.entry_count]lifecycle.Watch,
    };
}

/// The values of `App.init`, in the order of `Root.module.values`.
pub fn ValuesOf(comptime Root: type) type {
    _ = plan.planOf(Root); // the errors of the graph come first
    return @Tuple(Root.module.values);
}

/// The tuple `init` got, in the order of `Root.module.values`.
pub fn takeValues(comptime Root: type, comptime V: type, values: anytype) V {
    const map = comptime valueMap(Root, @TypeOf(values));
    var out: V = undefined;
    inline for (map, 0..) |j, i| out[i] = values[j];
    return out;
}

/// For each declared value, the index of the value of type `Given` that
/// matches it by type: `&var` (a `*T`) fits a declared `*const T`.
pub fn valueMap(comptime Root: type, comptime Given: type) [Root.module.values.len]usize {
    @setEvalBranchQuota(names.eval_quota);
    _ = plan.planOf(Root); // the errors of the graph come before those of the values
    const declared = Root.module.values;
    const p = pre(Root) ++ "App.init: ";
    if (!names.isTuple(Given) and !(names.isPlainStruct(Given) and names.fieldsOf(Given).field_names.len == 0))
        @compileError(p ++ "the values must be a tuple of pointers, such as .{ &config, &logger }; got " ++ typeName(Given));
    var map: [declared.len]?usize = @splat(null);
    for (names.fieldsOf(Given).field_types, 0..) |E, j| {
        const e = names.dataPointer(E) orelse @compileError(p ++ "value " ++ num(j) ++ " is a " ++ typeName(E) ++ "; a value is a pointer: pass &x");
        const i = for (declared, 0..) |D, i| {
            if (names.dataPointer(D).?.child == e.child) break i;
        } else @compileError(p ++ "value " ++ num(j) ++ " (" ++ typeName(E) ++ ") is not declared: " ++ name(Root) ++ ".values has " ++ names.typeList(declared) ++
            "; declare it there, or drop it");
        if (map[i]) |prev| @compileError(p ++ "values " ++ num(prev) ++ " and " ++ num(j) ++ " are both " ++ typeName(e.child) ++ "; pass each value once");
        if (e.attrs.@"const" and !names.dataPointer(declared[i]).?.attrs.@"const")
            @compileError(p ++ "value " ++ num(j) ++ " is " ++ typeName(E) ++ ", but " ++ name(Root) ++ ".values declares " ++ typeName(declared[i]) ++ "; pass a pointer to a var");
        map[i] = j;
    }
    var out: [declared.len]usize = undefined;
    for (map, 0..) |m, i| out[i] = m orelse
        @compileError(p ++ name(Root) ++ ".values declares " ++ typeName(declared[i]) ++ ", but App.init got no such value; pass it: .{ ..., &x }");
    return out;
}

/// The function that builds one bean into the block.
pub fn Step(comptime B: type, comptime V: type) type {
    return *const fn (block: *B, gpa: Allocator, io: Io, values: *const V) anyerror!void;
}

/// One step per bean, in creation order.
pub fn stepsOf(comptime Root: type, comptime B: type, comptime V: type) []const Step(B, V) {
    @setEvalBranchQuota(names.eval_quota);
    const n = plan.planOf(Root).beans.len;
    var out: [n]Step(B, V) = undefined;
    // The types go in as params: a generic call in the signature of each
    // of a thousand functions costs seconds of compile time.
    for (0..n) |i| out[i] = Builder(Root, B, V, i).run;
    const final = out;
    return &final;
}

/// For each bean, how many entries the beans before it made: what a
/// failing step leaves to destroy.
pub fn entriesBefore(comptime Root: type) []const usize {
    @setEvalBranchQuota(names.eval_quota);
    const beans = plan.planOf(Root).beans;
    var out: [beans.len]usize = undefined;
    var count: usize = 0;
    for (beans, 0..) |b, i| {
        out[i] = count;
        if (b.entry != null) count += 1;
    }
    const final = out;
    return &final;
}

/// The index of the bean of type T (a type is one bean).
pub fn beanIndex(comptime Root: type, comptime T: type) usize {
    @setEvalBranchQuota(names.eval_quota);
    for (plan.planOf(Root).beans, 0..) |b, i| if (b.T == T) return i;
    @compileError(pre(Root) ++ "get(" ++ typeName(T) ++ "): no bean of type " ++ typeName(T) ++ " in " ++ name(Root) ++
        " (a value of " ++ name(Root) ++ ".values is yours already; an overridden bean is not built)");
}

/// Calls `deinit` of the entries that have one, last first.
pub fn deinitReverse(entries: []contract.Entry, io: Io) void {
    var k = entries.len;
    while (k > 0) {
        k -= 1;
        if (entries[k].vtable.deinit) |deinitFn| deinitFn(entries[k].ptr, io);
    }
}

fn Builder(comptime Root: type, comptime B: type, comptime V: type, comptime i: usize) type {
    return struct {
        fn run(block: *B, gpa: Allocator, io: Io, values: *const V) anyerror!void {
            @setEvalBranchQuota(names.eval_quota);
            const bean = comptime plan.planOf(Root).beans[i];
            const dst = &block.beans[i];
            if (bean.kind == .factory) {
                dst.* = try callWith(bean.T, @field(bean.Holder, bean.fn_name), bean.sources, block, gpa, io, values);
            } else if (comptime names.hasInitFn(bean.T)) {
                dst.* = try callWith(bean.T, bean.T.init, bean.sources, block, gpa, io, values);
            } else {
                fillStruct(bean.T, bean.sources, dst, block, gpa, io, values);
            }
            if (bean.entry) |e| block.entries[e] = .{ .name = bean.label, .ptr = dst, .vtable = comptime contract.vtableOf(bean.T) };
        }
    };
}

inline fn callWith(comptime T: type, comptime func: anytype, comptime sources: []const plan.Source, block: anytype, gpa: Allocator, io: Io, values: anytype) !T {
    const params = @typeInfo(@TypeOf(func)).@"fn".param_types;
    var args: ArgsOf(@TypeOf(func)) = undefined;
    inline for (sources, 0..) |src, k| args[k] = arg(params[k].?, src, block, gpa, io, values);
    const result = @call(.auto, func, args);
    if (comptime @typeInfo(@TypeOf(result)) == .error_union) return try result;
    return result;
}

fn ArgsOf(comptime F: type) type {
    const params = @typeInfo(F).@"fn".param_types;
    var types: [params.len]type = undefined;
    for (params, 0..) |P, k| types[k] = P.?;
    const final = types;
    return @Tuple(&final);
}

inline fn arg(comptime P: type, comptime src: plan.Source, block: anytype, gpa: Allocator, io: Io, values: anytype) P {
    switch (src) {
        .gpa => return gpa,
        .io => return io,
        .status => return &block.status,
        .bean => |r| return if (r.how == .copy) block.beans[r.i] else &block.beans[r.i],
        .value => |r| return if (r.how == .copy) values.*[r.i].* else values.*[r.i],
        .deps => |d| {
            var out: P = undefined;
            fillStruct(P, d.fields, &out, block, gpa, io, values);
            return out;
        },
        .list => |list| {
            var out: P = undefined;
            inline for (list, 0..) |b, k| out[k] = &block.beans[b];
            return out;
        },
        .default => unreachable,
    }
}

inline fn fillStruct(comptime T: type, comptime sources: []const plan.Source, dst: *T, block: anytype, gpa: Allocator, io: Io, values: anytype) void {
    const s = comptime names.fieldsOf(T);
    inline for (s.field_names, s.field_types, s.field_attrs, sources) |field, FT, a, src| {
        if (a.@"comptime") continue;
        @field(dst, field) = if (src == .default) comptime a.defaultValue(FT).? else arg(FT, src, block, gpa, io, values);
    }
}
