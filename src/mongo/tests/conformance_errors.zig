//! Harnesses of `mongo.testing.conformance` that must not compile, one
//! test each. `zig build test-mongo` compiles every test on its own and
//! checks its error message; the list of messages is in build.zig.

const std = @import("std");
const mongo = @import("mongo");
const conformance = mongo.testing.conformance;

/// A harness with all three methods right.
const Harness = struct {
    calls: u32 = 0,

    pub fn setUp(h: *Harness, io: std.Io, gpa: std.mem.Allocator, target: conformance.Target) !mongo.Client {
        _ = h;
        _ = io;
        _ = gpa;
        _ = target;
        return error.Unsupported;
    }

    pub fn close(h: *Harness, io: std.Io) void {
        _ = io;
        h.calls += 1;
    }

    pub fn tearDown(h: *Harness, io: std.Io) void {
        _ = io;
        h.calls += 1;
    }
};

test "harness by value" {
    const harness: Harness = .{};
    var report = try conformance.run(std.testing.io, std.testing.allocator, harness, .{});
    report.deinit();
}

test "harness behind a const pointer" {
    const harness: Harness = .{};
    var report = try conformance.run(std.testing.io, std.testing.allocator, &harness, .{});
    report.deinit();
}

test "harness without close" {
    const NoClose = struct {
        calls: u32 = 0,
        pub fn setUp(h: *@This(), io: std.Io, gpa: std.mem.Allocator, target: conformance.Target) !mongo.Client {
            _ = h;
            _ = io;
            _ = gpa;
            _ = target;
            return error.Unsupported;
        }
        pub fn tearDown(h: *@This(), io: std.Io) void {
            _ = io;
            h.calls += 1;
        }
    };
    var harness: NoClose = .{};
    var report = try conformance.run(std.testing.io, std.testing.allocator, &harness, .{});
    report.deinit();
}

test "setUp without the target" {
    const NoTarget = struct {
        calls: u32 = 0,
        pub fn setUp(h: *@This(), io: std.Io, gpa: std.mem.Allocator) !mongo.Client {
            _ = h;
            _ = io;
            _ = gpa;
            return error.Unsupported;
        }
        pub fn close(h: *@This(), io: std.Io) void {
            _ = io;
            h.calls += 1;
        }
        pub fn tearDown(h: *@This(), io: std.Io) void {
            _ = io;
            h.calls += 1;
        }
    };
    var harness: NoTarget = .{};
    var report = try conformance.run(std.testing.io, std.testing.allocator, &harness, .{});
    report.deinit();
}

test "tearDown that may fail" {
    const Failing = struct {
        calls: u32 = 0,
        pub fn setUp(h: *@This(), io: std.Io, gpa: std.mem.Allocator, target: conformance.Target) !mongo.Client {
            _ = h;
            _ = io;
            _ = gpa;
            _ = target;
            return error.Unsupported;
        }
        pub fn close(h: *@This(), io: std.Io) void {
            _ = io;
            h.calls += 1;
        }
        pub fn tearDown(h: *@This(), io: std.Io) !void {
            _ = io;
            h.calls += 1;
            if (h.calls > 9) return error.Busy;
        }
    };
    var harness: Failing = .{};
    var report = try conformance.run(std.testing.io, std.testing.allocator, &harness, .{});
    report.deinit();
}
