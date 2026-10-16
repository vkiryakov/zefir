//! The NATS CLI, a client that is not zefir, against a zefir service:
//! `nats req` calls it as it calls any NATS service, without the headers
//! of zefir, and gets an error of the application in the headers of the
//! NATS Service API; `nats micro ls`, `info` and `stats` see the service,
//! its method and the counters of the calls (A11).

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const root = @import("root.zig");
const services = @import("services.zig");

const servers = root.servers;

/// `nats -s <the plain server> <args>`.
fn cli(io: Io, args: []const []const u8) !root.Output {
    var argv: [16][]const u8 = undefined;
    argv[0] = "-s";
    argv[1] = servers.plain_for_cli;
    @memcpy(argv[2..][0..args.len], args);
    return root.natsCli(io, argv[0 .. args.len + 2]);
}

fn expectHas(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.find(u8, haystack, needle) == null) {
        std.debug.print("expected to find \"{s}\" in:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedText;
    }
}

const Endpoint = struct { name: []const u8, subject: []const u8, queue_group: []const u8 };
const ServiceInfo = struct { name: []const u8, id: []const u8, version: []const u8, type: []const u8, endpoints: []const Endpoint };
const EndpointStats = struct { name: []const u8, num_requests: u64, num_errors: u64, last_error: []const u8, processing_time: u64, average_processing_time: u64 };
const ServiceStats = struct { name: []const u8, id: []const u8, version: []const u8, type: []const u8, started: []const u8, endpoints: []const EndpointStats };
const InfoAndStats = struct { info: ServiceInfo, stats: ServiceStats };

fn parse(comptime T: type, arena: std.mem.Allocator, out: root.Output) !T {
    // Copies: `out` is freed before the result is used.
    return std.json.parseFromSliceLeaky(T, arena, out.stdout, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
        std.debug.print("the NATS CLI printed:\n{s}\n{s}\n", .{ out.stdout, out.stderr });
        return err;
    };
}

fn expectService(info: ServiceInfo) !void {
    try testing.expectEqualStrings("users", info.name);
    try testing.expectEqualStrings("1.0.0", info.version);
    try testing.expectEqual(@as(usize, 22), info.id.len);
    try testing.expectEqual(@as(usize, 1), info.endpoints.len);
    try testing.expectEqualStrings("getUser", info.endpoints[0].name);
    try testing.expectEqualStrings("users.v1.getUser", info.endpoints[0].subject);
    try testing.expectEqualStrings("q", info.endpoints[0].queue_group);
}

fn expectCounters(stats: ServiceStats) !void {
    try testing.expectEqualStrings("io.nats.micro.v1.stats_response", stats.type);
    try testing.expect(std.mem.endsWith(u8, stats.started, "Z"));
    const e = stats.endpoints[0];
    try testing.expectEqualStrings("getUser", e.name);
    try testing.expectEqual(@as(u64, 2), e.num_requests);
    try testing.expectEqual(@as(u64, 1), e.num_errors);
    try testing.expectEqualStrings("404:users.not_found", e.last_error);
    try testing.expect(e.processing_time > 0);
    try testing.expectEqual(e.processing_time / 2, e.average_processing_time);
}

fn scenario(io: Io) !void {
    var users: services.Users = .{};
    var node: services.Node = undefined;
    try node.init(io, servers.plain, null, .{});
    defer node.deinit(io);
    try node.serve(io, &users);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A request without the headers of zefir; the 64-bit id travels as a
    // string.
    {
        const out = try cli(io, &.{ "req", "users.v1.getUser", "{\"id\":\"1\"}", "--raw" });
        defer out.deinit();
        try testing.expectEqualStrings("{\"id\":\"1\",\"name\":\"Alex\"}", std.mem.trim(u8, out.stdout, " \r\n"));
    }
    // An error of the application: the headers of ADR-32, and those of zefir.
    {
        const out = try cli(io, &.{ "req", "users.v1.getUser", "{\"id\":\"2\"}" });
        defer out.deinit();
        try expectHas(out.stderr, "Nats-Service-Error: User not found");
        try expectHas(out.stderr, "Nats-Service-Error-Code: 404");
        try expectHas(out.stderr, "Zefir-Rpc-Code: not_found");
        try expectHas(out.stderr, "Zefir-Rpc-App-Code: users.not_found");
    }
    try testing.expectEqual(@as(u32, 2), users.calls.load(.monotonic));

    // nats micro ls: the live services; here only users.
    const listed = listed: {
        const out = try cli(io, &.{ "micro", "ls", "--json" });
        defer out.deinit();
        break :listed try parse([]const ServiceInfo, a, out);
    };
    try testing.expectEqual(@as(usize, 1), listed.len);
    try expectService(listed[0]);
    // nats micro info users: the definition and the counters of one service.
    {
        const out = try cli(io, &.{ "micro", "info", "users", "--json" });
        defer out.deinit();
        const both = try parse(InfoAndStats, a, out);
        try expectService(both.info);
        try testing.expectEqualStrings(listed[0].id, both.info.id);
        try expectCounters(both.stats);
    }
    // nats micro stats users: the counters of its replicas.
    {
        const out = try cli(io, &.{ "micro", "stats", "users", "--json" });
        defer out.deinit();
        const replicas = try parse([]const ServiceStats, a, out);
        try testing.expectEqual(@as(usize, 1), replicas.len);
        try testing.expectEqualStrings(listed[0].id, replicas[0].id);
        try expectCounters(replicas[0]);
    }
}

test "the NATS CLI calls a zefir service, and nats micro sees it, its method and its counters" {
    try root.onZio(scenario);
}
