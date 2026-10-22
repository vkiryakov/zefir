//! The models of odm's tests, which the test files of the module share:
//! `User` of the design (§4.3) with its subdocuments; `Account`, which has
//! a field of each kind (optional ones, lists of strings and of structs, a
//! required struct, a float); `Gen`, whose id odm always makes; and
//! `Slug`, whose id the application gives. `Item` and `Address` are
//! subdocuments of `Account`. tests/compile_errors.zig declares the same
//! models at its top level, so that its messages name them.

const bson = @import("mongo-bson");
const v = @import("validator");
const odm = @import("../root.zig");

pub const User = struct {
    id: ?bson.ObjectId = null, // null: odm makes an ObjectId on insert
    email: []const u8,
    name: []const u8,
    age: u32 = 0,
    status: Status = .active,
    profile: ?Profile = null,
    created_at: bson.DateTime,

    pub const Status = enum { active, blocked, deleted };
    pub const Profile = struct { city: []const u8, country: []const u8 };

    pub const odm_schema: odm.Schema(User) = .{
        .collection = "users",
        .id = .id, // in the database this field is _id
        .names = .{ .created_at = "createdAt" },
        .indexes = &.{
            .{ .keys = &.{.{ .email = .asc }}, .unique = true },
            .{ .keys = &.{ .{ .status = .asc }, .{ .created_at = .desc } } },
        },
    };

    pub const field_rules = .{ // the rules of zefir-validator
        .email = .{ v.minLength(5), v.maxLength(255) },
        .age = v.range(0, 150),
    };
};

pub const Item = struct { sku: []const u8, qty: u32 };

pub const Address = struct { city: []const u8, country: []const u8, zip: ?[]const u8 = null };

pub const Account = struct {
    id: ?bson.ObjectId = null,
    email: []const u8,
    name: []const u8,
    age: u32 = 0,
    status: User.Status = .active,
    profile: ?User.Profile = null,
    created_at: bson.DateTime,
    nickname: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    labels: ?[]const []const u8 = null,
    items: []const Item = &.{},
    address: Address,
    visits: u32,
    score: ?f64 = null,

    pub const odm_schema: odm.Schema(Account) = .{ .collection = "accounts", .id = .id, .names = .{ .created_at = "createdAt" } };
};

pub const Gen = struct {
    id: bson.ObjectId,
    n: i32 = 0,

    pub const odm_schema: odm.Schema(Gen) = .{ .collection = "gens", .id = .id };
};

pub const Slug = struct {
    id: []const u8,
    title: []const u8,

    pub const odm_schema: odm.Schema(Slug) = .{ .collection = "slugs", .id = .id };
};
