//! The collection API of zefir-mongo on minidriver against a live mongod:
//! the scenarios that the end-to-end tests of zefir run on every driver,
//! taken from tests/mongo of this checkout. Without
//! `-Dlive-uri` the test is skipped.

const std = @import("std");
const mongo = @import("zefir-mongo");
const minidriver = @import("mongo-minidriver");
const build_options = @import("build_options");
const crud_scenarios = @import("crud-scenarios");

test "the collection API on minidriver against the live mongod" {
    const uri = build_options.live_uri orelse return error.SkipZigTest;
    const io = std.testing.io;
    var driver: minidriver.Client = try .init(std.testing.allocator, io, .{ .uri = uri });
    defer driver.deinit();
    try driver.connect(io, .root);
    var ids: mongo.bson.ObjectId.Generator = .init(io);
    try crud_scenarios.runAll(io, .init(driver.client(), "zefir_minidriver", &ids));
}
