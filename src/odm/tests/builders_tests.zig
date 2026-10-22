//! Tests of the conditions and changes built at run time, `odm.Filter(T)`
//! and `odm.Update(T)`: what the encoders write for them, alone and inside
//! filters, and the errors that they keep.

const std = @import("std");
const testing = std.testing;
const bson = @import("mongo-bson");
const odm = @import("../root.zig");
const filter = @import("../query/filter.zig");
const update = @import("../query/update.zig");
const models = @import("models.zig");
const User = models.User;
const Account = models.Account;

fn expectDoc(arena: std.mem.Allocator, expected: anytype, got: bson.RawDocument) !void {
    const want = try bson.encode(arena, expected, .{});
    if (!std.mem.eql(u8, want.bytes, got.bytes)) {
        std.debug.print("expected {f}\n   found {f}\n", .{ want.raw(), got });
        return error.TestExpectedEqual;
    }
}

const adult = .{ .age = .{ .@"$gte" = @as(i64, 18) } };
const active = .{ .status = "active" };

test "several where are AND in call order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const none = odm.Filter(User).init(a);
    try expectDoc(a, .{}, try filter.encode(User, a, none));
    const one = none.where(.{ .age = .{ .gte = 18 } });
    try expectDoc(a, adult, try filter.encode(User, a, one));
    const two = one.where(.{ .status = .active });
    try expectDoc(a, .{ .@"$and" = .{ adult, active } }, try filter.encode(User, a, two));
    // .{} adds nothing, and an empty Filter neither.
    try expectDoc(a, .{ .@"$and" = .{ adult, active } }, try filter.encode(User, a, two.where(.{}).where(none)));
    // A Filter in a where is one condition.
    try expectDoc(a, .{ .@"$and" = .{ .{ .@"$and" = .{ adult, active } }, .{ .name = "Ann" } } }, try filter.encode(User, a, none.where(two).where(.{ .name = "Ann" })));
}

test "branches of one Filter do not see each other" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = odm.Filter(User).init(a).where(.{ .status = .active });
    const young = base.where(.{ .age = .{ .lt = 18 } });
    const old = base.where(.{ .age = .{ .gte = 65 } });
    try expectDoc(a, .{ .@"$and" = .{ active, .{ .age = .{ .@"$lt" = @as(i64, 18) } } } }, try filter.encode(User, a, young));
    try expectDoc(a, .{ .@"$and" = .{ active, .{ .age = .{ .@"$gte" = @as(i64, 65) } } } }, try filter.encode(User, a, old));
    try expectDoc(a, active, try filter.encode(User, a, base));
}

test "where and with copy the values of their literals" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buffer = "ann".*;
    const email: []const u8 = &buffer;
    const f = odm.Filter(User).init(a).where(.{ .email = email });
    const u = odm.Update(User).init(a).with(.{ .set = .{ .name = email } });
    buffer[0] = 'b';
    try expectDoc(a, .{ .email = "ann" }, try filter.encode(User, a, f));
    try expectDoc(a, .{ .@"$set" = .{ .name = "ann" } }, try update.encode(User, a, u, .update));
}

test "the first error stays and comes out of encode" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bad: []const u8 = "\xff";
    _ = &bad;
    const f = odm.Filter(User).init(a).where(.{ .email = bad });
    try testing.expectError(error.EncodeFailed, filter.encode(User, a, f));
    // Later where change nothing, and the error comes out of a filter that
    // holds the Filter too.
    try testing.expectError(error.EncodeFailed, filter.encode(User, a, f.where(.{ .status = .active }).where(.{ .age = 1 })));
    try testing.expectError(error.EncodeFailed, filter.encode(User, a, .{ .@"or" = .{ f, .{ .age = 1 } } }));
    const u = odm.Update(User).init(a).with(.{ .set = .{ .email = bad } }).with(.{ .inc = .{ .age = 1 } });
    try testing.expectError(error.EncodeFailed, update.encode(User, a, u, .update));
}

test "with merges operators of one name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const none = odm.Update(User).init(a);
    const u = none.with(.{ .set = .{ .age = 1 } }).with(.{ .set = .{ .name = "x" } });
    try expectDoc(a, .{ .@"$set" = .{ .age = @as(i64, 1), .name = "x" } }, try update.encode(User, a, u, .update));
    // The operators in the order of their first with, their fields in the
    // order of the calls; one with is its literal.
    const v = none.with(.{ .set = .{ .name = "x" } }).with(.{ .inc = .{ .age = 1 } }).with(.{ .set = .{ .status = .blocked }, .unset = .{.profile} });
    try expectDoc(a, .{
        .@"$set" = .{ .name = "x", .status = "blocked" },
        .@"$inc" = .{ .age = @as(i64, 1) },
        .@"$unset" = .{ .profile = "" },
    }, try update.encode(User, a, v, .update));
    try expectDoc(a, .{ .@"$inc" = .{ .age = @as(i64, 1) } }, try update.encode(User, a, none.with(.{ .inc = .{ .age = 1 } }), .update));
}

test "an empty Update and a path of two with are InvalidArgument" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidArgument, update.encode(User, a, odm.Update(User).init(a), .update));
    const twice = odm.Update(Account).init(a).with(.{ .set = .{ .age = 1 } }).with(.{ .inc = .{ .age = 1 } });
    try testing.expectError(error.InvalidArgument, update.encode(Account, a, twice, .update));
    const lyon: models.Address = .{ .city = "Lyon", .country = "FR" };
    const whole = odm.Update(Account).init(a).with(.{ .set = .{ .address = lyon } });
    try testing.expectError(error.InvalidArgument, update.encode(Account, a, whole.with(.{ .unset = .{.@"address.zip"} }), .update));
    const zip = odm.Update(Account).init(a).with(.{ .set = .{ .address = .{ .zip = "69001" } } });
    try testing.expectError(error.InvalidArgument, update.encode(Account, a, zip.with(.{ .set = .{ .address = lyon } }), .update));
    // Paths that only share a beginning are no conflict.
    try expectDoc(a, .{ .@"$set" = .{ .@"address.zip" = "69001", .@"address.city" = "Lyon" } }, try update.encode(Account, a, zip.with(.{ .set = .{ .address = .{ .city = "Lyon" } } }), .update));
}

test "Filter(T) in and, or, nor" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const adults = odm.Filter(User).init(a).where(.{ .age = .{ .gte = 18 } });
    const both = adults.where(.{ .status = .active });
    // In a tuple with literals; a Filter of several where is their $and,
    // and an empty one matches every document.
    try expectDoc(a, .{ .@"$or" = .{ adult, .{ .status = "blocked" } } }, try filter.encode(User, a, .{ .@"or" = .{ adults, .{ .status = .blocked } } }));
    try expectDoc(a, .{ .@"$nor" = .{ .{ .@"$and" = .{ adult, active } }, .{} } }, try filter.encode(User, a, .{ .nor = .{ both, odm.Filter(User).init(a) } }));
    // A slice of them, known at run time.
    const list: []const odm.Filter(User) = &.{ adults, both };
    try expectDoc(a, .{ .@"$and" = .{ adult, .{ .@"$and" = .{ adult, active } } } }, try filter.encode(User, a, .{ .@"and" = list }));
    // MongoDB takes no empty and, or, nor.
    const empty: []const odm.Filter(User) = &.{};
    try testing.expectError(error.InvalidArgument, filter.encode(User, a, .{ .@"or" = empty }));
}

test "isEmpty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = odm.Filter(User).init(a);
    try testing.expect(f.isEmpty());
    try testing.expect(f.where(.{}).isEmpty());
    try testing.expect(!f.where(.{ .age = 1 }).isEmpty());
    const u = odm.Update(User).init(a);
    try testing.expect(u.isEmpty());
    try testing.expect(!u.with(.{ .set = .{ .age = 1 } }).isEmpty());
    // One that failed is not empty: its error comes out of the operation.
    var bad: []const u8 = "\xff";
    _ = &bad;
    try testing.expect(!f.where(.{ .email = bad }).isEmpty());
}
