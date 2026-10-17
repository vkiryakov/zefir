//! What the tasks of a request cost on zio. A request in work holds three
//! coroutines: its connection's task, the request task and the watcher,
//! which the connection races in an `Io.Select`. This probe holds 1,000
//! and then 10,000 such requests at once, with zio's default stacks, and
//! prints the wall time per request, the memory at the peak, and on Linux
//! the memory mappings of the process at the peak: Linux allows a process
//! `vm.max_map_count` of them, 65,530 by default, and each coroutine stack
//! takes some. It fails only when the requests cannot all run.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;
const runtime = @import("runtime");
const probes = @import("root.zig");

test "cost of three coroutines per request" {
    try runtime.forEachRuntime(testing.allocator, costOfRequests);
}

fn costOfRequests(io: Io) !void {
    for ([_]usize{ 1_000, 10_000 }) |count| try measure(io, count);
}

/// What the tasks of one measurement share.
const Requests = struct {
    count: usize,
    /// The requests wait for it, so that every task is alive at the peak.
    go: Io.Event = .unset,
    /// Set when the request and the watcher of every connection run.
    all_running: Io.Event = .unset,
    running: std.atomic.Value(usize) = .init(0),
    /// Connections whose request or watcher the runtime did not start.
    refused: std.atomic.Value(usize) = .init(0),
    finished: std.atomic.Value(usize) = .init(0),
};

/// The connection's task: races its request with the watcher, as the
/// server does, and cancels the watcher when the request ends.
fn connection(io: Io, requests: *Requests) Io.Cancelable!void {
    const Race = union(enum) {
        request: Io.Cancelable!void,
        watcher: Io.Cancelable!void,
    };
    var results: [2]Race = undefined;
    var select: Io.Select(Race) = .init(io, &results);
    defer select.cancelDiscard();
    const started = started: {
        select.concurrent(.request, request, .{ io, requests }) catch break :started false;
        select.concurrent(.watcher, watcher, .{io}) catch break :started false;
        break :started true;
    };
    if (!started) _ = requests.refused.fetchAdd(1, .monotonic);
    if (requests.running.fetchAdd(1, .acq_rel) + 1 == requests.count) requests.all_running.set(io);
    if (!started) return;
    switch (try select.await()) {
        .request => |result| try result,
        .watcher => return,
    }
    _ = requests.finished.fetchAdd(1, .monotonic);
}

/// The request: a handler that takes a millisecond.
fn request(io: Io, requests: *Requests) Io.Cancelable!void {
    try requests.go.wait(io);
    try io.sleep(.fromMilliseconds(1), .awake);
}

/// The watcher: waits far longer than the request, until it is canceled.
fn watcher(io: Io) Io.Cancelable!void {
    try io.sleep(.fromSeconds(30), .awake);
}

fn measure(io: Io, count: usize) !void {
    var requests: Requests = .{ .count = count };
    const before = sample(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    const start = probes.now(io);
    var spawned: usize = 0;
    while (spawned < count) : (spawned += 1) {
        group.concurrent(io, connection, .{ io, &requests }) catch break;
    }
    if (spawned < count) {
        requests.go.set(io);
        group.await(io) catch {};
        probes.report("{d} requests: the runtime gave only {d} connection tasks", .{ count, spawned });
        return error.ConcurrencyUnavailable;
    }
    try requests.all_running.wait(io);
    const running = probes.since(io, start);
    const peak = sample(io);
    requests.go.set(io);
    try group.await(io);
    const took = probes.since(io, start);
    const refused = requests.refused.load(.monotonic);
    if (refused != 0) {
        probes.report("{d} requests: the runtime did not start the request or the watcher of {d} connections", .{ count, refused });
        return error.ConcurrencyUnavailable;
    }
    try testing.expectEqual(count, requests.finished.load(.monotonic));

    const coroutines = 3 * count;
    const per_request = probes.ms(took) * 1000 / @as(f64, @floatFromInt(count));
    probes.report("{d} requests, {d} coroutines: all running after {d:.1} ms, done after {d:.1} ms, {d:.2} us per request", .{ count, coroutines, probes.ms(running), probes.ms(took), per_request });
    if (before.resident != null and peak.resident != null) {
        const grown = peak.resident.? -| before.resident.?;
        const grown_per_request = kib(grown) / @as(f64, @floatFromInt(count));
        probes.report("{d} requests: resident memory {d:.1} MiB at the peak, {d:.1} MiB more than before, {d:.1} KiB per request; process peak {d:.1} MiB", .{ count, mib(peak.resident.?), mib(grown), grown_per_request, mib(peak.peak_resident orelse 0) });
    }
    if (peak.mappings) |at_peak| {
        const added = at_peak -| (before.mappings orelse 0);
        const per_coroutine = @as(f64, @floatFromInt(added)) / @as(f64, @floatFromInt(coroutines));
        probes.report("{d} requests: {d} memory mappings at the peak, {d} more than before, {d:.2} per coroutine; vm.max_map_count {d}", .{ count, at_peak, added, per_coroutine, peak.max_map_count orelse 0 });
    }
}

/// The memory of the process at one moment; null where the system does not
/// tell it.
const Sample = struct {
    /// Bytes resident now.
    resident: ?u64 = null,
    /// The most bytes resident so far.
    peak_resident: ?u64 = null,
    /// Linux: the memory mappings of the process, lines of /proc/self/maps.
    mappings: ?usize = null,
    /// Linux: how many mappings a process may have.
    max_map_count: ?usize = null,
};

fn sample(io: Io) Sample {
    var s: Sample = .{};
    switch (builtin.os.tag) {
        .linux => {
            var buffer: [256]u8 = undefined;
            if (readFile(io, "/proc/self/statm", &buffer)) |statm| {
                var fields = std.mem.tokenizeScalar(u8, statm, ' ');
                _ = fields.next();
                if (fields.next()) |pages| {
                    if (std.fmt.parseInt(u64, pages, 10)) |n| s.resident = n * std.heap.pageSize() else |_| {}
                }
            } else |_| {}
            if (readFile(io, "/proc/sys/vm/max_map_count", &buffer)) |text| {
                s.max_map_count = std.fmt.parseInt(usize, std.mem.trim(u8, text, " \n"), 10) catch null;
            } else |_| {}
            s.mappings = countLines(io, "/proc/self/maps") catch null;
            // Linux gives the peak in KiB.
            s.peak_resident = @as(u64, @intCast(std.posix.getrusage(std.posix.rusage.SELF).maxrss)) * 1024;
        },
        .macos => {
            var info: std.c.mach_task_basic_info = undefined;
            var info_count: std.c.mach_msg_type_number_t = std.c.MACH.TASK.BASIC.INFO_COUNT;
            if (std.c.task_info(std.c.mach_task_self(), std.c.MACH.TASK.BASIC.INFO, @ptrCast(&info), &info_count) == 0) {
                s.resident = info.resident_size;
            }
            // macOS gives the peak in bytes.
            s.peak_resident = @intCast(std.posix.getrusage(std.posix.rusage.SELF).maxrss);
        },
        .windows => {
            const windows = std.os.windows;
            var counters: windows.PROCESS.VM_COUNTERS = undefined;
            if (windows.ntdll.NtQueryInformationProcess(windows.GetCurrentProcess(), .VmCounters, &counters, @sizeOf(windows.PROCESS.VM_COUNTERS), null) == .SUCCESS) {
                s.resident = counters.WorkingSetSize;
                s.peak_resident = counters.PeakWorkingSetSize;
            }
        },
        else => {},
    }
    return s;
}

fn readFile(io: Io, path: []const u8, buffer: []u8) ![]const u8 {
    const file = try Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var len: usize = 0;
    while (len < buffer.len) {
        const n = file.readStreaming(io, &.{buffer[len..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (n == 0) break;
        len += n;
    }
    return buffer[0..len];
}

fn countLines(io: Io, path: []const u8) !usize {
    const file = try Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var lines: usize = 0;
    while (true) {
        const n = file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => return lines,
            else => |e| return e,
        };
        if (n == 0) return lines;
        lines += std.mem.countScalar(u8, buffer[0..n], '\n');
    }
}

fn mib(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024 * 1024);
}

fn kib(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1024;
}
