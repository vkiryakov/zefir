//! Mocks for the tests of zefir.App: a recorder the mocks write their
//! lifecycle into, and the ready objects of a root.
const std = @import("std");

pub const Event = struct { what: []const u8, who: []const u8 };

/// A ready object (a value of the root) that mocks record into. Tasks may
/// share it: a mutex guards the events.
pub const Recorder = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    events: [capacity]Event = undefined,
    len: usize = 0,
    /// Set when an event did not fit; `expect` then fails the test.
    overflow: bool = false,

    pub const capacity = 512;

    pub fn init(io: std.Io) Recorder {
        return .{ .io = io };
    }

    pub fn add(r: *Recorder, what: []const u8, who: []const u8) void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        if (r.len == capacity) {
            r.overflow = true;
            return;
        }
        r.events[r.len] = .{ .what = what, .who = who };
        r.len += 1;
    }

    /// Checks the `who` of every event `what`, in order.
    pub fn expect(r: *Recorder, what: []const u8, expected: []const []const u8) !void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        if (r.overflow) {
            std.debug.print("the recorder got more than {d} events\n", .{capacity});
            return error.TestUnexpectedResult;
        }
        var got: [capacity][]const u8 = undefined;
        var n: usize = 0;
        for (r.events[0..r.len]) |e| if (std.mem.eql(u8, e.what, what)) {
            got[n] = e.who;
            n += 1;
        };
        errdefer {
            std.debug.print("{s}: got", .{what});
            for (got[0..n]) |g| std.debug.print(" {s}", .{g});
            std.debug.print("\n", .{});
        }
        try std.testing.expectEqual(expected.len, n);
        for (expected, got[0..n]) |e, g| try std.testing.expectEqualStrings(e, g);
    }
};

pub const Config = struct {
    port: u16 = 8080,
    mongo_uri: []const u8 = "mongodb://shop",
};

/// A ready object with a `deinit`, as `log.Logger` has: App never destroys
/// a value, so this must not record.
pub const Logger = struct {
    id: u32,
    rec: ?*Recorder = null,

    pub fn deinit(l: *Logger) void {
        if (l.rec) |r| r.add("deinit", "Logger");
    }
};
