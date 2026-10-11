//! The scope table of one logger: every scope name its handles use, the
//! level each one logs at, and the rules that set those levels.
//!
//! A handle keeps a pointer to its entry and reads the level with one
//! atomic load, so `setLevel` and `setScopeLevel` reach existing handles
//! at once. Names are only added, never removed, so lookups take no lock;
//! adding a name and changing levels take a short spin lock.

const std = @import("std");
const escape = @import("escape.zig");
const Level = @import("level.zig").Level;
const ScopeRule = @import("options.zig").ScopeRule;
const testing = std.testing;

/// Distinct scope names one logger keeps.
pub const max_scopes = 256;
/// Level rules one logger keeps.
pub const max_rules = 64;
/// The longest scope name or rule prefix, as records write it.
pub const max_name_bytes = 128;

/// One scope, as handles see it.
pub const Entry = struct {
    /// The level this scope logs at: its longest matching rule's, or the
    /// global one.
    level: std.atomic.Value(Level),
    /// The text format writes the name in quotes, see `encode.Header`.
    quoted: bool = false,
    len: u8 = 0,
    bytes: [max_name_bytes]u8 = undefined,

    /// The name as records write it, escaped; empty for the root entry.
    pub fn name(entry: *const Entry) []const u8 {
        return entry.bytes[0..entry.len];
    }
};

const Rule = struct {
    level: Level,
    len: u8,
    bytes: [max_name_bytes]u8,

    fn prefix(rule: *const Rule) []const u8 {
        return rule.bytes[0..rule.len];
    }
};

pub const Table = struct {
    /// Handles without a scope, and handles `find` could not add, use this
    /// entry. Its level is the global threshold.
    root: Entry,
    entries: [max_scopes]Entry,
    /// `entries[0..count]` are in use and, but for their level, never change.
    count: std.atomic.Value(u32),
    rules: [max_rules]Rule,
    /// Guarded by `lock`.
    rule_count: u32,
    /// Taken to add an entry or to change a level.
    lock: std.atomic.Mutex,
    /// `find` calls that found the table full.
    overflow: std.atomic.Value(u64),
    /// `find` calls whose name was cut to `max_name_bytes`.
    names_truncated: std.atomic.Value(u64),

    pub fn init(table: *Table, level: Level, rules: []const ScopeRule) error{ TooManyRules, EmptyPrefix }!void {
        table.* = .{
            .root = .{ .level = .init(level) },
            .entries = undefined,
            .count = .init(0),
            .rules = undefined,
            .rule_count = 0,
            .lock = .unlocked,
            .overflow = .init(0),
            .names_truncated = .init(0),
        };
        for (rules) |rule| try table.setRule(rule.prefix, rule.level);
    }

    /// The entry of scope `name`, added on first use. An empty name gets the
    /// root entry, and so does any new name once the table is full.
    pub fn find(table: *Table, name: []const u8) *const Entry {
        var buf: [max_name_bytes]u8 = undefined;
        const key = escapeName(name, &buf);
        if (key.cut) _ = table.names_truncated.fetchAdd(1, .monotonic);
        if (key.name.len == 0) return &table.root;
        const published = table.count.load(.acquire);
        if (lookup(table.entries[0..published], key.name)) |entry| return entry;

        table.lockSpin();
        defer table.lock.unlock();
        const count = table.count.load(.monotonic);
        if (lookup(table.entries[published..count], key.name)) |entry| return entry;
        if (count == max_scopes) {
            _ = table.overflow.fetchAdd(1, .monotonic);
            return &table.root;
        }
        const entry = &table.entries[count];
        entry.* = .{
            .level = .init(table.levelFor(key.name)),
            .quoted = !escape.isBare(key.name) or std.mem.findAny(u8, key.name, "[]") != null,
            .len = @intCast(key.name.len),
        };
        @memcpy(entry.bytes[0..key.name.len], key.name);
        table.count.store(count + 1, .release);
        return entry;
    }

    /// Sets the global threshold; scopes without a rule follow it.
    pub fn setGlobal(table: *Table, level: Level) void {
        table.lockSpin();
        defer table.lock.unlock();
        table.root.level.store(level, .monotonic);
        table.recompute();
    }

    /// Adds or changes the rule for `prefix`, or removes it when `level` is
    /// null. A trailing dot is ignored: `zefir.` is the rule for `zefir`.
    pub fn setRule(table: *Table, prefix: []const u8, level: ?Level) error{ TooManyRules, EmptyPrefix }!void {
        const trimmed = std.mem.trimEnd(u8, prefix, ".");
        if (trimmed.len == 0) return error.EmptyPrefix;
        var buf: [max_name_bytes]u8 = undefined;
        const key = escapeName(trimmed, &buf).name;
        table.lockSpin();
        defer table.lock.unlock();
        const rules = table.rules[0..table.rule_count];
        const index: ?usize = for (rules, 0..) |*rule, i| {
            if (std.mem.eql(u8, rule.prefix(), key)) break i;
        } else null;
        if (level) |new| {
            if (index) |i| {
                rules[i].level = new;
            } else {
                if (table.rule_count == max_rules) return error.TooManyRules;
                const rule = &table.rules[table.rule_count];
                rule.* = .{ .level = new, .len = @intCast(key.len), .bytes = undefined };
                @memcpy(rule.bytes[0..key.len], key);
                table.rule_count += 1;
            }
        } else if (index) |i| {
            rules[i] = rules[rules.len - 1];
            table.rule_count -= 1;
        }
        table.recompute();
    }

    fn levelFor(table: *const Table, name: []const u8) Level {
        var best: ?*const Rule = null;
        for (table.rules[0..table.rule_count]) |*rule| {
            if (!covers(rule.prefix(), name)) continue;
            if (best == null or rule.len > best.?.len) best = rule;
        }
        return if (best) |rule| rule.level else table.root.level.load(.monotonic);
    }

    fn recompute(table: *Table) void {
        for (table.entries[0..table.count.load(.monotonic)]) |*entry| {
            entry.level.store(table.levelFor(entry.name()), .monotonic);
        }
    }

    /// Spins, and now and then gives the CPU away, so a preempted holder
    /// can finish its short critical section.
    fn lockSpin(table: *Table) void {
        var spins: u32 = 0;
        while (!table.lock.tryLock()) {
            spins +%= 1;
            if (spins % 64 == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
        }
    }
};

/// Whether the rule for `prefix` covers scope `name`: the same name, or a
/// subscope after a dot.
fn covers(prefix: []const u8, name: []const u8) bool {
    return std.mem.startsWith(u8, name, prefix) and (name.len == prefix.len or name[prefix.len] == '.');
}

fn lookup(entries: []const Entry, name: []const u8) ?*const Entry {
    for (entries) |*entry| {
        if (std.mem.eql(u8, entry.name(), name)) return entry;
    }
    return null;
}

const Key = struct { name: []const u8, cut: bool };

/// `name` escaped as records write it and cut, between characters, to
/// `max_name_bytes`.
fn escapeName(name: []const u8, buf: *[max_name_bytes]u8) Key {
    const n = escape.fittingPrefix(name, max_name_bytes);
    var w: std.Io.Writer = .fixed(buf);
    escape.write(&w, name[0..n]) catch unreachable; // fits: fittingPrefix measured it
    return .{ .name = w.buffered(), .cut = n < name.len };
}

fn newTable(level: Level, rules: []const ScopeRule) !*Table {
    const table = try testing.allocator.create(Table);
    errdefer testing.allocator.destroy(table);
    try table.init(level, rules);
    return table;
}

test "a name maps to one entry; an empty name is the root" {
    const table = try newTable(.info, &.{});
    defer testing.allocator.destroy(table);
    const users = table.find("users");
    try testing.expect(users == table.find("users"));
    try testing.expect(users != table.find("orders"));
    try testing.expect(table.find("") == &table.root);
    try testing.expectEqualStrings("users", users.name());
    try testing.expectEqualStrings("", table.root.name());
}

test "the longest matching prefix wins, and only at a dot" {
    const table = try newTable(.info, &.{
        .{ .prefix = "zefir", .level = .warn },
        .{ .prefix = "zefir.rpc", .level = .debug },
    });
    defer testing.allocator.destroy(table);
    try testing.expectEqual(Level.debug, table.find("zefir.rpc").level.load(.monotonic));
    try testing.expectEqual(Level.debug, table.find("zefir.rpc.server").level.load(.monotonic));
    try testing.expectEqual(Level.warn, table.find("zefir.rpcx").level.load(.monotonic));
    try testing.expectEqual(Level.warn, table.find("zefir").level.load(.monotonic));
    try testing.expectEqual(Level.info, table.find("zefirx").level.load(.monotonic));
    try testing.expectEqual(Level.info, table.root.level.load(.monotonic));
}

test "rule and global changes reach existing entries" {
    const table = try newTable(.info, &.{});
    defer testing.allocator.destroy(table);
    const api = table.find("users.api");
    try table.setRule("users", .err);
    try testing.expectEqual(Level.err, api.level.load(.monotonic));
    table.setGlobal(.trace); // a rule outranks the global level
    try testing.expectEqual(Level.err, api.level.load(.monotonic));
    try testing.expectEqual(Level.trace, table.root.level.load(.monotonic));
    try table.setRule("users", null);
    try testing.expectEqual(Level.trace, api.level.load(.monotonic));
    try table.setRule("orders", .warn); // a new entry picks up the rules in place
    try testing.expectEqual(Level.warn, table.find("orders.db").level.load(.monotonic));
}

test "a trailing dot in a rule prefix is ignored" {
    const table = try newTable(.info, &.{});
    defer testing.allocator.destroy(table);
    try table.setRule("zefir.", .debug);
    try testing.expectEqual(Level.debug, table.find("zefir.rpc").level.load(.monotonic));
    try table.setRule("zefir", null); // the same rule
    try testing.expectEqual(Level.info, table.find("zefir.rpc").level.load(.monotonic));
    try testing.expectError(error.EmptyPrefix, table.setRule("..", .debug));
}

test "an entry knows whether the text format must quote its name" {
    const table = try newTable(.info, &.{});
    defer testing.allocator.destroy(table);
    try testing.expect(!table.find("zefir.rpc-v2_x").quoted);
    try testing.expect(table.find("a] fake=1 [b").quoted);
    try testing.expect(table.find("[x").quoted);
    try testing.expect(table.find("a b").quoted);
    try testing.expect(table.find("a=b").quoted);
    try testing.expect(table.find("a\nb").quoted);
    try testing.expect(!table.root.quoted);
}

test "at most 64 rules, none with an empty prefix" {
    const table = try newTable(.info, &.{});
    defer testing.allocator.destroy(table);
    var buf: [8]u8 = undefined;
    for (0..max_rules) |i| try table.setRule(try std.fmt.bufPrint(&buf, "r{d}", .{i}), .debug);
    try testing.expectError(error.TooManyRules, table.setRule("one-more", .debug));
    try table.setRule("r0", .err); // changing a rule is fine
    try table.setRule("r0", null); // and removing one makes room
    try table.setRule("one-more", .debug);
    try testing.expectError(error.EmptyPrefix, table.setRule("", .debug));
}

test "a full table hands out the root entry and counts it" {
    const table = try newTable(.info, &.{});
    defer testing.allocator.destroy(table);
    var buf: [8]u8 = undefined;
    for (0..max_scopes) |i| _ = table.find(try std.fmt.bufPrint(&buf, "s{d}", .{i}));
    try testing.expect(table.find("one-more") == &table.root);
    try testing.expectEqual(@as(u64, 1), table.overflow.load(.monotonic));
    try testing.expect(table.find("s0") != &table.root); // known names still work
}

test "names are escaped and cut to 128 bytes between characters" {
    const table = try newTable(.info, &.{});
    defer testing.allocator.destroy(table);
    try testing.expectEqualStrings("a\\nb\\\"c\u{FFFD}", table.find("a\nb\"c\xff").name());
    try testing.expectEqual(@as(u64, 0), table.names_truncated.load(.monotonic));
    const long = comptime blk: {
        var bytes: [129]u8 = @splat('s');
        bytes[127] = 0xc3; // 'é' does not fit in 128 bytes
        bytes[128] = 0xa9;
        break :blk bytes;
    };
    try testing.expectEqualStrings(&@as([127]u8, @splat('s')), table.find(&long).name());
    try testing.expectEqual(@as(u64, 1), table.names_truncated.load(.monotonic));
}

test "threads adding the same new name get one entry" {
    const table = try newTable(.info, &.{});
    defer testing.allocator.destroy(table);
    var found: [8]*const Entry = undefined;
    var threads: [8]std.Thread = undefined;
    for (&threads, &found) |*thread, *slot| thread.* = try std.Thread.spawn(.{}, findInto, .{ table, slot });
    for (threads) |thread| thread.join();
    for (found) |entry| try testing.expect(entry == found[0]);
    try testing.expectEqual(@as(u32, 1), table.count.load(.monotonic));
}

fn findInto(table: *Table, slot: **const Entry) void {
    slot.* = table.find("shared.scope");
}
