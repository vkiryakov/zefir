//! Documents three ways. Every operation of zefir-mongo takes its
//! documents in one of three forms: a struct or an anonymous literal,
//! which the codec writes by the types of its fields; a document built
//! field by field with `bson.Builder`; or a `bson.RawDocument`, bytes that
//! are a document already. This program writes a customer of the shop in
//! each form and prints the documents as Extended JSON, the text MongoDB's
//! tools show them in. It needs no server: `zig build test-mongo` runs it.

const std = @import("std");
const mongo = @import("mongo");
const bson = mongo.bson;

const Status = enum { active, suspended };

const Address = struct {
    city: []const u8,
    zip: ?[]const u8 = null,
};

/// A customer of the shop, as the collection "users" keeps it.
const User = struct {
    _id: bson.ObjectId,
    email: []const u8,
    name: []const u8,
    age: i32,
    status: Status = .active,
    address: Address,
    tags: []const []const u8 = &.{},
    joined: bson.DateTime,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const out = &stdout.interface;

    // 1. A struct: its fields in their order, an enum by the name of its
    // tag, a null as BSON null.
    const ann: User = .{
        ._id = try .parseHex("65f0c0ffee0000000000a001"),
        .email = "ann@example.com",
        .name = "Ann",
        .age = 30,
        .address = .{ .city = "Lisbon" },
        .tags = &.{"vip"},
        .joined = .{ .milliseconds = 1_760_000_000_000 },
    };
    const doc = try bson.encode(gpa, ann, .{});
    defer doc.deinit();
    try out.print("a struct:      {f}\n", .{doc.raw()});
    // The same struct without its null fields.
    const lean = try bson.encode(gpa, ann, .{ .skip_nulls = true });
    defer lean.deinit();
    try out.print("without nulls: {f}\n", .{lean.raw()});
    // And back. decode copies the strings into the arena: the user lives as
    // long as the arena, not as long as the document.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const back = try bson.decode(User, arena.allocator(), doc.raw(), .{});
    try out.print("decoded:       {s}, {d}, from {s}, {t}\n", .{ back.name, back.age, back.address.city, back.status });

    // 2. Anonymous literals: filters and updates, written where they go.
    // An operator is a field named with @"…", a path too.
    const adults = try bson.encode(gpa, .{ .age = .{ .@"$gte" = 18 }, .status = .active, .@"address.city" = "Lisbon" }, .{});
    defer adults.deinit();
    try out.print("a filter:      {f}\n", .{adults.raw()});
    // A tuple is an array.
    const tagged = try bson.encode(gpa, .{ .tags = .{ .@"$in" = .{ "vip", "staff" } } }, .{});
    defer tagged.deinit();
    try out.print("with a tuple:  {f}\n", .{tagged.raw()});
    // .{} is the empty document: as a filter, it matches every document.
    const everyone = try bson.encode(gpa, .{}, .{});
    defer everyone.deinit();
    try out.print("empty:         {f}\n", .{everyone.raw()});
    // A null goes as BSON null, so a filter of an optional that is null
    // matches the documents whose field is null or missing, never all.
    const nickname: ?[]const u8 = null;
    const unnamed = try bson.encode(gpa, .{ .nickname = nickname }, .{});
    defer unnamed.deinit();
    try out.print("a null:        {f}\n", .{unnamed.raw()});

    // 3. bson.literal: a document known when the program compiles, in
    // static bytes, with no allocator and no try. For sorts, projections
    // and the keys of indexes.
    const by_age = bson.literal(.{ .age = -1, .name = 1 });
    try out.print("a literal:     {f}\n", .{by_age});

    // 4. A Builder: field by field, when the fields are known only as the
    // program runs.
    var b: bson.Builder = .init(gpa);
    defer b.deinit();
    try b.putString("email", "bob@example.com");
    try b.putInt32("age", 17);
    try b.beginArray("tags");
    for ([_][]const u8{ "new", "student" }) |tag| try b.putString("", tag);
    try b.end();
    const built = try b.finish();
    defer built.deinit();
    try out.print("built:         {f}\n", .{built.raw()});

    // 5. A RawDocument: bytes that are a document already, such as a reply
    // or a file. init checks the length, validate the rest; reading takes
    // no copy.
    const raw = try bson.RawDocument.init(doc.bytes);
    try raw.validate();
    const city = (try raw.getPath("address.city")).?;
    try out.print("read:          address.city is {s}; the keys:", .{city.string});
    var it = raw.iterator();
    while (try it.next()) |element| try out.print(" {s}", .{element.key});
    try out.print("\n", .{});
    // Bytes that are no document never make a reader panic.
    if (bson.RawDocument.init(doc.bytes[0..20])) |_| {
        try out.print("cut short:     a document\n", .{});
    } else |err| try out.print("cut short:     error.{t}\n", .{err});
    try out.flush();
}
