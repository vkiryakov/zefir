//! Code that must not compile, one test per case of cases.zig, which
//! names the error each one stops with. `addOdmCompileChecks` in
//! build.zig compiles one test at a time, by its name, in a module rooted
//! at src/odm/compile_checks.zig; never import this file elsewhere.
//!
//! The fixtures are declared here, at the top of the file, so that Zig
//! names them `tests.compile_errors.X` in the messages. The public API
//! comes from ../root.zig: this file is in odm's directory, and a file
//! cannot be in two modules.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const bson = @import("mongo-bson");
const v = @import("validator");
const odm = @import("../root.zig");
const filter = @import("../query/filter.zig");
const options = @import("../query/options.zig");
const update = @import("../query/update.zig");
const Client = odm.Client;

// The models of tests/models.zig, declared here so that the messages name
// them `tests.compile_errors.User` and so on.

const User = struct {
    id: ?bson.ObjectId = null,
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
        .id = .id,
        .names = .{ .created_at = "createdAt" },
        .indexes = &.{
            .{ .keys = &.{.{ .email = .asc }}, .unique = true },
            .{ .keys = &.{ .{ .status = .asc }, .{ .created_at = .desc } } },
        },
    };

    pub const field_rules = .{
        .email = .{ v.minLength(5), v.maxLength(255) },
        .age = v.range(0, 150),
    };
};

const Item = struct { sku: []const u8, qty: u32 };

const Address = struct { city: []const u8, country: []const u8, zip: ?[]const u8 = null };

const Account = struct {
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

const Gen = struct {
    id: bson.ObjectId,
    n: i32 = 0,

    pub const odm_schema: odm.Schema(Gen) = .{ .collection = "gens", .id = .id };
};

const Slug = struct {
    id: []const u8,
    title: []const u8,

    pub const odm_schema: odm.Schema(Slug) = .{ .collection = "slugs", .id = .id };
};

/// The methods of the contract for a client of type `T`, which a fixture
/// takes one by one.
fn Methods(comptime T: type) type {
    return struct {
        pub fn connect(_: *T, _: Io, _: core.Context, _: ?*odm.Diagnostics) odm.DriverError!void {}
        pub fn ping(_: *T, _: Io, _: core.Context, _: ?*odm.Diagnostics) odm.DriverError!void {}
        pub fn close(_: *T, _: Io) void {}
        pub fn deinit(_: *T) void {}
        pub fn stats(_: *T) ?Client.PoolStats {
            return null;
        }
        pub fn insert(_: *T, _: Io, _: core.Context, _: *const Client.InsertRequest, _: Client.CallOptions) odm.DriverError!Client.InsertResult {
            return .{ .inserted = 0 };
        }
        pub fn update(_: *T, _: Io, _: core.Context, _: *const Client.UpdateRequest, _: Client.CallOptions) odm.DriverError!Client.UpdateResult {
            return .{ .matched = 0, .modified = 0 };
        }
        pub fn delete(_: *T, _: Io, _: core.Context, _: *const Client.DeleteRequest, _: Client.CallOptions) odm.DriverError!Client.DeleteResult {
            return .{ .deleted = 0 };
        }
        pub fn find(_: *T, _: Io, _: core.Context, _: *const Client.FindRequest, _: Client.CallOptions) odm.DriverError!odm.RawCursor {
            return error.Unavailable;
        }
        pub fn count(_: *T, _: Io, _: core.Context, _: *const Client.CountRequest, _: Client.CallOptions) odm.DriverError!u64 {
            return 0;
        }
    };
}

const NoInsert = struct {
    n: u8 = 0,
    pub const capabilities: odm.Capabilities = .{};
    pub const connect = Methods(NoInsert).connect;
    pub const ping = Methods(NoInsert).ping;
    pub const close = Methods(NoInsert).close;
    pub const deinit = Methods(NoInsert).deinit;
    pub const stats = Methods(NoInsert).stats;
};

test "compile error: a client without insert" {
    var client: NoInsert = .{};
    _ = Client.init(&client);
}

const OtherInsert = struct {
    n: u8 = 0,
    pub const capabilities: odm.Capabilities = .{};
    pub const connect = Methods(OtherInsert).connect;
    pub const ping = Methods(OtherInsert).ping;
    pub const close = Methods(OtherInsert).close;
    pub const deinit = Methods(OtherInsert).deinit;
    pub const stats = Methods(OtherInsert).stats;

    /// Without the options of the call.
    pub fn insert(_: *OtherInsert, _: Io, _: core.Context, _: *const Client.InsertRequest) odm.DriverError!Client.InsertResult {
        return .{ .inserted = 0 };
    }
};

test "compile error: insert of another signature" {
    var client: OtherInsert = .{};
    _ = Client.init(&client);
}

const NoAggregate = struct {
    n: u8 = 0,
    pub const capabilities: odm.Capabilities = .{ .aggregate = true };
    pub const connect = Methods(NoAggregate).connect;
    pub const ping = Methods(NoAggregate).ping;
    pub const close = Methods(NoAggregate).close;
    pub const deinit = Methods(NoAggregate).deinit;
    pub const stats = Methods(NoAggregate).stats;
    pub const insert = Methods(NoAggregate).insert;
    pub const update = Methods(NoAggregate).update;
    pub const delete = Methods(NoAggregate).delete;
    pub const find = Methods(NoAggregate).find;
};

test "compile error: aggregate in the capabilities, without the method" {
    var client: NoAggregate = .{};
    _ = Client.init(&client);
}

const HiddenCount = struct {
    n: u8 = 0,
    pub const capabilities: odm.Capabilities = .{};
    pub const connect = Methods(HiddenCount).connect;
    pub const ping = Methods(HiddenCount).ping;
    pub const close = Methods(HiddenCount).close;
    pub const deinit = Methods(HiddenCount).deinit;
    pub const stats = Methods(HiddenCount).stats;
    pub const insert = Methods(HiddenCount).insert;
    pub const update = Methods(HiddenCount).update;
    pub const delete = Methods(HiddenCount).delete;
    pub const find = Methods(HiddenCount).find;
    pub const count = Methods(HiddenCount).count;
};

test "compile error: the method count, without the capability" {
    var client: HiddenCount = .{};
    _ = Client.init(&client);
}

const SomeClient = struct { n: u8 = 0 };

test "compile error: Client.init of a client by value" {
    const client: SomeClient = .{};
    _ = Client.init(client);
}

test "compile error: Client.init of a constant client" {
    const client: SomeClient = .{};
    _ = Client.init(&client);
}

const NoCapabilities = struct {
    n: u8 = 0,
    pub const connect = Methods(NoCapabilities).connect;
};

test "compile error: a client without capabilities" {
    var client: NoCapabilities = .{};
    _ = Client.init(&client);
}

const NamelessDriver = struct {
    n: u8 = 0,

    pub fn open(_: *NamelessDriver, _: Io, _: *const odm.ConnectionConfig) odm.Driver.OpenError!Client {
        return error.Unsupported;
    }
};

test "compile error: a driver without a name" {
    var driver: NamelessDriver = .{};
    _ = odm.Driver.init(&driver);
}

const DriverWithoutOpen = struct {
    n: u8 = 0,
    pub const name = "without-open";
};

test "compile error: a driver without open" {
    var driver: DriverWithoutOpen = .{};
    _ = odm.Driver.init(&driver);
}

const CursorWithoutNext = struct {
    n: u8 = 0,

    pub fn deinit(_: *CursorWithoutNext, _: Io) void {}
};

test "compile error: a cursor without next" {
    var cursor: CursorWithoutNext = .{};
    _ = odm.RawCursor.init(&cursor);
}

// The checks of a model: odm.assertModel, one case per row of the design's
// table "Model and schema".

test "compile error: assertModel of an integer" {
    comptime odm.assertModel(u32);
}

test "compile error: assertModel of a tuple" {
    comptime odm.assertModel(struct { u32, u8 });
}

const NoSchema = struct { id: ?bson.ObjectId = null, name: []const u8 };

test "compile error: a model without odm_schema" {
    comptime odm.assertModel(NoSchema);
}

const SchemaOfAnotherType = struct {
    id: ?bson.ObjectId = null,
    pub const odm_schema: u32 = 0;
};

test "compile error: odm_schema of another type" {
    comptime odm.assertModel(SchemaOfAnotherType);
}

const NoCollection = struct {
    id: ?bson.ObjectId = null,
    pub const odm_schema: odm.Schema(NoCollection) = .{ .collection = "", .id = .id };
};

test "compile error: an empty collection name" {
    comptime odm.assertModel(NoCollection);
}

const DollarCollection = struct {
    id: ?bson.ObjectId = null,
    pub const odm_schema: odm.Schema(DollarCollection) = .{ .collection = "a$b", .id = .id };
};

test "compile error: a collection name with a dollar" {
    comptime odm.assertModel(DollarCollection);
}

const SystemCollection = struct {
    id: ?bson.ObjectId = null,
    pub const odm_schema: odm.Schema(SystemCollection) = .{ .collection = "system.users", .id = .id };
};

test "compile error: a collection of the system" {
    comptime odm.assertModel(SystemCollection);
}

const LongCollection = struct {
    id: ?bson.ObjectId = null,
    pub const odm_schema: odm.Schema(LongCollection) = .{ .collection = &@as([192]u8, @splat('a')), .id = .id };
};

test "compile error: a collection name of 192 bytes" {
    comptime odm.assertModel(LongCollection);
}

const BinaryCollection = struct {
    id: ?bson.ObjectId = null,
    pub const odm_schema: odm.Schema(BinaryCollection) = .{ .collection = "users\xff", .id = .id };
};

test "compile error: a collection name that is not UTF-8" {
    comptime odm.assertModel(BinaryCollection);
}

const OptionalSlug = struct {
    id: ?[]const u8 = null,
    title: []const u8,
    pub const odm_schema: odm.Schema(OptionalSlug) = .{ .collection = "slugs", .id = .id };
};

test "compile error: an optional id that is not an ObjectId" {
    comptime odm.assertModel(OptionalSlug);
}

const StrayId = struct {
    id: ?bson.ObjectId = null,
    _id: u32,
    pub const odm_schema: odm.Schema(StrayId) = .{ .collection = "strays", .id = .id };
};

test "compile error: a field _id that is not the id" {
    comptime odm.assertModel(StrayId);
}

const NamedId = struct {
    id: ?bson.ObjectId = null,
    pub const odm_schema: odm.Schema(NamedId) = .{ .collection = "named", .id = .id, .names = .{ .id = "x" } };
};

test "compile error: a BSON name for the id" {
    comptime odm.assertModel(NamedId);
}

const EmptyName = struct {
    id: ?bson.ObjectId = null,
    name: []const u8,
    pub const odm_schema: odm.Schema(EmptyName) = .{ .collection = "names", .id = .id, .names = .{ .name = "" } };
};

test "compile error: an empty BSON name" {
    comptime odm.assertModel(EmptyName);
}

const DollarName = struct {
    id: ?bson.ObjectId = null,
    name: []const u8,
    pub const odm_schema: odm.Schema(DollarName) = .{ .collection = "names", .id = .id, .names = .{ .name = "$a" } };
};

test "compile error: a BSON name that starts with a dollar" {
    comptime odm.assertModel(DollarName);
}

const DottedName = struct {
    id: ?bson.ObjectId = null,
    name: []const u8,
    pub const odm_schema: odm.Schema(DottedName) = .{ .collection = "names", .id = .id, .names = .{ .name = "a.b" } };
};

test "compile error: a BSON name with a dot" {
    comptime odm.assertModel(DottedName);
}

const TwinNames = struct {
    id: ?bson.ObjectId = null,
    a: u32,
    b: u32,
    pub const odm_schema: odm.Schema(TwinNames) = .{ .collection = "twins", .id = .id, .names = .{ .b = "a" } };
};

test "compile error: two fields under one BSON name" {
    comptime odm.assertModel(TwinNames);
}

const Operator = struct {
    id: ?bson.ObjectId = null,
    @"or": u32,
    pub const odm_schema: odm.Schema(Operator) = .{ .collection = "operators", .id = .id };
};

test "compile error: a field named as a logical operator" {
    comptime odm.assertModel(Operator);
}

const Unsigned = struct {
    id: ?bson.ObjectId = null,
    n: u64,
    pub const odm_schema: odm.Schema(Unsigned) = .{ .collection = "unsigned", .id = .id };
};

test "compile error: a field of u64" {
    comptime odm.assertModel(Unsigned);
}

const Narrow = struct {
    id: ?bson.ObjectId = null,
    x: f32,
    pub const odm_schema: odm.Schema(Narrow) = .{ .collection = "narrow", .id = .id };
};

test "compile error: a field of f32" {
    comptime odm.assertModel(Narrow);
}

const NarrowItems = struct {
    id: ?bson.ObjectId = null,
    items: []const struct { x: f32 } = &.{},
    pub const odm_schema: odm.Schema(NarrowItems) = .{ .collection = "narrow", .id = .id };
};

test "compile error: an f32 in the items of a list" {
    comptime odm.assertModel(NarrowItems);
}

const OptionalDefault = struct {
    id: ?bson.ObjectId = null,
    n: ?u32 = 5,
    pub const odm_schema: odm.Schema(OptionalDefault) = .{ .collection = "defaults", .id = .id };
};

test "compile error: an optional whose default is not null" {
    comptime odm.assertModel(OptionalDefault);
}

const NestedDefault = struct {
    id: ?bson.ObjectId = null,
    inner: struct { n: ?u32 = 5 },
    pub const odm_schema: odm.Schema(NestedDefault) = .{ .collection = "defaults", .id = .id };
};

test "compile error: an optional default inside a subdocument" {
    comptime odm.assertModel(NestedDefault);
}

const NoKeys = struct {
    id: ?bson.ObjectId = null,
    email: []const u8,
    pub const odm_schema: odm.Schema(NoKeys) = .{ .collection = "keys", .id = .id, .indexes = &.{.{ .keys = &.{} }} };
};

test "compile error: an index without keys" {
    comptime odm.assertModel(NoKeys);
}

const KeyTwice = struct {
    id: ?bson.ObjectId = null,
    email: []const u8,
    pub const odm_schema: odm.Schema(KeyTwice) = .{
        .collection = "keys",
        .id = .id,
        .indexes = &.{.{ .keys = &.{ .{ .email = .asc }, .{ .email = .desc } } }},
    };
};

test "compile error: an index with one key twice" {
    comptime odm.assertModel(KeyTwice);
}

const TextNumber = struct {
    id: ?bson.ObjectId = null,
    age: u32,
    pub const odm_schema: odm.Schema(TextNumber) = .{ .collection = "texts", .id = .id, .indexes = &.{.{ .keys = &.{.{ .age = .text }} }} };
};

test "compile error: a text key on a number" {
    comptime odm.assertModel(TextNumber);
}

const TtlString = struct {
    id: ?bson.ObjectId = null,
    email: []const u8,
    pub const odm_schema: odm.Schema(TtlString) = .{
        .collection = "ttls",
        .id = .id,
        .indexes = &.{.{ .keys = &.{.{ .email = .asc }}, .expire_after_seconds = 60 }},
    };
};

test "compile error: a TTL on a string" {
    comptime odm.assertModel(TtlString);
}

const SameIndexes = struct {
    id: ?bson.ObjectId = null,
    email: []const u8,
    pub const odm_schema: odm.Schema(SameIndexes) = .{
        .collection = "same",
        .id = .id,
        .indexes = &.{ .{ .keys = &.{.{ .email = .asc }} }, .{ .keys = &.{.{ .email = .asc }}, .unique = true } },
    };
};

test "compile error: two indexes with the same keys" {
    comptime odm.assertModel(SameIndexes);
}

const UniqueOptional = struct {
    id: ?bson.ObjectId = null,
    profile: ?User.Profile = null,
    pub const odm_schema: odm.Schema(UniqueOptional) = .{
        .collection = "uniques",
        .id = .id,
        .indexes = &.{.{ .keys = &.{.{ .@"profile.city" = .asc }}, .unique = true }},
    };
};

test "compile error: a unique index on an optional path without sparse" {
    comptime odm.assertModel(UniqueOptional);
}

const Typo = struct {
    id: ?bson.ObjectId = null,
    name: []const u8,
    pub const odm_schema: odm.Schema(Typo) = .{ .collection = "typos", .id = .id };
    pub const field_rules = .{ .nmae = v.minLength(1) };
};

test "compile error: field_rules of a field that is not there" {
    comptime odm.assertModel(Typo);
}

// Filters: one case per row of the design's table "Filters", through the
// encoder of query/filter.zig.

test "compile error: a filter on a field that is not there" {
    _ = try filter.encode(User, std.testing.allocator, .{ .agee = .{ .gte = 18 } });
}

test "compile error: an unknown filter operator" {
    _ = try filter.encode(User, std.testing.allocator, .{ .age = .{ .gtee = 18 } });
}

test "compile error: regex on a number" {
    _ = try filter.encode(User, std.testing.allocator, .{ .age = .{ .regex = "1" } });
}

test "compile error: size on a string" {
    _ = try filter.encode(User, std.testing.allocator, .{ .email = .{ .size = 1 } });
}

test "compile error: a string where a number goes" {
    _ = try filter.encode(User, std.testing.allocator, .{ .age = .{ .gte = "18" } });
}

test "compile error: a number out of the range of its field" {
    _ = try filter.encode(User, std.testing.allocator, .{ .age = -1 });
}

test "compile error: a tag that the enum does not have" {
    _ = try filter.encode(User, std.testing.allocator, .{ .status = .actve });
}

test "compile error: null on a required field" {
    _ = try filter.encode(User, std.testing.allocator, .{ .email = null });
}

test "compile error: or of a number" {
    _ = try filter.encode(User, std.testing.allocator, .{ .@"or" = 5 });
}

test "compile error: and of no filters" {
    _ = try filter.encode(User, std.testing.allocator, .{ .@"and" = .{} });
}

// Filters on documents and lists.

test "compile error: a field that a nested struct does not have" {
    _ = try filter.encode(User, std.testing.allocator, .{ .profile = .{ .ctiy = "Paris" } });
}

test "compile error: a document without eq" {
    const p: User.Profile = .{ .city = "Paris", .country = "FR" };
    _ = try filter.encode(User, std.testing.allocator, .{ .profile = p });
}

test "compile error: a list as the value of a list" {
    const list: []const []const u8 = &.{ "a", "b" };
    _ = try filter.encode(Account, std.testing.allocator, .{ .tags = list });
}

test "compile error: fields and operators in one literal" {
    _ = try filter.encode(User, std.testing.allocator, .{ .profile = .{ .city = "x", .exists = true } });
}

/// A model with a struct whose field is named like an operator.
const Box = struct {
    id: ?bson.ObjectId = null,
    inner: Inner,

    pub const Inner = struct { size: u32 };
    pub const odm_schema: odm.Schema(Box) = .{ .collection = "boxes", .id = .id };
};

test "compile error: a key that is a field and an operator" {
    _ = try filter.encode(Box, std.testing.allocator, .{ .inner = .{ .size = 1 } });
}

test "compile error: an empty literal on a struct" {
    _ = try filter.encode(User, std.testing.allocator, .{ .profile = .{} });
}

// Find options, sorts and projections, through query/options.zig.

test "compile error: an option that find does not have" {
    _ = try options.find(User, .find, std.testing.allocator, .{ .limt = 1 });
}

test "compile error: a limit of findOne" {
    _ = try options.find(User, .findOne, std.testing.allocator, .{ .limit = 1 });
}

test "compile error: a limit that is a string" {
    _ = try options.find(User, .find, std.testing.allocator, .{ .limit = "x" });
}

test "compile error: a sort by a number" {
    _ = try options.find(User, .find, std.testing.allocator, .{ .sort = .{ .age = 1 } });
}

test "compile error: a sort by a field that is not there" {
    _ = try options.sort(User, std.testing.allocator, .{ .agee = .asc });
}

const NameTypo = struct { nmae: []const u8 };

test "compile error: a projection field that the model does not have" {
    _ = try options.projection(User, NameTypo, std.testing.allocator);
}

const WideAge = struct { age: i64 };

test "compile error: a projection field of another type" {
    _ = try options.projection(User, WideAge, std.testing.allocator);
}

const RequiredProfile = struct { profile: User.Profile };

test "compile error: a required projection field of an optional one" {
    _ = try options.projection(User, RequiredProfile, std.testing.allocator);
}

// The texts of query literals that the design's table leaves to odm: the
// shapes of filters, options, sorts and projections, the operands of not
// and elem_match, and the branches of the messages above.

test "compile error: a filter that is not a literal" {
    _ = try filter.encode(User, std.testing.allocator, 5);
}

test "compile error: not of a value" {
    _ = try filter.encode(User, std.testing.allocator, .{ .age = .{ .not = 5 } });
}

test "compile error: elem_match of a value" {
    _ = try filter.encode(Account, std.testing.allocator, .{ .tags = .{ .elem_match = "a" } });
}

test "compile error: a string literal that is not UTF-8" {
    _ = try filter.encode(User, std.testing.allocator, .{ .email = "\xff" });
}

test "compile error: in of a value that is not a list" {
    _ = try filter.encode(User, std.testing.allocator, .{ .age = .{ .in = 5 } });
}

test "compile error: an operator misspelled on a struct" {
    _ = try filter.encode(User, std.testing.allocator, .{ .profile = .{ .exsts = false } });
}

test "compile error: options that are not a literal" {
    _ = try options.find(User, .find, std.testing.allocator, 5);
}

test "compile error: a limit out of the range of u32" {
    _ = try options.find(User, .find, std.testing.allocator, .{ .limit = -1 });
}

test "compile error: a sort that is not a literal" {
    _ = try options.sort(User, std.testing.allocator, 5);
}

test "compile error: a sort by a tag that is not a direction" {
    _ = try options.sort(User, std.testing.allocator, .{ .age = .ascending });
}

test "compile error: a sort by a field that a nested struct does not have" {
    _ = try options.sort(User, std.testing.allocator, .{ .profile = .{ .ctiy = .asc } });
}

test "compile error: a projection that is not a struct" {
    _ = try options.projection(User, u32, std.testing.allocator);
}

const NestedTypo = struct { profile: ?struct { ctiy: []const u8 } };

test "compile error: a nested projection field that the model does not have" {
    _ = try options.projection(User, NestedTypo, std.testing.allocator);
}

// Updates: one case per row of the design's table "Updates", through the
// encoder of query/update.zig, on Account.

const some_id = bson.ObjectId.parseHex("652f8a1b9c0d4e5f60718293") catch unreachable;

test "compile error: inc of a string field" {
    _ = try update.encode(Account, std.testing.allocator, .{ .inc = .{ .email = 1 } }, .update);
}

test "compile error: inc of an integer by a fraction" {
    _ = try update.encode(Account, std.testing.allocator, .{ .inc = .{ .age = 1.5 } }, .update);
}

test "compile error: push to a string field" {
    _ = try update.encode(Account, std.testing.allocator, .{ .push = .{ .email = "x" } }, .update);
}

test "compile error: max of an enum" {
    _ = try update.encode(Account, std.testing.allocator, .{ .max = .{ .status = .active } }, .update);
}

test "compile error: set of a string to a number field" {
    _ = try update.encode(Account, std.testing.allocator, .{ .set = .{ .age = "x" } }, .update);
}

test "compile error: set of an optional to null" {
    _ = try update.encode(Account, std.testing.allocator, .{ .set = .{ .profile = null } }, .update);
}

test "compile error: set_on_insert of an optional to null" {
    _ = try update.encode(Account, std.testing.allocator, .{ .set_on_insert = .{ .profile = null } }, .upsert);
}

test "compile error: set of an optional field by an optional value" {
    var maybe: ?[]const u8 = "ann";
    _ = &maybe;
    _ = try update.encode(Account, std.testing.allocator, .{ .set = .{ .nickname = maybe } }, .update);
}

test "compile error: set of a path into an optional struct" {
    _ = try update.encode(Account, std.testing.allocator, .{ .set = .{ .profile = .{ .city = "Lyon" } } }, .update);
}

test "compile error: unset of a required field" {
    _ = try update.encode(Account, std.testing.allocator, .{ .unset = .{.email} }, .update);
}

test "compile error: set of the id" {
    _ = try update.encode(Account, std.testing.allocator, .{ .set = .{ .id = some_id } }, .update);
}

test "compile error: one field changed by two operators" {
    _ = try update.encode(Account, std.testing.allocator, .{ .set = .{ .age = 1 }, .inc = .{ .age = 1 } }, .update);
}

test "compile error: a struct and its field in one update" {
    const a: Address = .{ .city = "Lyon", .country = "FR" };
    _ = try update.encode(Account, std.testing.allocator, .{ .set = .{ .address = a }, .unset = .{.@"address.zip"} }, .update);
}

test "compile error: an unknown update operator" {
    _ = try update.encode(Account, std.testing.allocator, .{ .sett = .{ .age = 1 } }, .update);
}

test "compile error: an update that changes nothing" {
    _ = try update.encode(Account, std.testing.allocator, .{}, .update);
}

test "compile error: an empty operator of an update" {
    _ = try update.encode(Account, std.testing.allocator, .{ .set = .{} }, .update);
}

test "compile error: pop by a number" {
    _ = try update.encode(Account, std.testing.allocator, .{ .pop = .{ .tags = 1 } }, .update);
}

test "compile error: set_on_insert outside an upsert" {
    _ = try update.encode(Account, std.testing.allocator, .{ .set_on_insert = .{ .status = .active } }, .update);
}

// The texts of updates that the design's table leaves to odm: the shapes
// of an update, of its operators and of unset, paths through lists, empty
// literals, push without each, an inc beyond the BSON integer of its field,
// and set_on_insert of an optional value.

test "compile error: an update that is not a literal" {
    _ = try update.encode(Account, std.testing.allocator, 5, .update);
}

test "compile error: an operator that is not a literal" {
    _ = try update.encode(Account, std.testing.allocator, .{ .set = 5 }, .update);
}

test "compile error: unset of a value that is not a path" {
    _ = try update.encode(Account, std.testing.allocator, .{ .unset = .nickname }, .update);
}

test "compile error: unset of a path through a list" {
    _ = try update.encode(Account, std.testing.allocator, .{ .unset = .{.@"items.sku"} }, .update);
}

test "compile error: set of a path through a list" {
    _ = try update.encode(Account, std.testing.allocator, .{ .set = .{ .items = .{ .qty = 0 } } }, .update);
}

test "compile error: an empty literal in an update" {
    _ = try update.encode(Account, std.testing.allocator, .{ .set = .{ .address = .{} } }, .update);
}

test "compile error: push of a literal without each" {
    _ = try update.encode(Account, std.testing.allocator, .{ .push = .{ .tags = .{ .eac = .{"a"} } } }, .update);
}

test "compile error: inc beyond the BSON integer of its field" {
    _ = try update.encode(Account, std.testing.allocator, .{ .inc = .{ .visits = 1 << 63 } }, .update);
}

test "compile error: set_on_insert of an optional field by an optional value" {
    var maybe: ?[]const u8 = "ann";
    _ = &maybe;
    _ = try update.encode(Account, std.testing.allocator, .{ .set_on_insert = .{ .nickname = maybe } }, .upsert);
}

// The rules of upsertOne, through update.checkUpsert, which upsertOne
// calls with the types of its literals.

const some_time: bson.DateTime = .{ .milliseconds = 0 };

test "compile error: an upsert without required fields" {
    const email: []const u8 = "ann@example.com";
    comptime update.checkUpsert(Account, @TypeOf(.{ .email = email }), @TypeOf(.{
        .set = .{ .address = .{ .city = "Lyon" } },
        .set_on_insert = .{ .created_at = some_time },
        .inc = .{ .visits = 1 },
    }));
}

test "compile error: an upsert of Slug without its id" {
    comptime update.checkUpsert(Slug, @TypeOf(.{}), @TypeOf(.{ .set = .{ .title = "Ann" } }));
}

test "compile error: null in the filter of an upsert" {
    comptime update.checkUpsert(Account, @TypeOf(.{ .nickname = null }), @TypeOf(.{ .set = .{ .name = "Ann" } }));
}

test "compile error: an optional value in the filter of an upsert" {
    var maybe: ?[]const u8 = "ann";
    _ = &maybe;
    comptime update.checkUpsert(Account, @TypeOf(.{ .nickname = maybe }), @TypeOf(.{ .set = .{ .name = "Ann" } }));
}

test "compile error: an item of a list in the filter of an upsert" {
    comptime update.checkUpsert(Account, @TypeOf(.{ .tags = "admin" }), @TypeOf(.{ .set = .{ .name = "Ann" } }));
}

test "compile error: a path through a list in the filter of an upsert" {
    comptime update.checkUpsert(Account, @TypeOf(.{ .items = .{ .sku = "x" } }), @TypeOf(.{ .set = .{ .name = "Ann" } }));
}

test "compile error: or in the filter of an upsert" {
    comptime update.checkUpsert(Account, @TypeOf(.{ .@"or" = .{ .{ .email = "a" }, .{ .email = "b" } } }), @TypeOf(.{ .set = .{ .name = "Ann" } }));
}
