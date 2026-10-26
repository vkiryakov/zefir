//! The checks of records and their changes in
//! `scheduler.testing.conformance`.

const std = @import("std");
const Runner = @import("runner.zig");
const Error = Runner.Error;

pub fn s3(r: *Runner) Error!void {
    const job = "s3-send";
    try r.expect(try r.get(job, "order-42") == null, "get of a key never created found a record", .{});
    const created = try r.create(job, "order-42", .{ .after = .fromSeconds(60) });
    try r.expect(created == .created, "create of a new key answered {t}, not created", .{created});
    // A key of another job, and another key of the job, are other records.
    try r.expect(try r.create("s3-other", "order-42", .{ .after = .fromSeconds(60) }) == .created, "create of the same key of another job did not answer created", .{});
    try r.expect(try r.create(job, "order-43", .{ .after = .fromSeconds(60) }) == .created, "create of another key of the job did not answer created", .{});
    const found = try r.fetch(job, "order-42");
    try r.expect(std.mem.eql(u8, found.job, job) and std.mem.eql(u8, found.key, "order-42"), "get of {s}/order-42 gave {s}/{s}", .{ job, found.job, found.key });
    try r.expect(try r.remove(job, "order-42"), "remove of a record that is there returned false", .{});
    try r.expect(try r.get(job, "order-42") == null, "get after remove found the record", .{});
    try r.expect(!try r.remove(job, "order-42"), "remove of a record that is gone returned true", .{});
    _ = try r.fetch("s3-other", "order-42");
    _ = try r.fetch(job, "order-43");
}
