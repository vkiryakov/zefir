//! The check that every function of `redis.cmd` has a test of the
//! catalog. Zig analyzes a function only where something calls it, so a
//! function of the catalog that no test runs is checked by no one, its
//! errors of types included. Each test file of the catalog names the
//! functions it tests in its `covered`; the functions of `redis.cmd`, its
//! declarations in lower case, must be exactly the names of these lists
//! and of the functions that other tests run.

const std = @import("std");
const testing = std.testing;
const cmd = @import("../cmd.zig");

/// The `covered` lists of the test files of the catalog.
const catalog = [_][]const []const u8{
    &@import("strings_tests.zig").covered,
    &@import("keys_tests.zig").covered,
    &@import("hashes_tests.zig").covered,
    &@import("lists_tests.zig").covered,
    &@import("sets_tests.zig").covered,
    &@import("zsets_tests.zig").covered,
    &@import("scripting_tests.zig").covered,
};

/// The functions that other tests run: `raw` in raw_tests.zig and in the
/// tests of the client, `watch` and `unwatch` in tests/conn_tests.zig and
/// tests/transaction_tests.zig.
const elsewhere = [_][]const u8{ "raw", "watch", "unwatch" };

/// The lists of the check.
const lists = catalog ++ [_][]const []const u8{&elsewhere};

/// The functions of `redis.cmd`: its declarations in lower case.
const functions = collect: {
    var names: []const []const u8 = &.{};
    for (std.meta.declarations(cmd)) |name| {
        if (std.ascii.isLower(name[0])) names = names ++ &[_][]const u8{name};
    }
    break :collect names;
};

/// What breaks the rule: a function that no list names, or a name of a
/// list that is no function.
const Mismatch = union(enum) {
    untested: []const u8,
    unknown: []const u8,
};

/// The first function of `names` that none of `of` names, then the first
/// name of `of` that `names` lacks; null when they agree.
fn mismatch(names: []const []const u8, of: []const []const []const u8) ?Mismatch {
    for (names) |name| {
        if (!inAny(name, of)) return .{ .untested = name };
    }
    for (of) |list| for (list) |name| {
        if (!inList(name, names)) return .{ .unknown = name };
    };
    return null;
}

fn inAny(name: []const u8, of: []const []const []const u8) bool {
    for (of) |list| if (inList(name, list)) return true;
    return false;
}

fn inList(name: []const u8, list: []const []const u8) bool {
    for (list) |each| if (std.mem.eql(u8, each, name)) return true;
    return false;
}

test "every function of redis.cmd has a test of the catalog, and every name of a covered list is a function" {
    if (mismatch(functions, &lists)) |found| {
        switch (found) {
            .untested => |name| std.debug.print("redis.cmd.{s} has no test of the catalog: test it, and name it in the covered list of its file\n", .{name}),
            .unknown => |name| std.debug.print("a covered list names {s}, which redis.cmd lacks\n", .{name}),
        }
        return error.TestUnexpectedResult;
    }
    try testing.expect(functions.len > 50);
}

test "a function taken out of its list fails the check, which names it; so does a name that is no function" {
    var without: [catalog[0].len - 1][]const u8 = undefined;
    var n: usize = 0;
    for (catalog[0]) |name| {
        if (std.mem.eql(u8, name, "get")) continue;
        if (n == without.len) return error.TestUnexpectedResult;
        without[n] = name;
        n += 1;
    }
    var shorter = lists;
    shorter[0] = &without;
    try testing.expectEqualDeep(@as(?Mismatch, .{ .untested = "get" }), mismatch(functions, &shorter));
    const extra: []const []const u8 = &.{"getall"};
    try testing.expectEqualDeep(@as(?Mismatch, .{ .unknown = "getall" }), mismatch(functions, &(lists ++ [_][]const []const u8{extra})));
}
