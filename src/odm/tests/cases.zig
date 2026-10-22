//! The compile checks of zefir-odm, read by `addOdmCompileChecks` in
//! build.zig. Each case compiles the test of tests/compile_errors.zig
//! whose name holds `name`, and passes only when the build fails with
//! the error `expect`: the whole message after "error: ". A type that
//! tests/compile_errors.zig declares is named `tests.compile_errors.X`.
//!
//! Every name starts with "compile error: ", which no other test of the
//! module holds: the filter of a case matches any test whose name holds
//! it, and the module of the checks holds the tests of odm too.

/// One compile check: the test it compiles and the error it must fail with.
pub const Case = struct { name: []const u8, expect: []const u8 };

const insert = "pub fn insert(self: *@This(), io: std.Io, ctx: core.Context, request: *const odm.Client.InsertRequest, options: odm.Client.CallOptions) odm.DriverError!odm.Client.InsertResult";
const aggregate = "pub fn aggregate(self: *@This(), io: std.Io, ctx: core.Context, request: *const odm.Client.AggregateRequest, options: odm.Client.CallOptions) odm.DriverError!odm.RawCursor";
const open = "pub fn open(self: *@This(), io: std.Io, config: *const odm.ConnectionConfig) odm.Driver.OpenError!odm.Client";
const next = "pub fn next(self: *@This(), io: std.Io, ctx: core.Context, d: ?*odm.Diagnostics) odm.DriverError!?bson.RawDocument";

pub const compile_errors = [_]Case{
    // The driver contract: odm.Client.init.
    .{ .name = "compile error: a client without insert", .expect = "odm.Client.init: tests.compile_errors.NoInsert has no method insert; expected " ++ insert },
    .{ .name = "compile error: insert of another signature", .expect = "odm.Client.init: tests.compile_errors.OtherInsert.insert has another signature; expected " ++ insert },
    .{ .name = "compile error: aggregate in the capabilities, without the method", .expect = "odm.Client.init: tests.compile_errors.NoAggregate.capabilities.aggregate is true, but tests.compile_errors.NoAggregate has no method aggregate; expected " ++ aggregate },
    .{ .name = "compile error: the method count, without the capability", .expect = "odm.Client.init: tests.compile_errors.HiddenCount has a method count, but capabilities.count is false" },
    .{ .name = "compile error: Client.init of a client by value", .expect = "odm.Client.init: pass a pointer to the client, e.g. &client; got tests.compile_errors.SomeClient" },
    .{ .name = "compile error: Client.init of a constant client", .expect = "odm.Client.init: the client must be mutable, declared with var; got *const tests.compile_errors.SomeClient" },
    .{ .name = "compile error: a client without capabilities", .expect = "odm.Client.init: tests.compile_errors.NoCapabilities has no pub const capabilities: odm.Capabilities" },
    // odm.Driver.init and odm.RawCursor.init.
    .{ .name = "compile error: a driver without a name", .expect = "odm.Driver.init: tests.compile_errors.NamelessDriver has no pub const name: []const u8" },
    .{ .name = "compile error: a driver without open", .expect = "odm.Driver.init: tests.compile_errors.DriverWithoutOpen has no method open; expected " ++ open },
    .{ .name = "compile error: a cursor without next", .expect = "odm.RawCursor.init: tests.compile_errors.CursorWithoutNext has no method next; expected " ++ next },
    // The checks of a model: odm.assertModel.
    .{ .name = "compile error: assertModel of an integer", .expect = "odm: u32 is not a model: a model is a struct with named fields" },
    .{ .name = "compile error: assertModel of a tuple", .expect = "odm: struct { u32, u8 } is not a model: a model is a struct with named fields" },
    .{ .name = "compile error: a model without odm_schema", .expect = "odm: tests.compile_errors.NoSchema has no pub const odm_schema; declare pub const odm_schema: odm.Schema(tests.compile_errors.NoSchema) = .{ .collection = \"...\", .id = .id };" },
    .{ .name = "compile error: odm_schema of another type", .expect = "odm: tests.compile_errors.SchemaOfAnotherType.odm_schema must be an odm.Schema(tests.compile_errors.SchemaOfAnotherType); got u32" },
    .{ .name = "compile error: an empty collection name", .expect = "odm: tests.compile_errors.NoCollection.odm_schema.collection is empty" },
    .{ .name = "compile error: a collection name with a dollar", .expect = "odm: tests.compile_errors.DollarCollection.odm_schema.collection holds '$' or NUL" },
    .{ .name = "compile error: a collection of the system", .expect = "odm: tests.compile_errors.SystemCollection.odm_schema.collection starts with \"system.\"" },
    .{ .name = "compile error: a collection name of 192 bytes", .expect = "odm: tests.compile_errors.LongCollection.odm_schema.collection is longer than 191 bytes" },
    .{ .name = "compile error: a collection name that is not UTF-8", .expect = "odm: tests.compile_errors.BinaryCollection.odm_schema.collection is not UTF-8" },
    .{ .name = "compile error: an optional id that is not an ObjectId", .expect = "odm: tests.compile_errors.OptionalSlug.id is the id of the model and is ?[]const u8: an id is bson.ObjectId, ?bson.ObjectId, or a value of another type that you give on insert and that is not optional" },
    .{ .name = "compile error: a field _id that is not the id", .expect = "odm: tests.compile_errors.StrayId._id is not the id of the model: set odm_schema.id = ._id, or rename the field" },
    .{ .name = "compile error: a BSON name for the id", .expect = "odm: tests.compile_errors.NamedId.odm_schema.names.id: the id of the model is always _id in the database; drop this name" },
    .{ .name = "compile error: an empty BSON name", .expect = "odm: tests.compile_errors.EmptyName.odm_schema.names.name: \"\" is not a field name of a document: it is empty, starts with '$', or holds '.' or NUL" },
    .{ .name = "compile error: a BSON name that starts with a dollar", .expect = "odm: tests.compile_errors.DollarName.odm_schema.names.name: \"$a\" is not a field name of a document: it is empty, starts with '$', or holds '.' or NUL" },
    .{ .name = "compile error: a BSON name with a dot", .expect = "odm: tests.compile_errors.DottedName.odm_schema.names.name: \"a.b\" is not a field name of a document: it is empty, starts with '$', or holds '.' or NUL" },
    .{ .name = "compile error: two fields under one BSON name", .expect = "odm: tests.compile_errors.TwinNames: the fields 'a' and 'b' both have the BSON name \"a\"" },
    .{ .name = "compile error: a field named as a logical operator", .expect = "odm: tests.compile_errors.Operator.or: and, or and nor are the logical operators of filters; rename the field and keep its BSON name with odm_schema.names" },
    .{ .name = "compile error: a field of u64", .expect = "odm: tests.compile_errors.Unsigned: field 'n' is u64, which BSON has no type for: its integers are signed; use i64" },
    .{ .name = "compile error: a field of f32", .expect = "odm: tests.compile_errors.Narrow.x is f32: a BSON double has 64 bits, and decoding one into f32 rounds it; use f64" },
    .{ .name = "compile error: an f32 in the items of a list", .expect = "odm: tests.compile_errors.NarrowItems.items[].x is f32: a BSON double has 64 bits, and decoding one into f32 rounds it; use f64" },
    .{ .name = "compile error: an optional whose default is not null", .expect = "odm: tests.compile_errors.OptionalDefault.n is optional, and its default is not null: odm leaves a null optional out of the document, and a field that is not there reads back as its default; make the default null" },
    .{ .name = "compile error: an optional default inside a subdocument", .expect = "odm: tests.compile_errors.NestedDefault.inner.n is optional, and its default is not null: odm leaves a null optional out of the document, and a field that is not there reads back as its default; make the default null" },
    .{ .name = "compile error: an index without keys", .expect = "odm: tests.compile_errors.NoKeys.odm_schema.indexes[0] has no keys" },
    .{ .name = "compile error: an index with one key twice", .expect = "odm: tests.compile_errors.KeyTwice.odm_schema.indexes[0]: the key 'email' comes twice" },
    .{ .name = "compile error: a text key on a number", .expect = "odm: tests.compile_errors.TextNumber.odm_schema.indexes[0]: a text key needs a string field; tests.compile_errors.TextNumber.age is u32" },
    .{ .name = "compile error: a TTL on a string", .expect = "odm: tests.compile_errors.TtlString.odm_schema.indexes[0]: expire_after_seconds needs one key on a bson.DateTime field" },
    .{ .name = "compile error: two indexes with the same keys", .expect = "odm: tests.compile_errors.SameIndexes.odm_schema.indexes[0] and [1] have the same keys" },
    .{ .name = "compile error: a unique index on an optional path without sparse", .expect = "odm: tests.compile_errors.UniqueOptional.odm_schema.indexes[0] is unique on tests.compile_errors.UniqueOptional.profile.city, which is optional: odm leaves null out, and the documents without the field would collide in the index as null; add .sparse = true" },
    .{ .name = "compile error: field_rules of a field that is not there", .expect = "validator: tests.compile_errors.Typo.field_rules.nmae: no such field; did you mean \"name\"?" },
    // Filters.
    .{ .name = "compile error: a filter on a field that is not there", .expect = "odm: tests.compile_errors.User has no field 'agee'; did you mean 'age'?" },
    .{ .name = "compile error: an unknown filter operator", .expect = "odm: unknown filter operator 'gtee' on tests.compile_errors.User.age; did you mean 'gte'?" },
    .{ .name = "compile error: regex on a number", .expect = "odm: regex does not apply to tests.compile_errors.User.age, which is u32" },
    .{ .name = "compile error: size on a string", .expect = "odm: size does not apply to tests.compile_errors.User.email, which is []const u8" },
    .{ .name = "compile error: a string where a number goes", .expect = "odm: gte on tests.compile_errors.User.age needs a u32; got *const [2:0]u8" },
    .{ .name = "compile error: a number out of the range of its field", .expect = "odm: tests.compile_errors.User.age is u32, and -1 is out of its range" },
    .{ .name = "compile error: a tag that the enum does not have", .expect = "odm: tests.compile_errors.User.status is tests.compile_errors.User.Status, which has no tag 'actve'; did you mean 'active'?" },
    .{ .name = "compile error: null on a required field", .expect = "odm: tests.compile_errors.User.email is not optional: null matches no document" },
    .{ .name = "compile error: or of a number", .expect = "odm: or takes a tuple of filters of tests.compile_errors.User, such as .{ .{ .a = 1 }, .{ .b = 2 } }, or a []const odm.Filter(tests.compile_errors.User); got comptime_int" },
    .{ .name = "compile error: and of no filters", .expect = "odm: and needs at least one filter" },
    // Filters on documents and lists.
    .{ .name = "compile error: a field that a nested struct does not have", .expect = "odm: tests.compile_errors.User.profile has no field 'ctiy'; did you mean 'city'?" },
    .{ .name = "compile error: a document without eq", .expect = "odm: tests.compile_errors.User.profile is a document: match its fields, .{ .profile = .{ .city = ... } }, or the whole document with .{ .eq = value }" },
    .{ .name = "compile error: a list as the value of a list", .expect = "odm: tests.compile_errors.Account.tags is a list: match an item with an item, all items with .all, the whole list with .eq" },
    .{ .name = "compile error: fields and operators in one literal", .expect = "odm: tests.compile_errors.User.profile: write either fields of tests.compile_errors.User.Profile or operators in one literal, not both" },
    .{ .name = "compile error: a key that is a field and an operator", .expect = "odm: tests.compile_errors.Box.inner: 'size' is both a field of tests.compile_errors.Box.Inner and an operator: rename the field" },
    .{ .name = "compile error: an empty literal on a struct", .expect = "odm: tests.compile_errors.User.profile: an empty literal matches nothing here; drop it" },
    // Find options, sorts and projections.
    .{ .name = "compile error: an option that find does not have", .expect = "odm: find has no option 'limt'; did you mean 'limit'?" },
    .{ .name = "compile error: a limit of findOne", .expect = "odm: findOne has no option 'limit'" },
    .{ .name = "compile error: a limit that is a string", .expect = "odm: limit is a u32; got *const [1:0]u8" },
    .{ .name = "compile error: a sort by a number", .expect = "odm: sort of tests.compile_errors.User.age takes .asc or .desc; got comptime_int" },
    .{ .name = "compile error: a sort by a field that is not there", .expect = "odm: tests.compile_errors.User has no field 'agee'; did you mean 'age'?" },
    .{ .name = "compile error: a projection field that the model does not have", .expect = "odm: tests.compile_errors.NameTypo.nmae is not a field of tests.compile_errors.User; did you mean 'name'?" },
    .{ .name = "compile error: a projection field of another type", .expect = "odm: tests.compile_errors.WideAge.age is i64, but tests.compile_errors.User.age is u32: a projection field has the type of the model's field or its optional" },
    .{ .name = "compile error: a required projection field of an optional one", .expect = "odm: tests.compile_errors.RequiredProfile.profile is required, but tests.compile_errors.User.profile is optional: make it ?tests.compile_errors.User.Profile" },
    // The texts of query literals beyond the design's table.
    .{ .name = "compile error: a filter that is not a literal", .expect = "odm: a filter of tests.compile_errors.User is a literal of its fields, or .{} for every document; got comptime_int" },
    .{ .name = "compile error: not of a value", .expect = "odm: not on tests.compile_errors.User.age takes a literal of operators, such as .{ .gt = 5 }, or a bson.Regex; got comptime_int" },
    .{ .name = "compile error: elem_match of a value", .expect = "odm: elem_match on tests.compile_errors.Account.tags takes a literal of conditions on the items of the list; got *const [1:0]u8" },
    .{ .name = "compile error: a string literal that is not UTF-8", .expect = "odm: tests.compile_errors.User.email is []const u8, and its value is not UTF-8" },
    .{ .name = "compile error: in of a value that is not a list", .expect = "odm: in on tests.compile_errors.User.age needs a []const u32; got comptime_int" },
    .{ .name = "compile error: an operator misspelled on a struct", .expect = "odm: unknown filter operator 'exsts' on tests.compile_errors.User.profile; did you mean 'exists'?" },
    .{ .name = "compile error: options that are not a literal", .expect = "odm: the options of find are a literal, such as .{ .skip = 10 }; got comptime_int" },
    .{ .name = "compile error: a limit out of the range of u32", .expect = "odm: limit is u32, and -1 is out of its range" },
    .{ .name = "compile error: a sort that is not a literal", .expect = "odm: a sort of tests.compile_errors.User is a literal of its fields with .asc or .desc; got comptime_int" },
    .{ .name = "compile error: a sort by a tag that is not a direction", .expect = "odm: sort of tests.compile_errors.User.age takes .asc or .desc; got .ascending" },
    .{ .name = "compile error: a sort by a field that a nested struct does not have", .expect = "odm: tests.compile_errors.User.profile has no field 'ctiy'; did you mean 'city'?" },
    .{ .name = "compile error: a projection that is not a struct", .expect = "odm: a projection of tests.compile_errors.User is a struct of fields of tests.compile_errors.User; got u32" },
    .{ .name = "compile error: a nested projection field that the model does not have", .expect = "odm: tests.compile_errors.NestedTypo.profile.ctiy is not a field of tests.compile_errors.User.profile; did you mean 'city'?" },
};
