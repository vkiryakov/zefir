//! A store of records in memory, with the lifecycle of a client of a
//! database: `start` opens it, where a client would connect; `shutdown`
//! closes it, where a client would close its connections by the deadline;
//! `deinit` frees its memory. Each record is a number and a text under an
//! id the store gives, 1, 2, and so on: a stand-in for the documents of a
//! real database.

const std = @import("std");

const Store = @This();

gpa: std.mem.Allocator,
/// Guards the fields below: the servers run their requests on many tasks.
mutex: std.Io.Mutex = .init,
records: std.ArrayList(Record) = .empty,
open: bool = false,

/// What the number means is up to the module that keeps the records: the
/// orders keep the id of their user in it.
pub const Record = struct {
    number: u64 = 0,
    text: []const u8,
};

pub fn init(gpa: std.mem.Allocator) Store {
    return .{ .gpa = gpa };
}

/// Opens the store.
pub fn start(store: *Store, io: std.Io) !void {
    try store.mutex.lock(io);
    defer store.mutex.unlock(io);
    store.open = true;
}

/// Closes the store: from now on it refuses every call with
/// `error.Unavailable`.
pub fn shutdown(store: *Store, io: std.Io, deadline: std.Io.Clock.Timestamp) !void {
    _ = deadline; // Closing a store in memory takes no time.
    try store.mutex.lock(io);
    defer store.mutex.unlock(io);
    store.open = false;
}

pub fn deinit(store: *Store) void {
    for (store.records.items) |record| store.gpa.free(record.text);
    store.records.deinit(store.gpa);
}

/// Keeps a copy of `record` and returns its id.
pub fn insert(store: *Store, io: std.Io, record: Record) !u64 {
    const text = try store.gpa.dupe(u8, record.text);
    errdefer store.gpa.free(text);
    try store.mutex.lock(io);
    defer store.mutex.unlock(io);
    if (!store.open) return error.Unavailable;
    try store.records.append(store.gpa, .{ .number = record.number, .text = text });
    return store.records.items.len;
}

/// The record `id`, its text copied into `arena`; null when there is none.
pub fn find(store: *Store, io: std.Io, arena: std.mem.Allocator, id: u64) !?Record {
    try store.mutex.lock(io);
    defer store.mutex.unlock(io);
    if (!store.open) return error.Unavailable;
    if (id == 0 or id > store.records.items.len) return null;
    const record = store.records.items[id - 1];
    return .{ .number = record.number, .text = try arena.dupe(u8, record.text) };
}
