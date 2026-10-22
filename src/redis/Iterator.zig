//! `redis.Iterator(T)`: the items of a scan, SCAN, HSCAN, SSCAN or ZSCAN,
//! one at a time, from `client.iterate`. `next` gives the items of the
//! page in hand; once they are out and the cursor is not 0, it fetches
//! the next page in one exchange on a connection of the pool, by the rules
//! of `client.run`. An empty page before the end is no end. After the
//! page of the cursor 0, `next` returns null.
//!
//! ```zig
//! var sessions = client.iterate(redis.cmd.scan(.{ .match = "session:*", .count = 500 }), .{ .allocator = gpa });
//! defer sessions.deinit();
//! while (try sessions.next(io, op)) |key| { // the key lives until the next next
//!     try cleanUp(key);
//! }
//! ```
//!
//! - A page lies in an arena of the iterator over `options.allocator`
//!   until the next page, and `deinit` frees it: an item lives until the
//!   next `next`.
//! - An item may come twice, as SCAN allows: the iterator keeps no record
//!   of what it gave. A key that was there all along comes at least once.
//! - A page that failed, by a deadline or a broken connection, leaves the
//!   iterator as it was: the next `next`, with a new context, asks for the
//!   same page from the same cursor. The iterator itself never asks twice:
//!   whether to go on is the caller's call.
//! - One task at a time calls `next`; in safe builds a second task that
//!   calls meanwhile panics. The client and the slices of the command must
//!   outlive the iterator.

const std = @import("std");
const Io = std.Io;
const errors = @import("errors.zig");
const requests = @import("requests.zig");
const contract = @import("cmd/contract.zig");
const command = @import("cmd/command.zig");
const Client = @import("Client.zig");

pub fn Iterator(comptime T: type) type {
    return struct {
        client: *Client,
        /// The page that comes next, with its cursor.
        command: command.Paged(T),
        arena: std.heap.ArenaAllocator,
        diagnostics: ?*errors.Diagnostics,
        /// The items of the page in hand, and how many of them `next` gave.
        items: []const T = &.{},
        given: usize = 0,
        /// Whether the page in hand is the last: its cursor was 0.
        last: bool = false,
        /// In safe builds: set while `next` runs, so that a second task
        /// that calls meanwhile panics.
        busy: if (std.debug.runtime_safety) std.atomic.Value(bool) else void = if (std.debug.runtime_safety) .init(false) else {},

        const Self = @This();

        /// The iterator of the scan `page` describes, as `client.iterate`
        /// makes it: no I/O.
        pub fn init(client: *Client, page: contract.Page, options: requests.IterateOptions) Self {
            return .{ .client = client, .command = .{ .page = page }, .arena = .init(options.allocator), .diagnostics = options.diagnostics };
        }

        /// Frees the page in hand.
        pub fn deinit(it: *Self) void {
            it.arena.deinit();
            it.* = undefined;
        }

        /// The next item, which lives until the next call; null after the
        /// last. It fetches a page when the one in hand is out, within the
        /// deadline of `op`, and what went wrong with it goes to the
        /// diagnostics of `client.iterate`.
        pub fn next(it: *Self, io: Io, op: requests.OperationContext) errors.Error!?T {
            it.enter();
            defer it.leave();
            while (it.given == it.items.len) {
                if (it.last) return null;
                try it.fetch(io, op);
            }
            const item = it.items[it.given];
            it.given += 1;
            return item;
        }

        /// The page of the cursor in hand; after an error, the cursor stays.
        fn fetch(it: *Self, io: Io, op: requests.OperationContext) errors.Error!void {
            // The items of the page before live until this call.
            _ = it.arena.reset(.retain_capacity);
            it.items = &.{};
            it.given = 0;
            const page = try it.client.run(io, op, it.command, .{ .allocator = it.arena.allocator(), .diagnostics = it.diagnostics });
            it.items = page.items;
            it.command.page.cursor = page.cursor;
            it.last = page.cursor == 0;
        }

        fn enter(it: *Self) void {
            if (std.debug.runtime_safety and it.busy.swap(true, .acquire)) {
                @panic("zefir-redis: an Iterator used by two tasks at once: one task at a time calls next");
            }
        }

        fn leave(it: *Self) void {
            if (std.debug.runtime_safety) it.busy.store(false, .release);
        }
    };
}
