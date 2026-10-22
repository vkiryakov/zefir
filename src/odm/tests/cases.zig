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
/// Why upsertOne refuses in, nin and all on the fields of its filter.
const list_conditions = "in, nin and all stay out of the filter of an upsert, since the server copies one item of in or all into the document it may insert, an item where a list goes too, and with no item it inserts none of the filter's equalities; match by equality, or use updateOne, then insertOne when it matched nothing";

pub const compile_errors = [_]Case{
    // The approved cases of the sketch, through the public API, as an
    // application writes them.
    .{ .name = "compile error: users.find on a field that is not there", .expect = "odm: tests.compile_errors.User has no field 'agee'; did you mean 'age'?" },
    .{ .name = "compile error: users.updateOne with inc of a string field", .expect = "odm: inc needs a number; tests.compile_errors.User.email is []const u8" },
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
    // The harness of odm.testing.conformance.run.
    .{ .name = "compile error: a harness by value", .expect = "odm.testing.conformance.run: pass a pointer to the harness, e.g. &harness; got tests.compile_errors.SomeHarness" },
    .{ .name = "compile error: a constant harness", .expect = "odm.testing.conformance.run: the harness must be mutable, declared with var; got *const tests.compile_errors.SomeHarness" },
    .{ .name = "compile error: a harness without setUp", .expect = "odm.testing.conformance.run: tests.compile_errors.NoSetUp has no method setUp; expected pub fn setUp(self: *@This(), io: std.Io, gpa: std.mem.Allocator) !odm.testing.conformance.Setup" },
    .{ .name = "compile error: a harness without tearDown", .expect = "odm.testing.conformance.run: tests.compile_errors.NoTearDown has no method tearDown; expected pub fn tearDown(self: *@This(), io: std.Io, setup: odm.testing.conformance.Setup) void" },
    .{ .name = "compile error: a hook of the harness of another signature", .expect = "odm.testing.conformance.run: tests.compile_errors.OtherStall.stall has another signature; expected pub fn stall(self: *@This(), io: std.Io, setup: odm.testing.conformance.Setup) !void" },
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
    // Names that a document cannot hold, at every level, and ids that the
    // server refuses.
    .{ .name = "compile error: a field whose name repeats a path", .expect = "odm: tests.compile_errors.DottedTwin: the field 'profile.city' holds '.', which odm reads as a step of a path; rename the field" },
    .{ .name = "compile error: a field whose name holds a dot", .expect = "odm: tests.compile_errors.Dotted: the field 'user.name' holds '.', which odm reads as a step of a path; rename the field" },
    .{ .name = "compile error: a field whose name starts with a dollar", .expect = "odm: tests.compile_errors.DollarField.$weird: the name \"$weird\" starts with '$', which MongoDB reads as an operator; rename the field, or give it a BSON name with odm_schema.names" },
    .{ .name = "compile error: a field of a struct in a list whose name starts with a dollar", .expect = "odm: tests.compile_errors.DollarInside.filter[].$ne: the name \"$ne\" starts with '$', which MongoDB reads as an operator; rename the field" },
    .{ .name = "compile error: a BSON name that is not UTF-8", .expect = "odm: tests.compile_errors.BinaryName.odm_schema.names.name: the name is not UTF-8" },
    .{ .name = "compile error: an id that is an array of bytes", .expect = "odm: tests.compile_errors.UuidId.id is the id of the model and is [16]u8: MongoDB takes no array or regular expression as _id; for bytes, such as a UUID, use bson.Binary" },
    .{ .name = "compile error: an id that is a regular expression", .expect = "odm: tests.compile_errors.RegexId.id is the id of the model and is types.Regex: MongoDB takes no array or regular expression as _id; for bytes, such as a UUID, use bson.Binary" },
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
    // Lists of the values that a filter writes under $eq, and $ne, which
    // takes no regular expression.
    .{ .name = "compile error: in over a list of documents", .expect = "odm: in does not apply to tests.compile_errors.Event.parts, which is []const RawDocument: its items would read as operators or patterns, not as values; match each item by equality in .@\"or\"" },
    .{ .name = "compile error: all over a list of values of any type", .expect = "odm: all does not apply to tests.compile_errors.Event.values, which is []const value.Value: its items would read as operators or patterns, not as values; match each item by equality in .@\"or\"" },
    .{ .name = "compile error: ne of a regular expression", .expect = "odm: ne does not apply to tests.compile_errors.Event.re, which is types.Regex: MongoDB takes no regular expression in $ne; put the equality in .nor instead" },
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
    // Updates.
    .{ .name = "compile error: inc of a string field", .expect = "odm: inc needs a number; tests.compile_errors.Account.email is []const u8" },
    .{ .name = "compile error: inc of an integer by a fraction", .expect = "odm: inc of tests.compile_errors.Account.age needs an integer: tests.compile_errors.Account.age is u32" },
    .{ .name = "compile error: push to a string field", .expect = "odm: push needs a list; tests.compile_errors.Account.email is []const u8" },
    .{ .name = "compile error: max of an enum", .expect = "odm: max needs a number, a string, a bson.DateTime or a bson.ObjectId; tests.compile_errors.Account.status is tests.compile_errors.User.Status" },
    .{ .name = "compile error: set of a string to a number field", .expect = "odm: set of tests.compile_errors.Account.age needs a u32; got *const [1:0]u8" },
    .{ .name = "compile error: set of an optional to null", .expect = "odm: set of tests.compile_errors.Account.profile to null: odm does not store null; clear the field with .unset = .{.profile}" },
    .{ .name = "compile error: set_on_insert of an optional to null", .expect = "odm: set_on_insert of tests.compile_errors.Account.profile to null: odm does not store null; leave the field out" },
    .{ .name = "compile error: set of an optional field by an optional value", .expect = "odm: set of tests.compile_errors.Account.nickname needs a []const u8; got ?[]const u8: odm does not store null, so set the field when the value is there, and unset it when it is not" },
    .{ .name = "compile error: set of a path into an optional struct", .expect = "odm: set of tests.compile_errors.Account.profile.city goes into tests.compile_errors.Account.profile, which is optional: in a document without profile it would create an incomplete tests.compile_errors.User.Profile; set the whole tests.compile_errors.User.Profile, .{ .set = .{ .profile = value } }, or unset profile" },
    .{ .name = "compile error: unset of a required field", .expect = "odm: unset would leave tests.compile_errors.Account.email without a value: it is not optional and has no default" },
    .{ .name = "compile error: set of the id", .expect = "odm: tests.compile_errors.Account.id is the _id of the document, which an update cannot change" },
    .{ .name = "compile error: one field changed by two operators", .expect = "odm: the update changes tests.compile_errors.Account.age twice: in set and in inc" },
    .{ .name = "compile error: a struct and its field in one update", .expect = "odm: the update changes tests.compile_errors.Account.address and tests.compile_errors.Account.address.zip, which overlap" },
    .{ .name = "compile error: an unknown update operator", .expect = "odm: unknown update operator 'sett'; did you mean 'set'?" },
    .{ .name = "compile error: an update that changes nothing", .expect = "odm: the update of tests.compile_errors.Account changes nothing" },
    .{ .name = "compile error: an empty operator of an update", .expect = "odm: set in the update of tests.compile_errors.Account is empty" },
    .{ .name = "compile error: pop by a number", .expect = "odm: pop takes .first or .last; got comptime_int" },
    .{ .name = "compile error: set_on_insert outside an upsert", .expect = "odm: set_on_insert works only in upsertOne" },
    // The texts of updates beyond the design's table.
    .{ .name = "compile error: an update that is not a literal", .expect = "odm: an update of tests.compile_errors.Account is a literal of operators, such as .{ .set = .{ .name = value } }; got comptime_int" },
    .{ .name = "compile error: an operator that is not a literal", .expect = "odm: set takes a literal of the fields of tests.compile_errors.Account; got comptime_int" },
    .{ .name = "compile error: unset of a value that is not a path", .expect = "odm: unset takes a tuple of paths of tests.compile_errors.Account, such as .{ .a, .@\"b.c\" }; got @EnumLiteral()" },
    .{ .name = "compile error: unset of a path through a list", .expect = "odm: unset of tests.compile_errors.Account.items.sku goes through the list tests.compile_errors.Account.items: an update sets a whole list, or changes its items with push, add_to_set, pull or pop" },
    .{ .name = "compile error: set of a path through a list", .expect = "odm: set of tests.compile_errors.Account.items.qty goes through the list tests.compile_errors.Account.items: an update sets a whole list, or changes its items with push, add_to_set, pull or pop" },
    .{ .name = "compile error: an empty literal in an update", .expect = "odm: set of tests.compile_errors.Account.address: an empty literal changes nothing here; drop it" },
    .{ .name = "compile error: push of a literal without each", .expect = "odm: push of tests.compile_errors.Account.tags takes an item of the list, or .{ .each = items } for several" },
    .{ .name = "compile error: inc beyond the BSON integer of its field", .expect = "odm: inc of tests.compile_errors.Account.visits needs an integer that fits i64, the BSON integer of u32; got 9223372036854775808" },
    .{ .name = "compile error: set_on_insert of an optional field by an optional value", .expect = "odm: set_on_insert of tests.compile_errors.Account.nickname needs a []const u8; got ?[]const u8: odm does not store null, so set the field when the value is there, and leave it out when it is not" },
    // The operators of lists on an array of a fixed length, which they
    // would make longer or shorter: a document that the model cannot read.
    .{ .name = "compile error: push to an array of a fixed length", .expect = "odm: push of tests.compile_errors.Color.rgb: [3]u8 has a fixed length, and push changes it; set the whole array with .set" },
    .{ .name = "compile error: add_to_set to an array of a fixed length", .expect = "odm: add_to_set of tests.compile_errors.Color.rgb: [3]u8 has a fixed length, and add_to_set changes it; set the whole array with .set" },
    .{ .name = "compile error: pull from an array of a fixed length", .expect = "odm: pull of tests.compile_errors.Color.rgb: [3]u8 has a fixed length, and pull changes it; set the whole array with .set" },
    .{ .name = "compile error: pop of an array of a fixed length", .expect = "odm: pop of tests.compile_errors.Color.rgb: [3]u8 has a fixed length, and pop changes it; set the whole array with .set" },
    .{ .name = "compile error: an upsert that pushes to an array of a fixed length", .expect = "odm: push of tests.compile_errors.Color.rgb: [3]u8 has a fixed length, and push changes it; set the whole array with .set" },
    // The rules of upsertOne.
    .{ .name = "compile error: an upsert without required fields", .expect = "odm: upsertOne of tests.compile_errors.Account may insert a document without its required fields 'name', 'address.country': give each by equality in the filter, in set, in set_on_insert, or with an operator that creates it, such as inc or push" },
    .{ .name = "compile error: an upsert of Slug without its id", .expect = "odm: upsertOne of tests.compile_errors.Slug may insert a document without its id 'id', which is []const u8: give it by equality in the filter or in set_on_insert" },
    .{ .name = "compile error: null in the filter of an upsert", .expect = "odm: upsertOne of tests.compile_errors.Account: the filter's tests.compile_errors.Account.nickname = null would go into the document it may insert, and odm does not store null; match a missing field with .{ .nickname = .{ .exists = false } }" },
    .{ .name = "compile error: an optional value in the filter of an upsert", .expect = "odm: upsertOne of tests.compile_errors.Account: the filter's equality on tests.compile_errors.Account.nickname needs a []const u8; got ?[]const u8: it goes into the document the upsert may insert, and odm does not store null" },
    .{ .name = "compile error: an item of a list in the filter of an upsert", .expect = "odm: upsertOne of tests.compile_errors.Account: the filter's tests.compile_errors.Account.tags = item would put the item where the list goes in the document it may insert; match the whole list with .eq, or the item with .elem_match" },
    .{ .name = "compile error: a path through a list in the filter of an upsert", .expect = "odm: upsertOne of tests.compile_errors.Account: the filter's path items.sku goes through the list tests.compile_errors.Account.items, and the document it may insert would get a document there, not a list; use .elem_match" },
    .{ .name = "compile error: an upsert that gives its id by paths", .expect = "odm: upsertOne of tests.compile_errors.Pair gives its id 'id' by paths into it: give the whole tests.compile_errors.Pair.Key by equality in the filter or in set_on_insert" },
    .{ .name = "compile error: or in the filter of an upsert", .expect = "odm: upsertOne of tests.compile_errors.Account: or in the filter: the server takes equalities from it into the document it may insert, and odm checks only the fields of the filter itself; put the conditions in the fields of the filter" },
    .{ .name = "compile error: in in the filter of an upsert", .expect = "odm: upsertOne of tests.compile_errors.Account: the filter's in on tests.compile_errors.Account.status: " ++ list_conditions },
    .{ .name = "compile error: nin in the filter of an upsert", .expect = "odm: upsertOne of tests.compile_errors.Account: the filter's nin on tests.compile_errors.Account.age: " ++ list_conditions },
    .{ .name = "compile error: all in the filter of an upsert", .expect = "odm: upsertOne of tests.compile_errors.Account: the filter's all on tests.compile_errors.Account.tags: " ++ list_conditions },
    .{ .name = "compile error: an optional list in the filter of an upsert", .expect = "odm: upsertOne of tests.compile_errors.Account: the filter's equality on tests.compile_errors.Account.labels needs a []const []const u8; got ?[]const []const u8: it goes into the document the upsert may insert, and odm does not store null" },
    // odm.Filter and odm.Update.
    .{ .name = "compile error: a filter of another model", .expect = "odm: this filter is an odm.Filter(tests.compile_errors.Account), not of tests.compile_errors.User" },
    .{ .name = "compile error: an upsert with an odm.Filter", .expect = "odm: upsertOne of tests.compile_errors.Account takes a filter literal, not an odm.Filter(tests.compile_errors.Account): it checks at compile time that the document it may insert gets every required field" },
    .{ .name = "compile error: an upsert with an odm.Update", .expect = "odm: upsertOne of tests.compile_errors.Account takes an update literal, not an odm.Update(tests.compile_errors.Account): it checks at compile time that the document it may insert gets every required field" },
    .{ .name = "compile error: an update of another model", .expect = "odm: this update is an odm.Update(tests.compile_errors.User), not of tests.compile_errors.Account" },
    // Collections.
    .{ .name = "compile error: a pipeline that is not a list", .expect = "odm: the pipeline of aggregateRaw is a tuple, a slice or an array of documents; got comptime_int" },
} ++ guide_checks;

/// A compile error that the guide, src/odm/examples/README.md, shows: its
/// text as README.md prints it after "error: ", with the names of the
/// guide, `models.User` and `my_driver.Client`, and the namespace of
/// tests/compile_errors.zig whose fixtures of those names give it there.
/// readme_test.zig of the guide checks that README.md shows each text.
pub const GuideError = struct { name: []const u8, fixtures: []const u8, text: []const u8 };

pub const guide_errors = [_]GuideError{
    .{ .name = "compile error: guide: a field of f32", .fixtures = "guide_f32", .text = "odm: models.User.rating is f32: a BSON double has 64 bits, and decoding one into f32 rounds it; use f64" },
    .{ .name = "compile error: guide: an optional whose default is not null", .fixtures = "guide_default", .text = "odm: models.User.nickname is optional, and its default is not null: odm leaves a null optional out of the document, and a field that is not there reads back as its default; make the default null" },
    .{ .name = "compile error: guide: a unique index on an optional without sparse", .fixtures = "guide_unique", .text = "odm: models.User.odm_schema.indexes[1] is unique on models.User.nickname, which is optional: odm leaves null out, and the documents without the field would collide in the index as null; add .sparse = true" },
    .{ .name = "compile error: guide: a filter on a field that is not there", .fixtures = "guide", .text = "odm: models.User has no field 'agee'; did you mean 'age'?" },
    .{ .name = "compile error: guide: a string where a number goes", .fixtures = "guide", .text = "odm: gte on models.User.age needs a u32; got *const [2:0]u8" },
    .{ .name = "compile error: guide: a tag that the enum does not have", .fixtures = "guide", .text = "odm: models.User.status is models.User.Status, which has no tag 'actve'; did you mean 'active'?" },
    .{ .name = "compile error: guide: an option that find does not have", .fixtures = "guide", .text = "odm: find has no option 'limt'; did you mean 'limit'?" },
    .{ .name = "compile error: guide: a document without eq", .fixtures = "guide", .text = "odm: models.User.address is a document: match its fields, .{ .address = .{ .city = ... } }, or the whole document with .{ .eq = value }" },
    .{ .name = "compile error: guide: set of an optional to null", .fixtures = "guide", .text = "odm: set of models.User.nickname to null: odm does not store null; clear the field with .unset = .{.nickname}" },
    .{ .name = "compile error: guide: set of a path into an optional struct", .fixtures = "guide", .text = "odm: set of models.User.profile.site goes into models.User.profile, which is optional: in a document without profile it would create an incomplete models.User.Profile; set the whole models.User.Profile, .{ .set = .{ .profile = value } }, or unset profile" },
    .{ .name = "compile error: guide: one list changed twice", .fixtures = "guide", .text = "odm: the update changes models.User.tags twice: in push and in pull" },
    .{ .name = "compile error: guide: an upsert without required fields", .fixtures = "guide", .text = "odm: upsertOne of models.User may insert a document without its required fields 'address', 'created_at': give each by equality in the filter, in set, in set_on_insert, or with an operator that creates it, such as inc or push" },
    .{ .name = "compile error: guide: in in the filter of an upsert", .fixtures = "guide", .text = "odm: upsertOne of models.User: the filter's in on models.User.status: in, nin and all stay out of the filter of an upsert, since the server copies one item of in or all into the document it may insert, an item where a list goes too, and with no item it inserts none of the filter's equalities; match by equality, or use updateOne, then insertOne when it matched nothing" },
    .{ .name = "compile error: guide: a client without insert", .fixtures = "guide", .text = "odm.Client.init: my_driver.Client has no method insert; expected pub fn insert(self: *@This(), io: std.Io, ctx: core.Context, request: *const odm.Client.InsertRequest, options: odm.Client.CallOptions) odm.DriverError!odm.Client.InsertResult" },
};

/// The compile checks of `guide_errors`: each text with the names of its
/// fixtures, as the compiler prints them in tests/compile_errors.zig.
const guide_checks = checks: {
    var out: [guide_errors.len]Case = undefined;
    for (guide_errors, &out) |e, *check| check.* = .{ .name = e.name, .expect = fixtureText(e) };
    break :checks out;
};

/// `e.text` with "tests.compile_errors.<fixtures>." before each name of the
/// guide.
fn fixtureText(comptime e: GuideError) []const u8 {
    @setEvalBranchQuota(100_000);
    const prefix = "tests.compile_errors." ++ e.fixtures ++ ".";
    var out: []const u8 = "";
    var i: usize = 0;
    while (i < e.text.len) : (i += 1) {
        for ([_][]const u8{ "models.User", "my_driver.Client" }) |name| {
            if (e.text.len - i >= name.len and eql(e.text[i..][0..name.len], name)) out = out ++ prefix;
        }
        out = out ++ e.text[i..][0..1];
    }
    return out;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}
