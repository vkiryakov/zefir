//! Benchmarks for zefir-core. `zig build bench` builds them with ReleaseFast
//! and prints the environment and nanoseconds per operation. The numbers
//! depend on the machine, so they go into pull requests, not the repository.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    try out.print("zig {s}, {t}-{t}, {s}, {t}\n", .{
        builtin.zig_version_string, builtin.cpu.arch, builtin.os.tag, builtin.cpu.model.name, builtin.mode,
    });

    var token: core.CancellationToken = .init;
    const trace = try core.w3c.parseTraceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01");
    const deadline: core.Deadline = .after(std.Io.Clock.awake.now(io), .fromSeconds(60));
    const ctx = core.Context.root.withTrace(trace).withDeadline(deadline).withCancellation(&token);
    const now = std.Io.Clock.awake.now(io);
    var traceparent: [core.w3c.traceparent_len]u8 = undefined;

    try measure(out, io, "root + withTrace/Deadline/Cancellation", 10_000_000, derive, .{ trace, deadline, &token });
    try measure(out, io, "copy a Context", 10_000_000, copy, .{ctx});
    try measure(out, io, "Context.isCancelled", 10_000_000, core.Context.isCancelled, .{ctx});
    try measure(out, io, "Context.check", 10_000_000, core.Context.check, .{ ctx, now });
    try measure(out, io, "w3c.parseTraceparent", 1_000_000, core.w3c.parseTraceparent, .{"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"});
    try measure(out, io, "w3c.formatTraceparent", 1_000_000, core.w3c.formatTraceparent, .{ trace, &traceparent });
    try measure(out, io, "w3c.parseTracestate, 3 members", 1_000_000, core.w3c.parseTracestate, .{"rojo=00f067aa0ba902b7,congo=t61rcWkgMzE,foo=bar"});
    try measure(out, io, "w3c.parseTracestate, 32 members", 100_000, core.w3c.parseTracestate, .{thirty_two_members});
}

fn derive(trace: core.TraceContext, deadline: core.Deadline, token: *const core.CancellationToken) core.Context {
    return core.Context.root.withTrace(trace).withDeadline(deadline).withCancellation(token);
}

fn copy(ctx: core.Context) core.Context {
    return ctx;
}

const thirty_two_members = blk: {
    @setEvalBranchQuota(100_000);
    var text: []const u8 = "";
    for (1..33) |i| text = text ++ (if (i == 1) "" else ",") ++ std.fmt.comptimePrint("vendor{d:0>2}=value{d:0>2}", .{ i, i });
    break :blk text;
};

fn measure(out: *std.Io.Writer, io: std.Io, name: []const u8, iterations: u64, comptime function: anytype, args: anytype) !void {
    var input = args;
    const start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        // Hide the input and keep the result, so the call is neither hoisted nor removed.
        std.mem.doNotOptimizeAway(&input);
        std.mem.doNotOptimizeAway(@call(.auto, function, input));
    }
    const elapsed = start.durationTo(std.Io.Clock.awake.now(io));
    const per_op = @as(f64, @floatFromInt(elapsed.nanoseconds)) / @as(f64, @floatFromInt(iterations));
    try out.print("{s:<40} {d:>9.2} ns/op\n", .{ name, per_op });
}
