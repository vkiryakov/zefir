//! The schemas of types: each row of the codec's table, read and written,
//! the names of the schemas, the rules of the fields and the examples. The
//! expected JSON is written compact; the document writes the same values
//! laid out.
const std = @import("std");
const http = @import("http");
const v = @import("validator");
const json = @import("../json.zig");
const schema = @import("../schema.zig");
const Doc = @import("../root.zig").Doc;

const testing = std.testing;

/// `node` as compact JSON.
fn compact(node: json.Node, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (node) {
        .object => |members| {
            try w.writeByte('{');
            for (members, 0..) |m, i| {
                if (i > 0) try w.writeByte(',');
                try std.json.Stringify.encodeJsonString(m.key, .{}, w);
                try w.writeByte(':');
                try compact(m.value, w);
            }
            try w.writeByte('}');
        },
        .array => |items| {
            try w.writeByte('[');
            for (items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try compact(item, w);
            }
            try w.writeByte(']');
        },
        .string => |s| try std.json.Stringify.encodeJsonString(s, .{}, w),
        .raw => |text| try w.writeAll(text),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .null => try w.writeAll("null"),
    }
}

fn expectJson(expected: []const u8, node: json.Node) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try compact(node, &out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

/// A registry of `uses`, finished, on a server whose bodies refuse unknown
/// keys.
fn registryOf(comptime uses: []const schema.Use) schema.Registry {
    var r: schema.Registry = .init(.reject);
    for (uses) |u| r.use(u);
    r.finish();
    return r;
}

/// The schema of `T` where it is used `direction`.
fn schemaOf(comptime T: type, comptime direction: schema.Direction) json.Node {
    comptime {
        const r = registryOf(&.{.{ .T = T, .direction = direction }});
        return r.schema(.{ .T = T, .direction = direction });
    }
}

/// The schemas of `components` for `uses`.
fn componentsOf(comptime uses: []const schema.Use) json.Node {
    comptime {
        const r = registryOf(uses);
        return r.components();
    }
}

/// The schema `name` of `components` for `uses`.
fn componentOf(comptime uses: []const schema.Use, comptime name: []const u8) json.Node {
    comptime {
        return json.get(componentsOf(uses).object, name) orelse @compileError("no schema " ++ name);
    }
}

fn input(comptime T: type) schema.Use {
    return .{ .T = T, .direction = .input };
}

fn output(comptime T: type) schema.Use {
    return .{ .T = T, .direction = .output };
}

// Application code of the tests: the DTOs.

const Priority = enum { low, normal, high };

const Line = struct {
    display_name: []const u8,
    pub const field_rules = .{ .display_name = v.rename("displayName") };
};

/// A field of each kind of the table of the codec.
const Every = struct {
    title: []const u8,
    page: u32 = 1,
    note: ?[]const u8,
    level: ?u8 = null,
    priority: Priority = .normal,
    ratio: f64,
    done: bool,
    tags: []const []const u8 = &.{},
    lines: []const Line = &.{},
    owner: ?Line = null,
    comptime version: u32 = 1,
    nothing: void = {},
};

test "integers: format from the registry of OpenAPI, bounds up to 32 bits, minimum 0 beyond when unsigned" {
    try expectJson("{\"type\":\"integer\",\"format\":\"uint8\",\"minimum\":0,\"maximum\":255}", comptime schemaOf(u8, .input));
    try expectJson("{\"type\":\"integer\",\"format\":\"int8\",\"minimum\":-128,\"maximum\":127}", comptime schemaOf(i8, .output));
    try expectJson("{\"type\":\"integer\",\"format\":\"uint16\",\"minimum\":0,\"maximum\":65535}", comptime schemaOf(u16, .input));
    try expectJson("{\"type\":\"integer\",\"format\":\"int16\",\"minimum\":-32768,\"maximum\":32767}", comptime schemaOf(i16, .input));
    try expectJson("{\"type\":\"integer\",\"format\":\"uint32\",\"minimum\":0,\"maximum\":4294967295}", comptime schemaOf(u32, .output));
    try expectJson("{\"type\":\"integer\",\"format\":\"int32\",\"minimum\":-2147483648,\"maximum\":2147483647}", comptime schemaOf(i32, .input));
    try expectJson("{\"type\":\"integer\",\"format\":\"uint64\",\"minimum\":0}", comptime schemaOf(u64, .input));
    try expectJson("{\"type\":\"integer\",\"format\":\"int64\"}", comptime schemaOf(i64, .output));
    // Other widths have no format; usize and isize, whose width is the
    // target's, none either.
    try expectJson("{\"type\":\"integer\",\"minimum\":0,\"maximum\":1}", comptime schemaOf(u1, .input));
    try expectJson("{\"type\":\"integer\",\"minimum\":-4,\"maximum\":3}", comptime schemaOf(i3, .input));
    try expectJson("{\"type\":\"integer\",\"minimum\":0}", comptime schemaOf(u48, .input));
    try expectJson("{\"type\":\"integer\"}", comptime schemaOf(i128, .output));
    try expectJson("{\"type\":\"integer\",\"minimum\":0}", comptime schemaOf(usize, .input));
    try expectJson("{\"type\":\"integer\"}", comptime schemaOf(isize, .input));
}

test "floats, bool and strings" {
    try expectJson("{\"type\":\"number\",\"format\":\"float\"}", comptime schemaOf(f32, .input));
    try expectJson("{\"type\":\"number\",\"format\":\"double\"}", comptime schemaOf(f64, .output));
    try expectJson("{\"type\":\"number\"}", comptime schemaOf(f16, .output));
    try expectJson("{\"type\":\"boolean\"}", comptime schemaOf(bool, .input));
    try expectJson("{\"type\":\"string\"}", comptime schemaOf([]const u8, .input));
    try expectJson("{\"type\":\"string\"}", comptime schemaOf([:0]const u8, .output));
    // An array of bytes is written as a string, of up to its length.
    try expectJson("{\"type\":\"string\",\"maxLength\":8}", comptime schemaOf([8]u8, .output));
}

test "lists, arrays and tuples" {
    try expectJson("{\"type\":\"array\",\"items\":{\"type\":\"boolean\"}}", comptime schemaOf([]const bool, .input));
    try expectJson("{\"type\":\"array\",\"items\":{\"type\":[\"integer\",\"null\"],\"format\":\"int32\",\"minimum\":-2147483648,\"maximum\":2147483647}}", comptime schemaOf([]const ?i32, .output));
    try expectJson("{\"type\":\"array\",\"minItems\":3,\"maxItems\":3,\"items\":{\"type\":\"number\",\"format\":\"double\"}}", comptime schemaOf([3]f64, .output));
    try expectJson("{\"type\":\"array\",\"prefixItems\":[{\"type\":\"string\"},{\"type\":\"boolean\"}],\"minItems\":2,\"maxItems\":2}", comptime schemaOf(struct { []const u8, bool }, .output));
}

test "enums: their names; one without a name for every value is written as an integer too" {
    try expectJson("{\"$ref\":\"#/components/schemas/Priority\"}", comptime schemaOf(Priority, .input));
    try expectJson("{\"type\":\"string\",\"enum\":[\"low\",\"normal\",\"high\"]}", comptime componentOf(&.{input(Priority)}, "Priority"));
    const Open = enum(u8) { a, b, _ };
    try expectJson("{\"type\":\"string\",\"enum\":[\"a\",\"b\"]}", comptime componentOf(&.{input(Open)}, "Open"));
    try expectJson("{\"anyOf\":[{\"type\":\"string\",\"enum\":[\"a\",\"b\"]},{\"type\":\"integer\"}]}", comptime componentOf(&.{output(Open)}, "Open"));
}

test "a struct read: required what has no default and is not ?T, defaults, unknown keys refused, no comptime field" {
    try expectJson("{\"type\":\"object\",\"required\":[\"title\",\"ratio\",\"done\"],\"properties\":{" ++
        "\"title\":{\"type\":\"string\"}," ++
        "\"page\":{\"type\":\"integer\",\"format\":\"uint32\",\"minimum\":0,\"maximum\":4294967295,\"default\":1}," ++
        "\"note\":{\"type\":[\"string\",\"null\"]}," ++
        "\"level\":{\"type\":[\"integer\",\"null\"],\"format\":\"uint8\",\"minimum\":0,\"maximum\":255,\"default\":null}," ++
        "\"priority\":{\"$ref\":\"#/components/schemas/Priority\",\"default\":\"normal\"}," ++
        "\"ratio\":{\"type\":\"number\",\"format\":\"double\"}," ++
        "\"done\":{\"type\":\"boolean\"}," ++
        "\"tags\":{\"type\":\"array\",\"default\":[],\"items\":{\"type\":\"string\"}}," ++
        "\"lines\":{\"type\":\"array\",\"default\":[],\"items\":{\"$ref\":\"#/components/schemas/Line\"}}," ++
        "\"owner\":{\"oneOf\":[{\"$ref\":\"#/components/schemas/Line\"},{\"type\":\"null\"}],\"default\":null}" ++
        "},\"additionalProperties\":false}", comptime componentOf(&.{input(Every)}, "Every"));
    // The nested struct, by the outside names of its fields.
    try expectJson("{\"type\":\"object\",\"required\":[\"displayName\"],\"properties\":{\"displayName\":{\"type\":\"string\"}},\"additionalProperties\":false}", comptime componentOf(&.{input(Every)}, "Line"));
}

test "a struct written: every field required, null included, the comptime field as a constant, no void field" {
    try expectJson("{\"type\":\"object\",\"required\":[\"title\",\"page\",\"note\",\"level\",\"priority\",\"ratio\",\"done\",\"tags\",\"lines\",\"owner\",\"version\"],\"properties\":{" ++
        "\"title\":{\"type\":\"string\"}," ++
        "\"page\":{\"type\":\"integer\",\"format\":\"uint32\",\"minimum\":0,\"maximum\":4294967295}," ++
        "\"note\":{\"type\":[\"string\",\"null\"]}," ++
        "\"level\":{\"type\":[\"integer\",\"null\"],\"format\":\"uint8\",\"minimum\":0,\"maximum\":255}," ++
        "\"priority\":{\"$ref\":\"#/components/schemas/Priority\"}," ++
        "\"ratio\":{\"type\":\"number\",\"format\":\"double\"}," ++
        "\"done\":{\"type\":\"boolean\"}," ++
        "\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}," ++
        "\"lines\":{\"type\":\"array\",\"items\":{\"$ref\":\"#/components/schemas/Line\"}}," ++
        "\"owner\":{\"oneOf\":[{\"$ref\":\"#/components/schemas/Line\"},{\"type\":\"null\"}]}," ++
        "\"version\":{\"type\":\"integer\",\"format\":\"uint32\",\"const\":1,\"minimum\":0,\"maximum\":4294967295}" ++
        "}}", comptime componentOf(&.{output(Every)}, "Every"));
}

test "a struct whose unknown keys the server ignores has no additionalProperties; its own policy wins over the server's" {
    const Loose = struct {
        a: u8,
        pub const unknown_fields = .ignore;
    };
    try expectJson("{\"type\":\"object\",\"required\":[\"a\"],\"properties\":{\"a\":{\"type\":\"integer\",\"format\":\"uint8\",\"minimum\":0,\"maximum\":255}}}", comptime componentOf(&.{input(Loose)}, "Loose"));
    const Strict = struct {
        b: bool,
        pub const unknown_fields: http.UnknownFields = .reject;
    };
    const ignoring = comptime blk: {
        var r: schema.Registry = .init(.ignore);
        r.use(input(Strict));
        r.use(input(Line));
        r.finish();
        break :blk r.components();
    };
    try expectJson("{\"type\":\"object\",\"required\":[\"b\"],\"properties\":{\"b\":{\"type\":\"boolean\"}},\"additionalProperties\":false}", comptime json.get(ignoring.object, "Strict").?);
    try expectJson("{\"type\":\"object\",\"required\":[\"displayName\"],\"properties\":{\"displayName\":{\"type\":\"string\"}}}", comptime json.get(ignoring.object, "Line").?);
}

test "the body of an http.Problem: a null field is left out, so not required and never null" {
    try expectJson("{\"$ref\":\"#/components/schemas/Problem\"}", comptime blk: {
        const r = registryOf(&.{.{ .T = http.Problem, .direction = .output, .problem = true }});
        break :blk r.schema(.{ .T = http.Problem, .direction = .output, .problem = true });
    });
    const problem: schema.Use = .{ .T = http.Problem, .direction = .output, .problem = true };
    try expectJson("{\"type\":\"object\",\"required\":[\"type\",\"title\",\"status\",\"code\",\"errors\"],\"properties\":{" ++
        "\"type\":{\"type\":\"string\"}," ++
        "\"title\":{\"type\":\"string\"}," ++
        "\"status\":{\"type\":\"integer\",\"format\":\"uint16\",\"minimum\":0,\"maximum\":65535}," ++
        "\"detail\":{\"type\":\"string\"}," ++
        "\"instance\":{\"type\":\"string\"}," ++
        "\"code\":{\"type\":\"string\"}," ++
        "\"errors\":{\"type\":\"array\",\"items\":{\"$ref\":\"#/components/schemas/Violation\"}}" ++
        "}}", comptime componentOf(&.{problem}, "Problem"));
    try expectJson("{\"type\":\"object\",\"required\":[\"code\",\"message\"],\"properties\":{\"code\":{\"type\":\"string\"},\"message\":{\"type\":\"string\"},\"field\":{\"type\":\"string\"}}}", comptime componentOf(&.{problem}, "Violation"));
    // Written inside a problem and outside one: one schema both fit.
    try expectJson("{\"type\":\"object\",\"required\":[\"code\",\"message\"],\"properties\":{\"code\":{\"type\":\"string\"},\"message\":{\"type\":\"string\"},\"field\":{\"type\":[\"string\",\"null\"]}}}", comptime componentOf(&.{ problem, output(v.Violation) }, "Violation"));
}

const Circle = struct {
    radius_mm: u32,
    pub const field_rules = .{ .radius_mm = v.rename("radiusMm") };
};
const Shape = union(enum) {
    circle: Circle,
    label: ?[]const u8,
    none,
};

test "a union written: oneOf objects of one key, the active variant; void is an empty object" {
    try expectJson("{\"oneOf\":[" ++
        "{\"type\":\"object\",\"required\":[\"circle\"],\"properties\":{\"circle\":{\"$ref\":\"#/components/schemas/Circle\"}},\"additionalProperties\":false}," ++
        "{\"type\":\"object\",\"required\":[\"label\"],\"properties\":{\"label\":{\"type\":[\"string\",\"null\"]}},\"additionalProperties\":false}," ++
        "{\"type\":\"object\",\"required\":[\"none\"],\"properties\":{\"none\":{\"type\":\"object\",\"maxProperties\":0}},\"additionalProperties\":false}" ++
        "]}", comptime componentOf(&.{output(Shape)}, "Shape"));
    try expectJson("{\"oneOf\":[{\"$ref\":\"#/components/schemas/Shape\"},{\"type\":\"null\"}]}", comptime schemaOf(?Shape, .output));
}

/// Writes itself as a string of its amount.
const Money = struct {
    cents: u64,
    pub fn jsonStringify(self: Money, w: anytype) !void {
        try w.print("\"{d}\"", .{self.cents});
    }
    pub const openapi: Doc(@This()) = .{ .description = "An amount, in cents, as a string.", .as = []const u8 };
};

const Order = struct {
    total: Money,
    meta: std.json.Value,
};

test "a type that writes itself has the schema of its .as when written; std.json.Value is any JSON" {
    try expectJson("{\"type\":\"string\",\"description\":\"An amount, in cents, as a string.\"}", comptime componentOf(&.{output(Order)}, "Money"));
    try expectJson("{\"type\":\"object\",\"required\":[\"total\",\"meta\"],\"properties\":{\"total\":{\"$ref\":\"#/components/schemas/Money\"},\"meta\":{}}}", comptime componentOf(&.{output(Order)}, "Order"));
    // Read, it is the struct it is: its fields.
    try expectJson("{\"type\":\"object\",\"description\":\"An amount, in cents, as a string.\",\"required\":[\"cents\"],\"properties\":{\"cents\":{\"type\":\"integer\",\"format\":\"uint64\",\"minimum\":0}},\"additionalProperties\":false}", comptime componentOf(&.{input(Money)}, "Money"));
}

test "an anonymous type stands inline: the compiler's name for it changes as the program does" {
    const Box = struct {
        size: struct { w: u16, h: u16 },
        kind: enum { small, large },
    };
    try expectJson("{\"type\":\"object\",\"required\":[\"size\",\"kind\"],\"properties\":{" ++
        "\"size\":{\"type\":\"object\",\"required\":[\"w\",\"h\"],\"properties\":{\"w\":{\"type\":\"integer\",\"format\":\"uint16\",\"minimum\":0,\"maximum\":65535},\"h\":{\"type\":\"integer\",\"format\":\"uint16\",\"minimum\":0,\"maximum\":65535}}}," ++
        "\"kind\":{\"type\":\"string\",\"enum\":[\"small\",\"large\"]}" ++
        "}}", comptime componentOf(&.{output(Box)}, "Box"));
    try testing.expectEqual(1, comptime componentsOf(&.{output(Box)}).object.len);
}

/// Texts of a type, its fields and its variants.
const Todo = struct {
    title: []const u8,
    old: ?u8 = null,

    pub const openapi: Doc(@This()) = .{
        .description = "A todo.",
        .deprecated = true,
        .fields = .{
            .title = .{ .description = "What to do." },
            .old = .{ .description = "Kept for old clients.", .deprecated = true },
        },
    };
};

test "the texts of a type and of its fields: description and deprecated" {
    try expectJson("{\"type\":\"object\",\"description\":\"A todo.\",\"deprecated\":true,\"required\":[\"title\",\"old\"],\"properties\":{" ++
        "\"title\":{\"type\":\"string\",\"description\":\"What to do.\"}," ++
        "\"old\":{\"type\":[\"integer\",\"null\"],\"format\":\"uint8\",\"description\":\"Kept for old clients.\",\"deprecated\":true,\"minimum\":0,\"maximum\":255}" ++
        "}}", comptime componentOf(&.{output(Todo)}, "Todo"));
}

fn Page(comptime T: type) type {
    return struct { items: []const T, total: u64 };
}

const TodoResponse = struct { id: u64 };

const Renamed = struct {
    id: u64,
    pub const openapi: Doc(@This()) = .{ .name = "TodoV2" };
};

test "names: the last part of the type's name, a generic's arguments after it, or Doc(T).name; by name in components" {
    const schemas = comptime componentsOf(&.{ output(Page(TodoResponse)), output(Renamed), output(Line) }).object;
    try testing.expectEqual(4, schemas.len);
    inline for (.{ "Line", "Page_TodoResponse", "TodoResponse", "TodoV2" }, schemas) |name, m| try testing.expectEqualStrings(name, m.key);
    try expectJson("{\"type\":\"object\",\"required\":[\"items\",\"total\"],\"properties\":{\"items\":{\"type\":\"array\",\"items\":{\"$ref\":\"#/components/schemas/TodoResponse\"}},\"total\":{\"type\":\"integer\",\"format\":\"uint64\",\"minimum\":0}}}", schemas[1].value);
    try expectJson("{\"$ref\":\"#/components/schemas/TodoV2\"}", comptime schemaOf(Renamed, .output));
}

const Address = struct { city: []const u8, zip: ?[]const u8 = null };
const Customer = struct { name: []const u8, address: Address };

test "a type read and written whose schemas differ has both, -Input and -Output, and so does a type inside it" {
    const uses = &.{ input(Customer), output(Customer) };
    const schemas = comptime componentsOf(uses).object;
    try testing.expectEqual(4, schemas.len);
    inline for (.{ "Address-Input", "Address-Output", "Customer-Input", "Customer-Output" }, schemas) |name, m| try testing.expectEqualStrings(name, m.key);
    try expectJson("{\"type\":\"object\",\"required\":[\"name\",\"address\"],\"properties\":{\"name\":{\"type\":\"string\"},\"address\":{\"$ref\":\"#/components/schemas/Address-Input\"}},\"additionalProperties\":false}", schemas[2].value);
    try expectJson("{\"type\":\"object\",\"required\":[\"name\",\"address\"],\"properties\":{\"name\":{\"type\":\"string\"},\"address\":{\"$ref\":\"#/components/schemas/Address-Output\"}}}", schemas[3].value);
    try expectJson("{\"type\":\"object\",\"required\":[\"city\"],\"properties\":{\"city\":{\"type\":\"string\"},\"zip\":{\"type\":[\"string\",\"null\"],\"default\":null}},\"additionalProperties\":false}", schemas[0].value);
    try expectJson("{\"type\":\"object\",\"required\":[\"city\",\"zip\"],\"properties\":{\"city\":{\"type\":\"string\"},\"zip\":{\"type\":[\"string\",\"null\"]}}}", schemas[1].value);
    // The uses refer to theirs.
    try expectJson("{\"$ref\":\"#/components/schemas/Customer-Input\"}", comptime registryOf(uses).schema(input(Customer)));
    try expectJson("{\"$ref\":\"#/components/schemas/Customer-Output\"}", comptime registryOf(uses).schema(output(Customer)));
}

/// The same read and written: unknown keys ignored, nothing optional.
const Point = struct {
    x: i32,
    y: i32,
    pub const unknown_fields = .ignore;
};
/// The same itself, but a type inside it differs.
const Labeled = struct {
    point: Point,
    address: Address,
    pub const unknown_fields = .ignore;
};

test "a type read and written whose schemas are the same has one; one that refers to a type split is split too" {
    const same = comptime componentsOf(&.{ input(Point), output(Point), input(Priority), output(Priority) }).object;
    try testing.expectEqual(2, same.len);
    try testing.expectEqualStrings("Point", same[0].key);
    try testing.expectEqualStrings("Priority", same[1].key);
    const nested = comptime componentsOf(&.{ input(Labeled), output(Labeled) }).object;
    inline for (.{ "Address-Input", "Address-Output", "Labeled-Input", "Labeled-Output", "Point" }, nested) |name, m| try testing.expectEqualStrings(name, m.key);
    try expectJson("{\"type\":\"object\",\"required\":[\"point\",\"address\"],\"properties\":{\"point\":{\"$ref\":\"#/components/schemas/Point\"},\"address\":{\"$ref\":\"#/components/schemas/Address-Input\"}}}", nested[2].value);
}
