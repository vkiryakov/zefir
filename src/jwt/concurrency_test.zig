//! One `Signer` and one `Verifier` serve many tasks at once (design
//! 5.13): they are immutable, and every call keeps its memory to itself;
//! ECDSA also takes its noise from the `Io` of each call.
//! `zig build test-jwt -Dtsan=true` runs this under ThreadSanitizer.

const std = @import("std");
const Key = @import("Key.zig");
const SigningKey = @import("SigningKey.zig");
const Signer = @import("Signer.zig");
const Verifier = @import("Verifier.zig");

const testing = std.testing;

const task_count = 64;
const tokens_per_task = 16;

const Claims = struct {
    task: u32,
    roles: []const []const u8 = &.{},
};

const Shared = struct {
    signer: *const Signer,
    verifier: *const Verifier,
    io: std.Io,
    passed: std.atomic.Value(u32) = .init(0),
    failed: std.atomic.Value(u32) = .init(0),
};

fn run(shared: *Shared, task: u32) void {
    signAndVerify(shared, task) catch |err| {
        std.debug.print("task {d}: {t}\n", .{ task, err });
        _ = shared.failed.fetchAdd(1, .monotonic);
    };
}

/// Signs tokens with a subject of its own and verifies each of them.
fn signAndVerify(shared: *Shared, task: u32) !void {
    var subject_buf: [16]u8 = undefined;
    const subject = try std.fmt.bufPrint(&subject_buf, "user-{d}", .{task});
    for (0..tokens_per_task) |_| {
        const token = try shared.signer.sign(Claims, shared.io, testing.allocator, &.{ .task = task, .roles = &.{"buyer"} }, .{ .subject = subject });
        defer testing.allocator.free(token);
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const verified = try shared.verifier.verify(Claims, shared.io, arena_state.allocator(), token, .{});
        if (!std.mem.eql(u8, subject, verified.registered.subject orelse "")) return error.TestWrongSubject;
        if (verified.claims.task != task) return error.TestWrongClaims;
        _ = shared.passed.fetchAdd(1, .monotonic);
    }
}

test "64 tasks sign and verify with one Signer and one Verifier at once, for HMAC, ECDSA and EdDSA" {
    var hs256: SigningKey = try .hmac(.HS256, "0123456789abcdef0123456789abcdef", .{ .id = "k1" });
    defer hs256.deinit();
    var es256: SigningKey = try .generate(testing.io, .ES256, .{ .id = "k2" });
    defer es256.deinit();
    var eddsa: SigningKey = try .generate(testing.io, .EdDSA, .{ .id = "k3" });
    defer eddsa.deinit();
    const signing_keys = [_]*const SigningKey{ &hs256, &es256, &eddsa };

    // One key, one signer and one verifier for each algorithm.
    var keys: [signing_keys.len]Key = undefined;
    defer for (&keys) |*key| key.deinit();
    var signers: [signing_keys.len]Signer = undefined;
    var verifiers: [signing_keys.len]Verifier = undefined;
    var shared: [signing_keys.len]Shared = undefined;
    for (signing_keys, 0..) |signing, i| {
        keys[i] = signing.verificationKey();
        signers[i] = try .init(signing, .{ .issuer = "orders", .audiences = &.{"orders"} });
        verifiers[i] = try .init(.{ .keys = keys[i..][0..1], .issuer = "orders", .audiences = &.{"orders"} });
        shared[i] = .{ .signer = &signers[i], .verifier = &verifiers[i], .io = testing.io };
    }

    var group: std.Io.Group = .init;
    // Should a start fail, the tasks already started end before `shared`
    // goes away.
    defer group.cancel(testing.io);
    for (&shared) |*one| {
        for (0..task_count) |task| try group.concurrent(testing.io, run, .{ one, @as(u32, @intCast(task)) });
    }
    try group.await(testing.io);

    for (&shared, signing_keys) |*one, signing| {
        errdefer std.debug.print("{t}\n", .{signing.algorithm});
        try testing.expectEqual(0, one.failed.load(.monotonic));
        try testing.expectEqual(task_count * tokens_per_task, one.passed.load(.monotonic));
    }
}
