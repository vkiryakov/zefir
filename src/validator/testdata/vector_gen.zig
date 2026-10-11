//! vector_gen turns one golden-vector file into a Zig test file:
//!
//!     vector_gen <in.json> <out.zig>
//!
//! build.zig builds it for the host and runs it on every name in
//! `vector_files` of cases.zig; the output lives in the build cache, is never
//! committed, and is compiled against the `validator` and `harness`
//! (vector_harness.zig) modules, one test per record. A file it rejects fails
//! the build with one line per problem on stderr:
//! `vector_gen: <file>: <id>: <problem>`.
//!
//! A vector file is a JSON array of records sorted by `id` (UTF-8, LF,
//! 2-space indent). The fields of a record:
//!
//! - `id` (required): `<rule>-<NNN>`, three digits, unique in the file
//! - `rule` (required): the rule under test, by its public name (`notEmpty`)
//! - `params` (required): the Zig source of the rule's arguments without
//!   the parentheses; `""` for a rule that takes none
//! - `call`: the Zig source of the whole `field_rules` entry when it is
//!   more than `v.<rule>(<params>)`, such as a tuple; written with `v.`
//! - `field_type` (required): the Zig source of the field's type; it may
//!   name the fixtures of vector_harness.zig (`[]const Role`, `?Stock`)
//! - `input` (required): the value, encoded as vector_harness.zig describes
//! - `hex`: the bytes of a string input in lowercase hex, present exactly
//!   when a byte is outside 0x20-0x7E or the bytes are not valid UTF-8;
//!   `input` then shows the bytes as `std.zig.fmtString` does
//! - `bits`: the IEEE bits of a float input in lowercase hex, in the width
//!   of the field type
//! - `expect` (required): `pass`, `fail` (a rule failed) or `precondition`
//!   (a rule's precondition failed)
//! - `code`: the violation's code; required unless `expect` is `pass`
//! - `message`: the violation's exact message, when the record pins it
//! - `path`: the violation's field relative to the DTO field: `""`
//!   (default), `"[1]"`, `"[2].name"`
//! - `mode`: `check` (default) or `checkAll`; a `checkAll` record lists the
//!   whole report in `violations`, `[{ "code": ..., "path": ... }]` in walk
//!   order, the first of which `code` and `path` describe
//! - `reason` (required): one line on why the record exists
//! - `source` (required): where the record comes from
//! - `vjs`: what validator.js returns for the input (`true`/`false`), when measured
//! - `deviation`: the documented deviation (`D<n>`), required when `vjs`
//!   differs from `expect == "pass"`
//!
//! The generator also rejects: unknown fields; a failing record of a single
//! rule (no `call`) whose code is not the rule's own (`validation.` and the
//! rule's name in snake_case; `validation.unique_items` for `uniqueBy`;
//! `each` and `custom` have no code of their own); a precondition code other
//! than `validation.utf8`, `validation.finite`, `validation.date` and
//! `validation.rfc3339`; a rule with fewer than 10 records.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The fixture types and predicates of vector_harness.zig that records may
/// name; the generated file aliases each one (`const Role = h.Role;`) and
/// references them all, so a name the harness lacks fails the build. A new
/// fixture goes into both files.
pub const fixture_names = [_][]const u8{
    "Role",
    "Color",
    "Open",
    "OpenOne",
    "Only",
    "Sparse",
    "Item",
    "Stock",
    "isEven",
    "isEvenPtr",
    "lt100",
    "hasStock",
    "startsWithAt",
    "isNonEmpty",
    "isPositive64",
};

const required_fields = [_][]const u8{ "id", "rule", "params", "field_type", "input", "expect", "reason", "source" };
const optional_fields = [_][]const u8{ "call", "hex", "bits", "code", "message", "path", "mode", "violations", "vjs", "deviation" };
const precondition_codes = [_][]const u8{ "validation.utf8", "validation.finite", "validation.date", "validation.rfc3339" };
const string_types = [_][]const u8{ "[]const u8", "[]u8", "[:0]const u8", "[:0]u8" };
const float_types = [_][]const u8{ "f16", "f32", "f64", "f80", "f128", "c_longdouble" };
/// Every rule of a file needs at least this many records.
const min_records = 10;

/// Why a file is rejected. `where` is the record's id (or `[<index>]` when
/// it has no usable id), a rule's name for the record count, or empty for a
/// problem of the whole file.
const Problem = struct { where: []const u8, text: []const u8 };

const Expect = enum { pass, fail, precondition };
const Mode = enum { check, checkAll };
const ExpectedViolation = struct { code: []const u8, path: []const u8 };

/// A record that passed the checks of its own fields.
const Record = struct {
    id: []const u8,
    rule: []const u8,
    params: []const u8,
    call: ?[]const u8,
    field_type: []const u8,
    input: std.json.Value,
    hex: ?[]const u8,
    bits: ?[]const u8,
    expect: Expect,
    code: ?[]const u8,
    message: ?[]const u8,
    path: ?[]const u8,
    mode: Mode,
    violations: ?[]const ExpectedViolation,
};

const Checked = struct { records: []const Record, problems: []const Problem };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: vector_gen <in.json> <out.zig>\n", .{});
        std.process.exit(2);
    }
    const file_name = std.fs.path.basename(args[1]);
    const cwd = std.Io.Dir.cwd();
    const text = cwd.readFileAlloc(init.io, args[1], arena, .unlimited) catch |err| {
        std.debug.print("vector_gen: {s}: cannot read the file: {s}\n", .{ args[1], @errorName(err) });
        std.process.exit(1);
    };
    const checked = try checkFile(arena, text);
    if (checked.problems.len > 0) {
        for (checked.problems) |problem| {
            if (problem.where.len == 0) {
                std.debug.print("vector_gen: {s}: {s}\n", .{ file_name, problem.text });
            } else {
                std.debug.print("vector_gen: {s}: {s}: {s}\n", .{ file_name, problem.where, problem.text });
            }
        }
        std.process.exit(1);
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeTests(&out.writer, arena, file_name, checked.records);
    try cwd.writeFile(init.io, .{ .sub_path = args[2], .data = out.written() });
}

/// Parses a vector file and checks every record; `problems` is empty when
/// the file is accepted.
fn checkFile(arena: Allocator, text: []const u8) Allocator.Error!Checked {
    var problems: std.ArrayList(Problem) = .empty;
    var records: std.ArrayList(Record) = .empty;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try problems.append(arena, .{ .where = "", .text = try std.fmt.allocPrint(arena, "not valid JSON ({s})", .{@errorName(err)}) });
            return .{ .records = &.{}, .problems = problems.items };
        },
    };
    if (root != .array) {
        try problems.append(arena, .{ .where = "", .text = "the file must be a JSON array of records" });
        return .{ .records = &.{}, .problems = problems.items };
    }
    // The id and rule of every record that has them, malformed or not.
    var keys: std.ArrayList(struct { id: []const u8, rule: []const u8 }) = .empty;
    for (root.array.items, 0..) |value, index| {
        if (try readRecord(arena, &problems, index, value)) |record| try records.append(arena, record);
        if (value != .object) continue;
        const id = value.object.get("id") orelse continue;
        const rule = value.object.get("rule") orelse continue;
        if (id == .string and rule == .string) try keys.append(arena, .{ .id = id.string, .rule = rule.string });
    }
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    var counts: std.StringArrayHashMapUnmanaged(usize) = .empty;
    for (keys.items, 0..) |key, i| {
        if ((try ids.getOrPut(arena, key.id)).found_existing) {
            try problems.append(arena, .{ .where = key.id, .text = "id repeats" });
        } else if (i > 0 and std.mem.order(u8, keys.items[i - 1].id, key.id) == .gt) {
            try problems.append(arena, .{ .where = key.id, .text = try std.fmt.allocPrint(arena, "records must be sorted by id; this one comes after \"{s}\"", .{keys.items[i - 1].id}) });
        }
        const count = try counts.getOrPutValue(arena, key.rule, 0);
        count.value_ptr.* += 1;
    }
    for (counts.keys(), counts.values()) |rule, count| {
        if (count < min_records) {
            try problems.append(arena, .{ .where = rule, .text = try std.fmt.allocPrint(arena, "{d} record{s}; every rule needs at least {d}", .{ count, if (count == 1) "" else "s", min_records }) });
        }
    }
    return .{ .records = records.items, .problems = problems.items };
}

/// Reads the fields of one record and collects its problems.
const FieldReader = struct {
    arena: Allocator,
    problems: *std.ArrayList(Problem),
    where: []const u8,
    object: std.json.ObjectMap,
    ok: bool = true,

    fn problem(r: *FieldReader, comptime format: []const u8, args: anytype) Allocator.Error!void {
        r.ok = false;
        try r.problems.append(r.arena, .{ .where = r.where, .text = try std.fmt.allocPrint(r.arena, format, args) });
    }

    fn string(r: *FieldReader, name: []const u8) Allocator.Error!?[]const u8 {
        const value = r.object.get(name) orelse return null;
        if (value == .string) return value.string;
        try r.problem("field \"{s}\" must be a string", .{name});
        return null;
    }

    fn boolean(r: *FieldReader, name: []const u8) Allocator.Error!?bool {
        const value = r.object.get(name) orelse return null;
        if (value == .bool) return value.bool;
        try r.problem("field \"{s}\" must be true or false", .{name});
        return null;
    }

    fn oneOf(r: *FieldReader, comptime E: type, name: []const u8, default: E) Allocator.Error!E {
        const value = try r.string(name) orelse return default;
        if (std.meta.stringToEnum(E, value)) |e| return e;
        const names = comptime names: {
            var text: []const u8 = "";
            for (@typeInfo(E).@"enum".field_names, 0..) |tag, i| {
                const separator = if (i == 0) "" else if (i + 1 == @typeInfo(E).@"enum".field_names.len) " or " else ", ";
                text = text ++ separator ++ "\"" ++ tag ++ "\"";
            }
            break :names text;
        };
        try r.problem("field \"{s}\" must be " ++ names, .{name});
        return default;
    }

    fn violations(r: *FieldReader) Allocator.Error!?[]const ExpectedViolation {
        const value = r.object.get("violations") orelse return null;
        const shape = "field \"violations\" must be an array of {{\"code\": \"...\", \"path\": \"...\"}}";
        if (value != .array) {
            try r.problem(shape, .{});
            return null;
        }
        const out = try r.arena.alloc(ExpectedViolation, value.array.items.len);
        for (value.array.items, out) |item, *violation| {
            if (item != .object or item.object.count() != 2) {
                try r.problem(shape, .{});
                return null;
            }
            const code = item.object.get("code") orelse .null;
            const path = item.object.get("path") orelse .null;
            if (code != .string or path != .string) {
                try r.problem(shape, .{});
                return null;
            }
            violation.* = .{ .code = code.string, .path = path.string };
        }
        return out;
    }
};

fn readRecord(arena: Allocator, problems: *std.ArrayList(Problem), index: usize, value: std.json.Value) Allocator.Error!?Record {
    const position = try std.fmt.allocPrint(arena, "[{d}]", .{index});
    if (value != .object) {
        try problems.append(arena, .{ .where = position, .text = "a record must be a JSON object" });
        return null;
    }
    const id = value.object.get("id") orelse std.json.Value.null;
    var r: FieldReader = .{ .arena = arena, .problems = problems, .where = if (id == .string) id.string else position, .object = value.object };
    for (value.object.keys()) |key| {
        if (!contains(&required_fields, key) and !contains(&optional_fields, key)) try r.problem("unknown field \"{s}\"", .{key});
    }
    for (required_fields) |name| {
        if (!value.object.contains(name)) try r.problem("missing field \"{s}\"", .{name});
    }
    const record: Record = .{
        .id = try r.string("id") orelse "",
        .rule = try r.string("rule") orelse "",
        .params = try r.string("params") orelse "",
        .call = try r.string("call"),
        .field_type = try r.string("field_type") orelse "",
        .input = value.object.get("input") orelse .null,
        .hex = try r.string("hex"),
        .bits = try r.string("bits"),
        .expect = try r.oneOf(Expect, "expect", .pass),
        .code = try r.string("code"),
        .message = try r.string("message"),
        .path = try r.string("path"),
        .mode = try r.oneOf(Mode, "mode", .check),
        .violations = try r.violations(),
    };
    _ = try r.string("reason");
    _ = try r.string("source");
    _ = try r.string("deviation");
    const vjs = try r.boolean("vjs");
    if (!r.ok) return null;
    try checkRecord(&r, record, vjs);
    return if (r.ok) record else null;
}

/// The rules that tie a record's fields together.
fn checkRecord(r: *FieldReader, record: Record, vjs: ?bool) Allocator.Error!void {
    if (!isId(record.id, record.rule)) try r.problem("id must be \"{s}-NNN\" with three digits", .{record.rule});
    if (record.mode == .checkAll and record.violations == null) try r.problem("a checkAll record needs \"violations\"", .{});
    if (record.mode == .check and record.violations != null) try r.problem("\"violations\" needs \"mode\": \"checkAll\"", .{});
    if (record.expect == .pass) {
        if (record.code != null) try r.problem("a passing record has no code", .{});
    } else if (record.code) |code| {
        if (record.expect == .precondition and !contains(&precondition_codes, code)) {
            try r.problem("a precondition code is one of validation.utf8, validation.finite, validation.date, validation.rfc3339", .{});
        }
        if (record.expect == .fail and record.call == null) {
            if (try ownCode(r.arena, record.rule)) |own| {
                if (!std.mem.eql(u8, code, own)) try r.problem("code must be {s}, the code of {s}; a record that expects another code needs a call", .{ own, record.rule });
            }
        }
    } else try r.problem("a failing record needs a code", .{});
    if (vjs) |result| {
        if (result != (record.expect == .pass) and r.object.get("deviation") == null) {
            try r.problem("vjs disagrees with expect, so the record needs \"deviation\"", .{});
        }
    }
    const field_type = std.mem.trimStart(u8, record.field_type, "?");
    if (record.hex) |hex| {
        if (!isHex(hex) or hex.len % 2 != 0) {
            try r.problem("hex must be lowercase hex digits, two per byte", .{});
        } else if (!contains(&string_types, field_type)) {
            try r.problem("hex is only for string fields", .{});
        } else {
            const bytes = try r.arena.alloc(u8, hex.len / 2);
            _ = std.fmt.hexToBytes(bytes, hex) catch unreachable;
            if (!needsHex(bytes)) {
                try r.problem("hex is only for inputs with bytes outside 0x20-0x7E or invalid UTF-8", .{});
            } else {
                const display = try std.fmt.allocPrint(r.arena, "{f}", .{std.zig.fmtString(bytes)});
                if (record.input != .string or !std.mem.eql(u8, record.input.string, display)) {
                    try r.problem("input must show the hex bytes as std.zig.fmtString does: \"{f}\"", .{std.zig.fmtString(display)});
                }
            }
        }
    } else try checkStrings(r, record.field_type, record.input, "input");
    if (record.bits) |bits| {
        if (!isHex(bits)) {
            try r.problem("bits must be lowercase hex digits", .{});
        } else if (!contains(&float_types, field_type)) {
            try r.problem("bits is only for float fields", .{});
        }
    }
}

/// A string in `value` (the input, or an item of a list of strings) whose
/// bytes need hex: the input must use the record's `hex`, an item must be
/// written `{ "hex": "..." }`.
fn checkStrings(r: *FieldReader, field_type: []const u8, value: std.json.Value, name: []const u8) Allocator.Error!void {
    const T = std.mem.trimStart(u8, field_type, "?");
    if (contains(&string_types, T)) {
        switch (value) {
            .string => |s| if (needsHex(s)) {
                if (std.mem.eql(u8, name, "input")) {
                    try r.problem("the input has bytes outside 0x20-0x7E; add \"hex\"", .{});
                } else {
                    try r.problem("{s} has bytes outside 0x20-0x7E; write it as {{\"hex\": \"...\"}}", .{name});
                }
            },
            .object => |o| {
                const hex = o.get("hex") orelse std.json.Value.null;
                if (std.mem.eql(u8, name, "input") or o.count() != 1 or hex != .string or !isHex(hex.string) or hex.string.len % 2 != 0) {
                    try r.problem("{s} must be a string, or {{\"hex\": \"...\"}} in a list", .{name});
                }
            },
            else => {},
        }
        return;
    }
    const child = listChild(T) orelse return;
    if (value != .array) return;
    for (value.array.items, 0..) |item, i| {
        try checkStrings(r, child, item, try std.fmt.allocPrint(r.arena, "{s}[{d}]", .{ name, i }));
    }
}

/// The item type of a slice or array type: `[]const T`, `[]T`, `[N]T`.
fn listChild(T: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, T, "[]const ")) return T["[]const ".len..];
    if (std.mem.startsWith(u8, T, "[]")) return T["[]".len..];
    if (!std.mem.startsWith(u8, T, "[")) return null;
    const close = std.mem.findScalar(u8, T, ']') orelse return null;
    for (T[1..close]) |c| if (!std.ascii.isDigit(c)) return null;
    if (close == 1) return null;
    return T[close + 1 ..];
}

fn needsHex(bytes: []const u8) bool {
    for (bytes) |c| if (c < 0x20 or c > 0x7e) return true;
    return !std.unicode.utf8ValidateSlice(bytes);
}

fn isHex(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn isId(id: []const u8, rule: []const u8) bool {
    if (rule.len == 0 or id.len != rule.len + 4) return false;
    if (!std.mem.startsWith(u8, id, rule) or id[rule.len] != '-') return false;
    for (id[rule.len + 1 ..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// The code a rule reports for its own check, or null for `each` and
/// `custom`, whose codes come from the rules inside them or from the call.
fn ownCode(arena: Allocator, rule: []const u8) Allocator.Error!?[]const u8 {
    if (std.mem.eql(u8, rule, "each") or std.mem.eql(u8, rule, "custom")) return null;
    if (std.mem.eql(u8, rule, "uniqueBy")) return "validation.unique_items";
    var code: std.ArrayList(u8) = .empty;
    try code.appendSlice(arena, "validation.");
    for (rule) |c| {
        if (std.ascii.isUpper(c)) {
            try code.append(arena, '_');
            try code.append(arena, std.ascii.toLower(c));
        } else try code.append(arena, c);
    }
    return code.items;
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, s)) return true;
    return false;
}

/// Writes the test file of a checked vector file.
fn writeTests(w: *std.Io.Writer, arena: Allocator, file_name: []const u8, records: []const Record) !void {
    try w.print(
        \\//! Generated by src/validator/testdata/vector_gen.zig from {s}, one test
        \\//! per record. Do not edit: change the JSON file and rebuild.
        \\const v = @import("validator");
        \\const h = @import("harness");
        \\
        \\
    , .{file_name});
    for (fixture_names) |name| try w.print("const {s} = h.{s};\n", .{ name, name });
    // Analyzed whether or not a record uses them: a name missing from the
    // harness fails the build at once.
    try w.writeAll("\ncomptime {\n    _ = .{");
    for (fixture_names, 0..) |name, i| try w.print("{s}{s}", .{ if (i == 0) " " else ", ", name });
    try w.writeAll(" };\n}\n");
    for (records) |record| try writeTest(w, arena, record);
}

fn writeTest(w: *std.Io.Writer, arena: Allocator, record: Record) !void {
    try w.print("\ntest \"{f}\" {{\n", .{std.zig.fmtString(record.id)});
    try w.writeAll("    const Dto = struct {\n");
    try w.print("        value: {s},\n", .{record.field_type});
    try w.writeAll("        pub const field_rules = .{ .value = ");
    if (record.call) |call| {
        try w.writeAll(call);
    } else if (record.params.len == 0) {
        try w.print("v.{s}", .{record.rule});
    } else {
        try w.print("v.{s}({s})", .{ record.rule, record.params });
    }
    try w.writeAll(" };\n    };\n    try h.expectRecord(Dto, .{\n");
    try w.print("        .id = \"{f}\",\n", .{std.zig.fmtString(record.id)});
    const input = try std.json.Stringify.valueAlloc(arena, record.input, .{});
    try w.print("        .input = \"{f}\",\n", .{std.zig.fmtString(input)});
    if (record.hex) |hex| try w.print("        .hex = \"{f}\",\n", .{std.zig.fmtString(hex)});
    if (record.bits) |bits| try w.print("        .bits = \"{f}\",\n", .{std.zig.fmtString(bits)});
    try w.print("        .expect = .{s},\n", .{@tagName(record.expect)});
    if (record.code) |code| try w.print("        .code = \"{f}\",\n", .{std.zig.fmtString(code)});
    if (record.message) |message| try w.print("        .message = \"{f}\",\n", .{std.zig.fmtString(message)});
    if (record.path) |path| try w.print("        .path = \"{f}\",\n", .{std.zig.fmtString(path)});
    if (record.mode == .checkAll) try w.writeAll("        .mode = .checkAll,\n");
    if (record.violations) |list| {
        if (list.len == 0) {
            try w.writeAll("        .violations = &.{},\n");
        } else {
            try w.writeAll("        .violations = &.{\n");
            for (list) |item| {
                try w.print("            .{{ .code = \"{f}\", .path = \"{f}\" }},\n", .{ std.zig.fmtString(item.code), std.zig.fmtString(item.path) });
            }
            try w.writeAll("        },\n");
        }
    }
    try w.writeAll("    });\n}\n");
}

/// Fails unless checking `text` reports `problem` at `where`.
fn expectProblem(text: []const u8, where: []const u8, problem: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const checked = try checkFile(arena_state.allocator(), text);
    for (checked.problems) |p| {
        if (std.mem.eql(u8, p.where, where) and std.mem.eql(u8, p.text, problem)) return;
    }
    std.debug.print("expected the problem {s}: {s}\ngot:\n", .{ where, problem });
    for (checked.problems) |p| std.debug.print("  {s}: {s}\n", .{ p.where, p.text });
    return error.TestExpectedProblem;
}

/// Fails if checking `text` reports a problem at `id` (the problem of too
/// few records, reported at the rule's name, is ignored).
fn expectAccepted(text: []const u8, id: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const checked = try checkFile(arena_state.allocator(), text);
    for (checked.problems) |p| {
        if (std.mem.eql(u8, p.where, id)) {
            std.debug.print("unexpected problem {s}: {s}\n", .{ p.where, p.text });
            return error.TestUnexpectedProblem;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), checked.records.len);
}

test "a file that is not a JSON array of records is rejected" {
    try expectProblem("[1,", "", "not valid JSON (UnexpectedEndOfInput)");
    try expectProblem("{}", "", "the file must be a JSON array of records");
    try expectProblem("[1]", "[0]", "a record must be a JSON object");
}

test "a record with a missing, unknown or mistyped field is rejected" {
    try expectProblem(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "field_type": "u8", "input": "0",
        \\  "expect": "fail", "code": "validation.positive", "reason": "r", "source": "s", "colour": "red"}]
    , "positive-001", "unknown field \"colour\"");
    try expectProblem(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "field_type": "u8", "input": "0",
        \\  "expect": "fail", "code": "validation.positive", "source": "s"}]
    , "positive-001", "missing field \"reason\"");
    try expectProblem(
        \\[{"rule": "positive", "params": "", "field_type": "u8", "input": "0",
        \\  "expect": "fail", "code": "validation.positive", "reason": "r", "source": "s"}]
    , "[0]", "missing field \"id\"");
    try expectProblem(
        \\[{"id": "positive-001", "rule": "positive", "params": 3, "field_type": "u8", "input": "0",
        \\  "expect": "fail", "code": "validation.positive", "reason": "r", "source": "s"}]
    , "positive-001", "field \"params\" must be a string");
    try expectProblem(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "field_type": "u8", "input": "0",
        \\  "expect": "fail", "code": "validation.positive", "reason": "r", "source": "s", "vjs": "no"}]
    , "positive-001", "field \"vjs\" must be true or false");
    try expectProblem(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "field_type": "u8", "input": "0",
        \\  "expect": "maybe", "code": "validation.positive", "reason": "r", "source": "s"}]
    , "positive-001", "field \"expect\" must be \"pass\", \"fail\" or \"precondition\"");
    try expectProblem(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "field_type": "u8", "input": "0",
        \\  "expect": "fail", "code": "validation.positive", "reason": "r", "source": "s", "mode": "all"}]
    , "positive-001", "field \"mode\" must be \"check\" or \"checkAll\"");
    try expectProblem(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "field_type": "u8", "input": "0",
        \\  "expect": "fail", "code": "validation.positive", "reason": "r", "source": "s",
        \\  "mode": "checkAll", "violations": [{"code": "validation.positive"}]}]
    , "positive-001", "field \"violations\" must be an array of {\"code\": \"...\", \"path\": \"...\"}");
}

test "an id that is not <rule>-NNN is rejected, and so is a repeated or unsorted one" {
    try expectProblem(
        \\[{"id": "positive-1", "rule": "positive", "params": "", "field_type": "u8", "input": "0",
        \\  "expect": "fail", "code": "validation.positive", "reason": "r", "source": "s"}]
    , "positive-1", "id must be \"positive-NNN\" with three digits");
    try expectProblem(
        \\[{"id": "negative-001", "rule": "positive", "params": "", "field_type": "u8", "input": "0",
        \\  "expect": "fail", "code": "validation.positive", "reason": "r", "source": "s"}]
    , "negative-001", "id must be \"positive-NNN\" with three digits");
    try expectProblem(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "field_type": "u8", "input": "0",
        \\  "expect": "fail", "code": "validation.positive", "reason": "r", "source": "s"},
        \\ {"id": "positive-001", "rule": "positive", "params": "", "field_type": "u8", "input": "1",
        \\  "expect": "pass", "reason": "r", "source": "s"}]
    , "positive-001", "id repeats");
    try expectProblem(
        \\[{"id": "positive-002", "rule": "positive", "params": "", "field_type": "u8", "input": "1",
        \\  "expect": "pass", "reason": "r", "source": "s"},
        \\ {"id": "positive-001", "rule": "positive", "params": "", "field_type": "u8", "input": "0",
        \\  "expect": "fail", "code": "validation.positive", "reason": "r", "source": "s"}]
    , "positive-001", "records must be sorted by id; this one comes after \"positive-002\"");
}

test "codes must fit expect, the rule and the preconditions" {
    try expectProblem(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "field_type": "u8", "input": "1",
        \\  "expect": "pass", "code": "validation.positive", "reason": "r", "source": "s"}]
    , "positive-001", "a passing record has no code");
    try expectProblem(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "field_type": "u8", "input": "0",
        \\  "expect": "fail", "reason": "r", "source": "s"}]
    , "positive-001", "a failing record needs a code");
    try expectProblem(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "field_type": "u8", "input": "0",
        \\  "expect": "fail", "code": "validation.negative", "reason": "r", "source": "s"}]
    , "positive-001", "code must be validation.positive, the code of positive; a record that expects another code needs a call");
    try expectProblem(
        \\[{"id": "notEmpty-001", "rule": "notEmpty", "params": "", "field_type": "[]const u8", "input": "",
        \\  "expect": "fail", "code": "validation.notempty", "reason": "r", "source": "s"}]
    , "notEmpty-001", "code must be validation.not_empty, the code of notEmpty; a record that expects another code needs a call");
    try expectProblem(
        \\[{"id": "uniqueBy-001", "rule": "uniqueBy", "params": ".id", "field_type": "[]const Item", "input": [],
        \\  "expect": "fail", "code": "validation.unique_by", "reason": "r", "source": "s"}]
    , "uniqueBy-001", "code must be validation.unique_items, the code of uniqueBy; a record that expects another code needs a call");
    try expectProblem(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "field_type": "f64", "input": "nan",
        \\  "expect": "precondition", "code": "validation.positive", "reason": "r", "source": "s"}]
    , "positive-001", "a precondition code is one of validation.utf8, validation.finite, validation.date, validation.rfc3339");
    try expectProblem(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "field_type": "u8", "input": "0",
        \\  "expect": "fail", "code": "validation.positive", "reason": "r", "source": "s", "vjs": true}]
    , "positive-001", "vjs disagrees with expect, so the record needs \"deviation\"");
    try expectProblem(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "field_type": "u8", "input": "0",
        \\  "expect": "fail", "code": "validation.positive", "reason": "r", "source": "s", "mode": "checkAll"}]
    , "positive-001", "a checkAll record needs \"violations\"");
    try expectProblem(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "field_type": "u8", "input": "0",
        \\  "expect": "fail", "code": "validation.positive", "reason": "r", "source": "s", "violations": []}]
    , "positive-001", "\"violations\" needs \"mode\": \"checkAll\"");
}

test "strings that need hex must have it, and hex and bits must be well-formed" {
    try expectProblem(
        \\[{"id": "notEmpty-001", "rule": "notEmpty", "params": "", "field_type": "[]const u8", "input": "a\tb",
        \\  "expect": "pass", "reason": "r", "source": "s"}]
    , "notEmpty-001", "the input has bytes outside 0x20-0x7E; add \"hex\"");
    try expectProblem(
        \\[{"id": "each-001", "rule": "each", "params": "v.notEmpty", "field_type": "[]const ?[]const u8",
        \\  "input": ["a", "\n"], "expect": "pass", "reason": "r", "source": "s"}]
    , "each-001", "input[1] has bytes outside 0x20-0x7E; write it as {\"hex\": \"...\"}");
    try expectProblem(
        \\[{"id": "each-001", "rule": "each", "params": "v.notEmpty", "field_type": "[2][]const u8",
        \\  "input": ["a", {"hex": "f"}], "expect": "pass", "reason": "r", "source": "s"}]
    , "each-001", "input[1] must be a string, or {\"hex\": \"...\"} in a list");
    try expectProblem(
        \\[{"id": "notEmpty-001", "rule": "notEmpty", "params": "", "field_type": "[]const u8", "input": "\\xff",
        \\  "hex": "FF", "expect": "pass", "reason": "r", "source": "s"}]
    , "notEmpty-001", "hex must be lowercase hex digits, two per byte");
    try expectProblem(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "field_type": "u8", "input": "1",
        \\  "hex": "ff", "expect": "pass", "reason": "r", "source": "s"}]
    , "positive-001", "hex is only for string fields");
    try expectProblem(
        \\[{"id": "notEmpty-001", "rule": "notEmpty", "params": "", "field_type": "[]const u8", "input": "a",
        \\  "hex": "61", "expect": "pass", "reason": "r", "source": "s"}]
    , "notEmpty-001", "hex is only for inputs with bytes outside 0x20-0x7E or invalid UTF-8");
    try expectProblem(
        \\[{"id": "notEmpty-001", "rule": "notEmpty", "params": "", "field_type": "[]const u8", "input": "ff",
        \\  "hex": "ff", "expect": "pass", "reason": "r", "source": "s"}]
    , "notEmpty-001", "input must show the hex bytes as std.zig.fmtString does: \"\\\\xff\"");
    try expectProblem(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "field_type": "f32", "input": "0.1",
        \\  "bits": "3DCCCCCD", "expect": "pass", "reason": "r", "source": "s"}]
    , "positive-001", "bits must be lowercase hex digits");
    try expectProblem(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "field_type": "u32", "input": "1",
        \\  "bits": "00000001", "expect": "pass", "reason": "r", "source": "s"}]
    , "positive-001", "bits is only for float fields");
}

test "a rule with fewer than 10 records is rejected" {
    try expectProblem(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "field_type": "u8", "input": "0",
        \\  "expect": "fail", "code": "validation.positive", "reason": "r", "source": "s"}]
    , "positive", "1 record; every rule needs at least 10");
}

test "records the checks must accept" {
    // each and custom have no code of their own; a call may expect any code.
    try expectAccepted(
        \\[{"id": "each-001", "rule": "each", "params": "v.positive", "field_type": "[]const u32", "input": ["1", "0"],
        \\  "expect": "fail", "code": "validation.positive", "path": "[1]", "reason": "r", "source": "s"}]
    , "each-001");
    try expectAccepted(
        \\[{"id": "custom-001", "rule": "custom", "params": "\"numbers.even\", \"must be even\", isEven",
        \\  "field_type": "u32", "input": "3", "expect": "fail", "code": "numbers.even", "reason": "r", "source": "s"}]
    , "custom-001");
    try expectAccepted(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "call": ".{ v.custom(\"a.b\", \"c\", isEven), v.positive }",
        \\  "field_type": "u32", "input": "3", "expect": "fail", "code": "a.b", "reason": "r", "source": "s"}]
    , "positive-001");
    try expectAccepted(
        \\[{"id": "base64Url-001", "rule": "base64Url", "params": "", "field_type": "[]const u8", "input": "a",
        \\  "expect": "fail", "code": "validation.base64_url", "reason": "r", "source": "s"}]
    , "base64Url-001");
    // a precondition, checkAll, a measured deviation, hex, bits, a hex item, null
    try expectAccepted(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "field_type": "?f64", "input": "nan",
        \\  "bits": "7ff8000000000000", "expect": "precondition", "code": "validation.finite", "reason": "r", "source": "s"}]
    , "positive-001");
    try expectAccepted(
        \\[{"id": "each-001", "rule": "each", "params": "v.positive", "field_type": "[]const u32", "input": ["0", "0"],
        \\  "expect": "fail", "code": "validation.positive", "path": "[0]", "mode": "checkAll",
        \\  "violations": [{"code": "validation.positive", "path": "[0]"}, {"code": "validation.positive", "path": "[1]"}],
        \\  "reason": "r", "source": "s"}]
    , "each-001");
    try expectAccepted(
        \\[{"id": "positive-001", "rule": "positive", "params": "", "field_type": "f64", "input": "inf",
        \\  "expect": "precondition", "code": "validation.finite", "reason": "r", "source": "s", "vjs": true, "deviation": "D16"}]
    , "positive-001");
    try expectAccepted(
        \\[{"id": "notEmpty-001", "rule": "notEmpty", "params": "", "field_type": "?[:0]const u8", "input": "a\\xffb",
        \\  "hex": "61ff62", "expect": "pass", "reason": "r", "source": "s"}]
    , "notEmpty-001");
    try expectAccepted(
        \\[{"id": "each-001", "rule": "each", "params": "v.notEmpty", "field_type": "[]const []const u8",
        \\  "input": ["a", {"hex": "ff"}, ""], "expect": "fail", "code": "validation.not_empty", "path": "[2]",
        \\  "reason": "r", "source": "s"}]
    , "each-001");
    try expectAccepted(
        \\[{"id": "notEmpty-001", "rule": "notEmpty", "params": "", "field_type": "?[]const u8", "input": null,
        \\  "expect": "pass", "reason": "r", "source": "s"}]
    , "notEmpty-001");
}

test "a file of well-formed records is accepted" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const checked = try checkFile(arena_state.allocator(),
        \\[
        \\  {"id": "positive-001", "rule": "positive", "params": "", "field_type": "u8", "input": "0", "expect": "fail", "code": "validation.positive", "reason": "r", "source": "s"},
        \\  {"id": "positive-002", "rule": "positive", "params": "", "field_type": "u8", "input": "1", "expect": "pass", "reason": "r", "source": "s"},
        \\  {"id": "positive-003", "rule": "positive", "params": "", "field_type": "i8", "input": "-128", "expect": "fail", "code": "validation.positive", "reason": "r", "source": "s"},
        \\  {"id": "positive-004", "rule": "positive", "params": "", "field_type": "i8", "input": "127", "expect": "pass", "reason": "r", "source": "s"},
        \\  {"id": "positive-005", "rule": "positive", "params": "", "field_type": "f64", "input": "-0", "expect": "fail", "code": "validation.positive", "reason": "r", "source": "s"},
        \\  {"id": "positive-006", "rule": "positive", "params": "", "field_type": "f64", "input": "5e-324", "bits": "0000000000000001", "expect": "pass", "reason": "r", "source": "s"},
        \\  {"id": "positive-007", "rule": "positive", "params": "", "field_type": "f64", "input": "nan", "expect": "precondition", "code": "validation.finite", "reason": "r", "source": "s"},
        \\  {"id": "positive-008", "rule": "positive", "params": "", "field_type": "?u8", "input": null, "expect": "pass", "reason": "r", "source": "s"},
        \\  {"id": "positive-009", "rule": "positive", "params": "", "field_type": "u64", "input": "18446744073709551615", "expect": "pass", "reason": "r", "source": "s"},
        \\  {"id": "positive-010", "rule": "positive", "params": "", "field_type": "??f64", "input": "0", "expect": "fail", "code": "validation.positive", "reason": "r", "source": "s"}
        \\]
    );
    try std.testing.expectEqual(@as(usize, 0), checked.problems.len);
    try std.testing.expectEqual(@as(usize, 10), checked.records.len);
}

test "the generated file aliases the fixtures and has one test per record" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const checked = try checkFile(arena,
        \\[
        \\  {"id": "each-001", "rule": "each", "params": "v.notEmpty", "field_type": "[]const []const u8",
        \\   "input": ["a", ""], "expect": "fail", "code": "validation.not_empty", "message": "must not be empty",
        \\   "path": "[1]", "reason": "r", "source": "s"},
        \\  {"id": "each-002", "rule": "each", "params": "v.positive", "call": ".{ v.notEmpty, v.each(v.positive) }",
        \\   "field_type": "[]const ?f32", "input": [null, "0.1", "0"], "expect": "fail", "code": "validation.positive",
        \\   "path": "[2]", "mode": "checkAll", "violations": [{"code": "validation.positive", "path": "[2]"}],
        \\   "reason": "r", "source": "s"},
        \\  {"id": "notEmpty-001", "rule": "notEmpty", "params": "", "field_type": "[]const u8", "input": "\\x00",
        \\   "hex": "00", "expect": "pass", "reason": "r", "source": "s"},
        \\  {"id": "positive-001", "rule": "positive", "params": "", "field_type": "f32", "input": "1e-45",
        \\   "bits": "00000001", "expect": "pass", "reason": "r", "source": "s"}
        \\]
    );
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeTests(&out.writer, arena, "lists.json", checked.records);
    try std.testing.expectEqualStrings(
        \\//! Generated by src/validator/testdata/vector_gen.zig from lists.json, one test
        \\//! per record. Do not edit: change the JSON file and rebuild.
        \\const v = @import("validator");
        \\const h = @import("harness");
        \\
        \\const Role = h.Role;
        \\const Color = h.Color;
        \\const Open = h.Open;
        \\const OpenOne = h.OpenOne;
        \\const Only = h.Only;
        \\const Sparse = h.Sparse;
        \\const Item = h.Item;
        \\const Stock = h.Stock;
        \\const isEven = h.isEven;
        \\const isEvenPtr = h.isEvenPtr;
        \\const lt100 = h.lt100;
        \\const hasStock = h.hasStock;
        \\const startsWithAt = h.startsWithAt;
        \\const isNonEmpty = h.isNonEmpty;
        \\const isPositive64 = h.isPositive64;
        \\
        \\comptime {
        \\    _ = .{ Role, Color, Open, OpenOne, Only, Sparse, Item, Stock, isEven, isEvenPtr, lt100, hasStock, startsWithAt, isNonEmpty, isPositive64 };
        \\}
        \\
        \\test "each-001" {
        \\    const Dto = struct {
        \\        value: []const []const u8,
        \\        pub const field_rules = .{ .value = v.each(v.notEmpty) };
        \\    };
        \\    try h.expectRecord(Dto, .{
        \\        .id = "each-001",
        \\        .input = "[\"a\",\"\"]",
        \\        .expect = .fail,
        \\        .code = "validation.not_empty",
        \\        .message = "must not be empty",
        \\        .path = "[1]",
        \\    });
        \\}
        \\
        \\test "each-002" {
        \\    const Dto = struct {
        \\        value: []const ?f32,
        \\        pub const field_rules = .{ .value = .{ v.notEmpty, v.each(v.positive) } };
        \\    };
        \\    try h.expectRecord(Dto, .{
        \\        .id = "each-002",
        \\        .input = "[null,\"0.1\",\"0\"]",
        \\        .expect = .fail,
        \\        .code = "validation.positive",
        \\        .path = "[2]",
        \\        .mode = .checkAll,
        \\        .violations = &.{
        \\            .{ .code = "validation.positive", .path = "[2]" },
        \\        },
        \\    });
        \\}
        \\
        \\test "notEmpty-001" {
        \\    const Dto = struct {
        \\        value: []const u8,
        \\        pub const field_rules = .{ .value = v.notEmpty };
        \\    };
        \\    try h.expectRecord(Dto, .{
        \\        .id = "notEmpty-001",
        \\        .input = "\"\\\\x00\"",
        \\        .hex = "00",
        \\        .expect = .pass,
        \\    });
        \\}
        \\
        \\test "positive-001" {
        \\    const Dto = struct {
        \\        value: f32,
        \\        pub const field_rules = .{ .value = v.positive };
        \\    };
        \\    try h.expectRecord(Dto, .{
        \\        .id = "positive-001",
        \\        .input = "\"1e-45\"",
        \\        .bits = "00000001",
        \\        .expect = .pass,
        \\    });
        \\}
        \\
    , out.written());
}
