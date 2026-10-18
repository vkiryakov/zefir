//! Tests of `mongo.testing.conformance`: `FakeDriver` passes every check of
//! layer S that it can take, and a driver that breaks a rule fails the
//! check of that rule.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const mongo = @import("../root.zig");
const bson = mongo.bson;
const conformance = mongo.testing.conformance;
const Script = mongo.testing.Script;
const FakeDriver = mongo.testing.FakeDriver;
const Check = conformance.Check;

/// `FakeDriver` on the script of each check.
const FakeHarness = struct {
    fake: FakeDriver = undefined,

    pub fn setUp(h: *FakeHarness, io: Io, gpa: std.mem.Allocator, target: conformance.Target) !mongo.Client {
        const script = switch (target) {
            .scripted => |s| s.script,
            .live => return error.NoLiveServer,
        };
        h.fake = .init(gpa, script);
        try h.fake.connect(io, .root);
        return h.fake.client();
    }

    pub fn close(h: *FakeHarness, io: Io) void {
        h.fake.close(io);
    }

    pub fn tearDown(h: *FakeHarness, io: Io) void {
        _ = io;
        h.fake.deinit();
    }
};

fn expectNoFailures(report: *const conformance.Report) !void {
    if (report.failedCount() == 0) return;
    std.debug.print("{f}", .{report});
    return error.TestUnexpectedResult;
}

/// Fails unless `check` failed with a message that holds `text`.
fn expectFailed(report: *const conformance.Report, check: Check, text: []const u8) !void {
    switch (report.outcome(check)) {
        .failed => |why| if (std.mem.find(u8, why, text) != null) return,
        else => {},
    }
    std.debug.print("expected {s} to fail with \"{s}\":\n{f}", .{ check.label(), text, report });
    return error.TestUnexpectedResult;
}

test "FakeDriver passes every check of layer S but S16, which is for drivers on the wire; L is skipped without a live mongod" {
    var harness: FakeHarness = .{};
    var report = try conformance.run(testing.io, testing.allocator, &harness, .{});
    defer report.deinit();
    try expectNoFailures(&report);
    try testing.expectEqualStrings("fake", report.driver_name);
    try testing.expectEqual(@as(usize, 8), report.passedCount());
    try testing.expectEqual(@as(usize, 0), report.skippedCount());
}

test "only runs the checks it names, and the report says why the others were skipped" {
    var harness: FakeHarness = .{};
    var report = try conformance.run(testing.io, testing.allocator, &harness, .{ .only = &.{} });
    defer report.deinit();
    try testing.expectEqual(@as(usize, 0), report.passedCount());
    try testing.expectEqualStrings("not in options.only", report.outcome(.s19).skipped);
}

/// A broken rule of a driver, for the tests of the suite itself.
const Flaw = enum {
    /// capabilities() declares sessions, which revision 1 reserves.
    claims_sessions,
    /// setUp takes memory that tearDown does not give back.
    leaks,
    /// runCommand adds a field of its own to the command.
    adds_field,
    /// runCommand takes the cancelation of its task that it reports as
    /// Interrupted, instead of leaving it to the task.
    swallows_cancel,
};

/// `FakeDriver` with one flaw: the harness and the driver in one object.
const Flawed = struct {
    flaw: Flaw,
    fake: FakeDriver = undefined,
    gpa: std.mem.Allocator = undefined,
    /// What `leaks` took, one block a setUp: the test frees it, from the
    /// allocator under the suite's.
    leaked: [4][]u8 = undefined,
    leaks: usize = 0,

    pub fn setUp(f: *Flawed, io: Io, gpa: std.mem.Allocator, target: conformance.Target) !mongo.Client {
        const script = switch (target) {
            .scripted => |s| s.script,
            .live => return error.NoLiveServer,
        };
        f.fake = .init(gpa, script);
        f.gpa = gpa;
        if (f.flaw == .leaks and f.leaks < f.leaked.len) {
            f.leaked[f.leaks] = try gpa.alloc(u8, 16);
            f.leaks += 1;
        }
        try f.fake.connect(io, .root);
        return .init(f);
    }

    pub fn close(f: *Flawed, io: Io) void {
        f.fake.close(io);
    }

    pub fn tearDown(f: *Flawed, io: Io) void {
        _ = io;
        f.fake.deinit();
    }

    fn freeLeaked(f: *Flawed) void {
        for (f.leaked[0..f.leaks]) |block| testing.allocator.free(block);
        f.leaks = 0;
    }

    pub fn runCommand(f: *Flawed, io: Io, op: mongo.OperationContext, command: *const mongo.Command, options: mongo.CommandOptions) mongo.Error!bson.OwnedDocument {
        switch (f.flaw) {
            .adds_field => {
                var b: bson.Builder = .init(f.gpa);
                defer b.deinit();
                var it = command.body.iterator();
                while (it.next() catch return error.InvalidArgument) |element| b.putValue(element.key, element.value) catch return error.OutOfMemory;
                b.putInt32("zefir", 1) catch return error.OutOfMemory;
                const body = b.finish() catch return error.OutOfMemory;
                defer body.deinit();
                return f.fake.runCommand(io, op, &.{ .database = command.database, .body = body.raw() }, options);
            },
            .swallows_cancel => return f.fake.runCommand(io, op, command, options) catch |err| {
                if (err == error.Interrupted) io.checkCancel() catch {};
                return err;
            },
            else => return f.fake.runCommand(io, op, command, options),
        }
    }

    pub fn openCursor(f: *Flawed, io: Io, op: mongo.OperationContext, command: *const mongo.Command, options: mongo.CursorOptions) mongo.Error!mongo.Cursor {
        return f.fake.openCursor(io, op, command, options);
    }

    pub fn write(f: *Flawed, io: Io, op: mongo.OperationContext, request: *const mongo.WriteRequest, options: mongo.WriteOptions) mongo.Error!mongo.WriteResult {
        return f.fake.write(io, op, request, options);
    }

    pub fn capabilities(f: *Flawed) mongo.Capabilities {
        var caps = f.fake.capabilities();
        if (f.flaw == .claims_sessions) caps.sessions = true;
        return caps;
    }
};

test "a driver that claims a reserved capability fails S19, which names it" {
    var flawed: Flawed = .{ .flaw = .claims_sessions };
    var report = try conformance.run(testing.io, testing.allocator, &flawed, .{ .only = &.{.s19} });
    defer report.deinit();
    try expectFailed(&report, .s19, "sessions");
}

test "a driver that adds a field to the command fails S1, which names the field" {
    var flawed: Flawed = .{ .flaw = .adds_field };
    var report = try conformance.run(testing.io, testing.allocator, &flawed, .{ .only = &.{.s1} });
    defer report.deinit();
    try expectFailed(&report, .s1, "'zefir'");
}

test "a driver that swallows the cancelation of its task fails S6" {
    var flawed: Flawed = .{ .flaw = .swallows_cancel };
    var report = try conformance.run(testing.io, testing.allocator, &flawed, .{ .only = &.{.s6} });
    defer report.deinit();
    try expectFailed(&report, .s6, "swallowed");
}

test "a driver that keeps memory after tearDown fails the check with a leak" {
    var flawed: Flawed = .{ .flaw = .leaks };
    defer flawed.freeLeaked();
    var report = try conformance.run(testing.io, testing.allocator, &flawed, .{ .only = &.{.s19} });
    defer report.deinit();
    try expectFailed(&report, .s19, "16 bytes in 1 allocation(s) were still held after harness.tearDown");
}

/// A harness whose setUp always fails.
const NoDriver = struct {
    pub fn setUp(h: *NoDriver, io: Io, gpa: std.mem.Allocator, target: conformance.Target) !mongo.Client {
        _ = h;
        _ = io;
        _ = gpa;
        _ = target;
        return error.NoDriverHere;
    }

    pub fn close(h: *NoDriver, io: Io) void {
        _ = h;
        _ = io;
    }

    pub fn tearDown(h: *NoDriver, io: Io) void {
        _ = h;
        _ = io;
    }
};

test "a setUp that fails fails every check with its error" {
    var harness: NoDriver = .{};
    var report = try conformance.run(testing.io, testing.allocator, &harness, .{});
    defer report.deinit();
    try testing.expectEqual(std.enums.values(Check).len, report.failedCount());
    try expectFailed(&report, .s19, "harness.setUp returned error.NoDriverHere");
}

test "the report has a line a check, with the reason of each failure and skip" {
    var flawed: Flawed = .{ .flaw = .claims_sessions };
    var report = try conformance.run(testing.io, testing.allocator, &flawed, .{});
    defer report.deinit();
    var buffer: [16 * 1024]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{f}", .{&report});
    var first: [128]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, text, try std.fmt.bufPrint(&first, "mongo conformance of \"fake\": {d} passed, 1 failed, {d} skipped\n", .{ report.passedCount(), report.skippedCount() })));
    try testing.expect(std.mem.find(u8, text, "\n  FAILED   S19  capabilities: ") != null);
    try testing.expect(std.mem.find(u8, text, "\n  passed   S1   ") != null);
}
