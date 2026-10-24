//! Tests of the codec of models: the documents of a model under the BSON
//! names of its schema, `_id` for the id, without null optionals, and the
//! path and cause of a document that does not fit the model.

const std = @import("std");
const testing = std.testing;
const bson = @import("mongo-bson");
const odm = @import("../root.zig");
const codec = @import("../model/codec.zig");
const models = @import("models.zig");
const User = models.User;
const Account = models.Account;
const Gen = models.Gen;
const Slug = models.Slug;

const id = bson.ObjectId.parseHex("652f8a1b9c0d4e5f60718293") catch unreachable;
const created: bson.DateTime = .{ .milliseconds = 1_760_000_000_000 };

/// The keys of `doc`, in their order, are `expected`.
fn expectKeys(expected: []const []const u8, doc: bson.RawDocument) !void {
    var it = doc.iterator();
    for (expected) |key| {
        const element = (try it.next()) orelse return error.TestExpectedMoreKeys;
        try testing.expectEqualStrings(key, element.key);
    }
    try testing.expect((try it.next()) == null);
}

/// The BSON type of the element `key` of `doc`.
fn typeOf(doc: bson.RawDocument, key: []const u8) !bson.Type {
    const value = (try doc.get(key)) orelse return error.TestExpectedKey;
    return std.meta.activeTag(value);
}

const ann: User = .{ .id = id, .email = "ann@example.com", .name = "Ann", .age = 30, .created_at = created };

/// A model with a list whose items may be null.
const Listed = struct {
    id: ?bson.ObjectId = null,
    l: []const ?u32,

    pub const odm_schema: odm.Schema(Listed) = .{ .collection = "listed", .id = .id };
};

test "null optionals are left out at every depth; a null item of a list stays" {
    const account: Account = .{
        .id = id,
        .email = "ann@example.com",
        .name = "Ann",
        .profile = .{ .city = "Paris", .country = "FR" },
        .created_at = created,
        .address = .{ .city = "Lyon", .country = "FR" },
        .visits = 3,
    };
    const doc = try codec.encode(Account, testing.allocator, &account, .insert);
    defer doc.deinit();
    // No nickname, labels or score: they are null.
    try expectKeys(&.{ "_id", "email", "name", "age", "status", "profile", "createdAt", "tags", "items", "address", "visits" }, doc.raw());
    try expectKeys(&.{ "city", "country" }, (try doc.raw().get("profile")).?.document);
    // No zip in the address.
    try expectKeys(&.{ "city", "country" }, (try doc.raw().get("address")).?.document);

    const listed: Listed = .{ .l = &.{ null, 2 } };
    const list_doc = try codec.encode(Listed, testing.allocator, &listed, .insert);
    defer list_doc.deinit();
    const expected = try bson.encode(testing.allocator, .{ .l = &[_]?u32{ null, 2 } }, .{});
    defer expected.deinit();
    try testing.expectEqualSlices(u8, expected.bytes, list_doc.bytes);
}

/// The document of an `Account` that another writer made, with `extra`
/// fields at the end.
fn accountDoc(extra: anytype) !bson.OwnedDocument {
    var b: bson.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.put("_id", id);
    try b.put("email", "ann@example.com");
    try b.put("name", "Ann");
    try b.put("createdAt", created);
    try b.put("address", .{ .city = "Lyon", .country = "FR" });
    try b.put("visits", @as(i32, 3));
    try bson.codec.writeFields(&b, extra, .{});
    return b.finish();
}

test "a missing optional and a null of another writer read as null" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: odm.Diagnostics = .{};
    const missing = try accountDoc(.{});
    defer missing.deinit();
    const a = try codec.decode(Account, Account, arena.allocator(), missing.raw(), &d);
    try testing.expectEqual(null, a.nickname);
    try testing.expectEqual(null, a.score);
    try testing.expectEqual(null, a.address.zip);
    try testing.expectEqual(id, a.id.?);

    const nulls = try accountDoc(.{ .nickname = null, .score = null, .profile = null });
    defer nulls.deinit();
    const b = try codec.decode(Account, Account, arena.allocator(), nulls.raw(), &d);
    try testing.expectEqual(null, b.nickname);
    try testing.expectEqual(null, b.score);
    try testing.expectEqual(null, b.profile);
    try testing.expectEqual(null, d.cause);
}

test "a missing required field is DecodeFailed with MissingField and the BSON path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: odm.Diagnostics = .{};
    const doc = try bson.encode(testing.allocator, .{ ._id = id, .email = "ann@example.com", .name = "Ann" }, .{});
    defer doc.deinit();
    try testing.expectError(error.DecodeFailed, codec.decode(User, User, arena.allocator(), doc.raw(), &d));
    try testing.expectEqual(error.MissingField, d.cause.?);
    try testing.expectEqualStrings("createdAt", d.path());

    // A value of the wrong type in a subdocument: the path holds its keys.
    var wrong_d: odm.Diagnostics = .{};
    const wrong = try accountDoc(.{ .profile = .{ .city = 75, .country = "FR" } });
    defer wrong.deinit();
    try testing.expectError(error.DecodeFailed, codec.decode(Account, Account, arena.allocator(), wrong.raw(), &wrong_d));
    try testing.expectEqual(error.WrongType, wrong_d.cause.?);
    try testing.expectEqualStrings("profile.city", wrong_d.path());

    // Bytes that are not BSON are InvalidBson, without a cause: a string
    // "email" of 100 bytes in a document of 16.
    var broken_d: odm.Diagnostics = .{};
    const broken: bson.RawDocument = .{ .bytes = &.{ 16, 0, 0, 0, 0x02, 'e', 'm', 'a', 'i', 'l', 0, 100, 0, 0, 0, 0 } };
    try testing.expectError(error.InvalidBson, codec.decode(User, User, arena.allocator(), broken, &broken_d));
    try testing.expectEqual(null, broken_d.cause);
}

test "the id and names are BSON keys" {
    const doc = try codec.encode(User, testing.allocator, &ann, .insert);
    defer doc.deinit();
    try expectKeys(&.{ "_id", "email", "name", "age", "status", "createdAt" }, doc.raw());
    try testing.expectEqual(id, (try doc.raw().get("_id")).?.object_id);
    // A replacement cannot change the id: it has no _id.
    const replacement = try codec.encode(User, testing.allocator, &ann, .replace);
    defer replacement.deinit();
    try expectKeys(&.{ "email", "name", "age", "status", "createdAt" }, replacement.raw());
    // A projection reads by the keys of its model.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: odm.Diagnostics = .{};
    const Stamp = struct { id: ?bson.ObjectId, created_at: bson.DateTime };
    const stamp = try codec.decode(User, Stamp, arena.allocator(), doc.raw(), &d);
    try testing.expectEqual(id, stamp.id.?);
    try testing.expectEqual(created, stamp.created_at);
}

/// A model of the other kinds of fields: a Binary, a fixed array, a list
/// of strings and one of structs, and an optional struct with a value.
const Blob = struct {
    id: []const u8,
    status: User.Status,
    at: bson.DateTime,
    data: bson.Binary,
    pair: [2]i32,
    words: []const []const u8,
    items: []const models.Item,
    address: models.Address,
    profile: ?User.Profile = null,

    pub const odm_schema: odm.Schema(Blob) = .{ .collection = "blobs", .id = .id };
};

test "enum, DateTime, Binary, nested structs and lists round-trip" {
    const blob: Blob = .{
        .id = "blob-1",
        .status = .blocked,
        .at = created,
        .data = .{ .subtype = .generic, .bytes = "\x00\x01\xfe" },
        .pair = .{ -1, 7 },
        .words = &.{ "a", "b" },
        .items = &.{ .{ .sku = "x", .qty = 5 }, .{ .sku = "y", .qty = 0 } },
        .address = .{ .city = "Lyon", .country = "FR", .zip = "69001" },
        .profile = .{ .city = "Paris", .country = "FR" },
    };
    const doc = try codec.encode(Blob, testing.allocator, &blob, .insert);
    defer doc.deinit();
    try testing.expectEqualStrings("blob-1", (try doc.raw().get("_id")).?.string);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: odm.Diagnostics = .{};
    const back = try codec.decode(Blob, Blob, arena.allocator(), doc.raw(), &d);
    try testing.expectEqualDeep(blob, back);

    var account: Account = .{
        .id = id,
        .email = "ann@example.com",
        .name = "Ann",
        .created_at = created,
        .tags = &.{ "admin", "ops" },
        .labels = &.{"new"},
        .items = &.{.{ .sku = "x", .qty = 1 }},
        .address = .{ .city = "Lyon", .country = "FR" },
        .visits = 9,
        .score = 1.5,
    };
    account.nickname = "annie";
    const account_doc = try codec.encode(Account, testing.allocator, &account, .insert);
    defer account_doc.deinit();
    try testing.expectEqualDeep(account, try codec.decode(Account, Account, arena.allocator(), account_doc.raw(), &d));
}

test "u32 is int64 and i32 is int32" {
    const doc = try codec.encode(User, testing.allocator, &ann, .insert);
    defer doc.deinit();
    try testing.expectEqual(.int64, try typeOf(doc.raw(), "age"));
    const gen: Gen = .{ .id = id, .n = 4 };
    const gen_doc = try codec.encode(Gen, testing.allocator, &gen, .insert);
    defer gen_doc.deinit();
    try testing.expectEqual(.int32, try typeOf(gen_doc.raw(), "n"));
}

test "fromInsert puts the id in" {
    const doc: odm.Insert(Gen) = .{ .n = 7 };
    const gen = codec.fromInsert(Gen, doc, id);
    try testing.expectEqual(id, gen.id);
    try testing.expectEqual(7, gen.n);
    // The other kinds of ids take theirs in the same way.
    const user = codec.fromInsert(User, .{ .email = "ann@example.com", .name = "Ann", .created_at = created }, id);
    try testing.expectEqual(id, user.id.?);
    try testing.expectEqualStrings("Ann", user.name);
    const slug = codec.fromInsert(Slug, .{ .id = "", .title = "Hello" }, "hello");
    try testing.expectEqualStrings("hello", slug.id);
    try testing.expectEqualStrings("Hello", slug.title);
}
