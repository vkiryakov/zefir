//! `mongo.OdmDriver`: zefir-mongo under the driver contract of zefir-odm,
//! its reference driver. Hand it to the registry; it lives longer than the
//! registry does:
//!
//! ```zig
//! var driver: mongo.OdmDriver = .init(gpa);
//! var registry: odm.Registry = .init(gpa, io, driver.driver(), .{});
//! defer registry.deinit(io);
//! ```
//!
//! Each client that odm opens is a `mongo.Client` of the connection string
//! of its connection, in the heap of `gpa`. `open` does no I/O; the pool,
//! the deadlines, cancelation and SCRAM are those of `mongo.Client`, and
//! the operations are those of `mongo.Collection`: odm's insert is
//! `insertMany`, ordered, update `updateOne`, `updateMany` or `replaceOne`,
//! find `find`, or `findOne` with `limit = 1`, so that no cursor stays open
//! on the server, count `countDocuments`, and a command
//! `mongo.Database.runCommand`. The documents of an insert come with their
//! `_id`, and go as they are.
//!
//! The clients close with a `close_timeout` of 0: odm closes a connection
//! once the leases of its sessions and cursors came back, or once its
//! drain ran out, so the calls left then are cut at once.
//!
//! The errors of zefir-mongo pass under their names. A write that the
//! server refused for a unique index (codes 11000, 11001 and 12582) is
//! `error.DuplicateKey`, any other refusal `error.WriteFailed`;
//! `Diagnostics.index` names the document, in the list of the call. The
//! text of the diagnostics is that of `mongo.Diagnostics`, the server's
//! errmsg or the driver's text, and its code the server's: it never holds
//! the password.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const bson = @import("mongo-bson");
const odm = @import("odm");
const mongo = @import("root.zig");
const OdmDriver = @This();

/// The memory of the clients, their pools and their cursors; it must be
/// thread-safe, as `std.heap.smp_allocator` is.
gpa: Allocator,

pub const name = "zefir-mongo";

pub fn init(gpa: Allocator) OdmDriver {
    return .{ .gpa = gpa };
}

/// The driver for `odm.Registry.init`; `self` stays where it is while the
/// registry uses it.
pub fn driver(self: *OdmDriver) odm.Driver {
    return .init(self);
}

/// A `mongo.Client` of `config`, without I/O: the connection string is
/// read and checked, and the password copied. Why the settings were
/// refused goes to `config.diagnostics`.
pub fn open(self: *OdmDriver, io: Io, config: *const odm.ConnectionConfig) odm.Driver.OpenError!odm.Client {
    const d = config.diagnostics;
    if (d) |x| x.* = .{};
    const c = try self.gpa.create(Client);
    errdefer self.gpa.destroy(c);
    var md: mongo.Diagnostics = .{};
    c.* = .{
        .gpa = self.gpa,
        .client = mongo.Client.init(self.gpa, io, .{
            .uri = config.uri,
            .password = config.password,
            .close_timeout = .fromSeconds(0),
            .diagnostics = &md,
        }) catch |err| {
            if (d) |x| x.set(null, null, "{s}", .{md.message()});
            return err;
        },
        .ids = .init(io),
    };
    return .init(c);
}

/// A client of odm: a `mongo.Client` in the heap, which stays where
/// `connect` ran, as `mongo.Client` must.
const Client = struct {
    gpa: Allocator,
    client: mongo.Client,
    /// For `mongo.Database` only: odm's documents come with their `_id`.
    ids: bson.ObjectId.Generator,
    /// Set by `close`: the cursors of `find` with `limit = 1` are
    /// `error.Closed` from then on, as those of the server are.
    closed: std.atomic.Value(bool) = .init(false),

    pub const capabilities: odm.Capabilities = .{ .aggregate = true, .count = true, .indexes = true, .command = true };

    pub fn connect(c: *Client, io: Io, ctx: core.Context, d: ?*odm.Diagnostics) odm.DriverError!void {
        if (d) |x| x.* = .{};
        var md: mongo.Diagnostics = .{};
        c.client.connect(io, ctx, &md) catch |err| return failed(d, err, &md, null);
    }

    pub fn ping(c: *Client, io: Io, ctx: core.Context, d: ?*odm.Diagnostics) odm.DriverError!void {
        if (d) |x| x.* = .{};
        var md: mongo.Diagnostics = .{};
        const reply = c.client.runCommand(io, .of(ctx), .{ .database = "admin", .body = ping_command }, .{ .allocator = c.gpa, .diagnostics = &md }) catch |err|
            return failed(d, err, &md, null);
        reply.deinit();
    }

    pub fn close(c: *Client, io: Io) void {
        c.closed.store(true, .release);
        c.client.close(io);
    }

    pub fn deinit(c: *Client) void {
        const gpa = c.gpa;
        c.client.deinit();
        gpa.destroy(c);
    }

    pub fn stats(c: *Client) ?odm.Client.PoolStats {
        const s = c.client.stats();
        return .{ .connections = s.connections, .idle = s.idle, .in_use = s.in_use, .waiting = s.waiting };
    }

    pub fn insert(c: *Client, io: Io, ctx: core.Context, request: *const odm.Client.InsertRequest, options: odm.Client.CallOptions) odm.DriverError!odm.Client.InsertResult {
        const d = options.diagnostics;
        if (d) |x| x.* = .{};
        var md: mongo.Diagnostics = .{};
        var partial: mongo.Collection.InsertManyResult = .{};
        defer partial.deinit(options.allocator);
        var result = c.collection(request.ns).insertMany(io, .of(ctx), request.documents, .{
            .allocator = options.allocator,
            .diagnostics = &md,
            .partial = &partial,
        }) catch |err| return refused(d, err, &md, partial.write_errors);
        defer result.deinit(options.allocator);
        return .{ .inserted = result.inserted };
    }

    pub fn update(c: *Client, io: Io, ctx: core.Context, request: *const odm.Client.UpdateRequest, options: odm.Client.CallOptions) odm.DriverError!odm.Client.UpdateResult {
        const d = options.diagnostics;
        if (d) |x| x.* = .{};
        var md: mongo.Diagnostics = .{};
        var partial: mongo.Collection.UpdateResult = .{};
        defer partial.deinit(options.allocator);
        const target = c.collection(request.ns);
        const op: mongo.OperationContext = .of(ctx);
        const changes: mongo.Collection.UpdateOptions = .{ .allocator = options.allocator, .upsert = request.upsert, .diagnostics = &md, .partial = &partial };
        const result = switch (request.mode) {
            .one => target.updateOne(io, op, request.filter, request.update, changes),
            .many => target.updateMany(io, op, request.filter, request.update, changes),
            .replace => target.replaceOne(io, op, request.filter, request.update, .{ .allocator = options.allocator, .upsert = request.upsert, .diagnostics = &md, .partial = &partial }),
        } catch |err| return refused(d, err, &md, partial.write_errors);
        // The `_id` of an upsert is the caller's now, in its allocator.
        return .{ .matched = result.matched, .modified = result.modified, .upserted_id = result.upserted_id };
    }

    pub fn delete(c: *Client, io: Io, ctx: core.Context, request: *const odm.Client.DeleteRequest, options: odm.Client.CallOptions) odm.DriverError!odm.Client.DeleteResult {
        const d = options.diagnostics;
        if (d) |x| x.* = .{};
        var md: mongo.Diagnostics = .{};
        var partial: mongo.Collection.DeleteResult = .{};
        defer partial.deinit(options.allocator);
        const target = c.collection(request.ns);
        const op: mongo.OperationContext = .of(ctx);
        const removal: mongo.Collection.DeleteOptions = .{ .allocator = options.allocator, .diagnostics = &md, .partial = &partial };
        const result = (if (request.many) target.deleteMany(io, op, request.filter, removal) else target.deleteOne(io, op, request.filter, removal)) catch |err|
            return refused(d, err, &md, partial.write_errors);
        return .{ .deleted = result.deleted };
    }

    pub fn find(c: *Client, io: Io, ctx: core.Context, request: *const odm.Client.FindRequest, options: odm.Client.CallOptions) odm.DriverError!odm.RawCursor {
        const d = options.diagnostics;
        if (d) |x| x.* = .{};
        var md: mongo.Diagnostics = .{};
        const target = c.collection(request.ns);
        const op: mongo.OperationContext = .of(ctx);
        if (request.limit == 1) {
            // findOne sends singleBatch, and frees its cursor before it
            // returns: none stays on the server (rule 8 of the contract).
            const one = try c.gpa.create(OneDocument);
            errdefer c.gpa.destroy(one);
            const doc = target.findOne(io, op, request.filter, .{
                .allocator = c.gpa,
                .sort = request.sort,
                .projection = request.projection,
                .skip = request.skip,
                .diagnostics = &md,
            }) catch |err| return failed(d, err, &md, null);
            one.* = .{ .owner = c, .doc = doc };
            return .init(one);
        }
        const cursor = target.find(io, op, request.filter, .{
            .allocator = options.allocator,
            .sort = request.sort,
            .projection = request.projection,
            .skip = request.skip,
            .limit = request.limit,
            .batch_size = request.batch_size,
            .diagnostics = &md,
        }) catch |err| return failed(d, err, &md, null);
        return c.cursorOf(cursor);
    }

    pub fn aggregate(c: *Client, io: Io, ctx: core.Context, request: *const odm.Client.AggregateRequest, options: odm.Client.CallOptions) odm.DriverError!odm.RawCursor {
        const d = options.diagnostics;
        if (d) |x| x.* = .{};
        var md: mongo.Diagnostics = .{};
        const cursor = c.collection(request.ns).aggregate(io, .of(ctx), request.pipeline, .{
            .allocator = options.allocator,
            .batch_size = request.batch_size,
            .diagnostics = &md,
        }) catch |err| return failed(d, err, &md, null);
        return c.cursorOf(cursor);
    }

    pub fn count(c: *Client, io: Io, ctx: core.Context, request: *const odm.Client.CountRequest, options: odm.Client.CallOptions) odm.DriverError!u64 {
        const d = options.diagnostics;
        if (d) |x| x.* = .{};
        var md: mongo.Diagnostics = .{};
        return c.collection(request.ns).countDocuments(io, .of(ctx), request.filter, .{ .allocator = options.allocator, .diagnostics = &md }) catch |err|
            return failed(d, err, &md, null);
    }

    pub fn createIndexes(c: *Client, io: Io, ctx: core.Context, request: *const odm.Client.IndexRequest, options: odm.Client.CallOptions) odm.DriverError!void {
        const d = options.diagnostics;
        if (d) |x| x.* = .{};
        var md: mongo.Diagnostics = .{};
        const models = try options.allocator.alloc(mongo.Collection.IndexModel, request.indexes.len);
        defer options.allocator.free(models);
        for (models, request.indexes) |*model, spec| model.* = .{
            .keys = spec.keys,
            .name = spec.name,
            .unique = spec.unique,
            .sparse = spec.sparse,
            .expire_after_seconds = spec.expire_after_seconds,
        };
        const names = c.collection(request.ns).createIndexes(io, .of(ctx), models, .{ .allocator = options.allocator, .diagnostics = &md }) catch |err|
            return failed(d, err, &md, null);
        // The names are odm's own, in the request.
        for (names) |index_name| options.allocator.free(index_name);
        options.allocator.free(names);
    }

    pub fn command(c: *Client, io: Io, ctx: core.Context, request: *const odm.Client.CommandRequest, options: odm.Client.CallOptions) odm.DriverError!bson.RawDocument {
        const d = options.diagnostics;
        if (d) |x| x.* = .{};
        var md: mongo.Diagnostics = .{};
        const db: mongo.Database = .init(&c.client, request.database, &c.ids);
        const reply = db.runCommand(io, .of(ctx), request.body, .{ .allocator = options.allocator, .diagnostics = &md }) catch |err|
            return failed(d, err, &md, null);
        // In `options.allocator`: the caller's.
        return reply.raw();
    }

    fn collection(c: *Client, at: odm.Client.Namespace) mongo.Collection {
        const db: mongo.Database = .init(&c.client, at.database, &c.ids);
        return db.collection(at.collection);
    }

    /// The cursor of odm over `cursor`: the state that the client keeps,
    /// without an allocation of its own.
    fn cursorOf(c: *Client, cursor: mongo.Cursor) odm.DriverError!odm.RawCursor {
        if (cursor.state) |state| return .init(@as(*ServerCursor, @ptrCast(state)));
        // A cursor without documents and without a cursor on the server;
        // find and aggregate give none such, but the type allows it.
        const one = try c.gpa.create(OneDocument);
        one.* = .{ .owner = c, .doc = null };
        return .init(one);
    }
};

const ping_command = bson.literal(.{ .ping = 1 });

/// A cursor of the server, as `mongo.Cursor` keeps it: `ptr` is its
/// state in the client.
const ServerCursor = opaque {
    fn cursor(self: *ServerCursor) mongo.Cursor {
        return .{ .state = @ptrCast(@alignCast(self)) };
    }

    pub fn next(self: *ServerCursor, io: Io, ctx: core.Context, d: ?*odm.Diagnostics) odm.DriverError!?bson.RawDocument {
        if (d) |x| x.* = .{};
        const c = self.cursor();
        return c.next(io, .of(ctx)) catch |err| return failed(d, err, c.diagnostics(), null);
    }

    pub fn deinit(self: *ServerCursor, io: Io) void {
        self.cursor().deinit(io);
    }
};

/// The cursor of a `find` with `limit = 1`: the document that `findOne`
/// read, copied into the driver's memory, or none.
const OneDocument = struct {
    owner: *Client,
    doc: ?bson.OwnedDocument,
    given: bool = false,

    pub fn next(one: *OneDocument, io: Io, ctx: core.Context, d: ?*odm.Diagnostics) odm.DriverError!?bson.RawDocument {
        _ = io;
        _ = ctx;
        if (d) |x| x.* = .{};
        if (one.owner.closed.load(.acquire)) {
            if (d) |x| x.set(null, null, "the client of the cursor is closed", .{});
            return error.Closed;
        }
        if (one.given) return null;
        one.given = true;
        const doc = one.doc orelse return null;
        return doc.raw();
    }

    pub fn deinit(one: *OneDocument, io: Io) void {
        _ = io;
        if (one.doc) |doc| doc.deinit();
        one.owner.gpa.destroy(one);
    }
};

/// `err` of zefir-mongo as odm's, with the text and the server's code of
/// `md` in `d`, and `index` for the item of a write.
fn failed(d: ?*odm.Diagnostics, err: mongo.Error, md: *const mongo.Diagnostics, index: ?usize) odm.DriverError {
    // mongo's code 0: the reply had none.
    const code: ?i32 = if (md.server) |server| (if (server.code != 0) server.code else null) else null;
    if (d) |x| x.set(code, index, "{s}", .{md.message()});
    if (err == error.WriteFailed) if (code) |n| switch (n) {
        11000, 11001, 12582 => return error.DuplicateKey,
        else => {},
    };
    return err;
}

/// `err` of a write, with the first item that the server refused, by its
/// index in the list of the call.
fn refused(d: ?*odm.Diagnostics, err: mongo.Error, md: *const mongo.Diagnostics, write_errors: []const mongo.WriteError) odm.DriverError {
    return failed(d, err, md, if (write_errors.len > 0) write_errors[0].index else null);
}
