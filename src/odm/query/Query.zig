//! `odm.Query(T)`: a find built at run time, such as a search with
//! optional parts in an http handler.
//!
//! ```zig
//! var q = users.query(arena);
//! if (min_age) |age| q = q.where(.{ .age = .{ .gte = age } });
//! if (active_only) q = q.where(.{ .status = .active });
//! var page = try q.sort(.{ .age = .desc }).limit(50).execute(io, ctx);
//! defer page.deinit(io);
//! ```
//!
//! - Several `where` are an AND, in the order of the calls: one condition
//!   goes as it is, several as `{$and: [...]}`. Each literal is checked by
//!   the compiler and encoded into the arena of the query at once, so the
//!   query holds no pointer to the caller's values. The first error of a
//!   `where` stays, later ones change nothing, and the operation that runs
//!   the query returns it.
//! - `sort` replaces the sort before it; `sort`, `skip`, `limit` and
//!   `batchSize` take no memory.
//! - A query is a value: `a = q.where(x)` and `b = q.where(y)` do not see
//!   each other.
//! - Nothing goes to the network until `execute`, `executeAs`, `first` or
//!   `count`; each of them is an operation of the collection's session.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const bson = @import("mongo-bson");
const errors = @import("../errors.zig");
const driver = @import("../driver.zig");
const schema = @import("../model/schema.zig");
const filter_ = @import("filter.zig");
const options_ = @import("options.zig");
const operations = @import("../Collection.zig");
const Session = @import("../Session.zig");
const Cursor = @import("../Cursor.zig").Cursor;
const Error = errors.Error;

/// Whether `K` is the type of `.{}`.
fn isEmpty(comptime K: type) bool {
    return switch (@typeInfo(K)) {
        .@"struct" => |info| info.field_names.len == 0,
        else => false,
    };
}

/// A find of the model `T` built at run time; `users.query(arena)` gives
/// it. `arena` holds its conditions and the documents of `first`: an
/// arena, or any allocator that is freed whole, which outlives the query.
pub fn Query(comptime T: type) type {
    return struct {
        // The fields are for odm; the application uses the methods.

        session: *Session,
        arena: Allocator,
        conditions: filter_.Filter(T),
        order: Order = .{},
        skip_count: u32 = 0,
        limit_count: u32 = 0,
        batch_size: ?u32 = null,

        const Self = @This();

        /// A sort literal names each path of `T` once at most, and only its
        /// directions known at run time take a byte each.
        const storage = @max(1, schema.paths(T).len);

        /// The sort literal, copied by value, and the function that writes
        /// it as BSON, which knows its type.
        const Order = struct {
            bytes: [storage]u8 = undefined,
            write: ?*const fn (memory: Allocator, bytes: *const [storage]u8) Error!bson.RawDocument = null,
        };

        /// The query and `condition`: a filter literal of `T`, or an
        /// `odm.Filter(T)`.
        pub fn where(q: Self, condition: anytype) Self {
            var next = q;
            next.conditions = q.conditions.where(condition);
            return next;
        }

        /// The query with the sort `keys` in place of the one before: a
        /// literal of the paths of `T` with `.asc` or `.desc`, or an
        /// `odm.Direction` known at run time, in the order of its keys, as
        /// find takes it. `.{}` is no sort.
        pub fn sort(q: Self, keys: anytype) Self {
            const K = @TypeOf(keys);
            var next = q;
            if (comptime isEmpty(K)) {
                next.order = .{};
                return next;
            }
            next.order = .{ .write = &Writer(K).write };
            // A sort that the checks of find take fits `storage`; any other
            // one does not compile, as `Writer(K)` says why.
            const size = comptime @min(@sizeOf(K), storage);
            @memcpy(next.order.bytes[0..size], std.mem.asBytes(&keys)[0..size]);
            return next;
        }

        pub fn skip(q: Self, n: u32) Self {
            var next = q;
            next.skip_count = n;
            return next;
        }

        /// 0 is no limit.
        pub fn limit(q: Self, n: u32) Self {
            var next = q;
            next.limit_count = n;
            return next;
        }

        pub fn batchSize(q: Self, n: u32) Self {
            var next = q;
            next.batch_size = n;
            return next;
        }

        /// A cursor over the documents of the query; `deinit` it.
        pub fn execute(q: Self, io: Io, ctx: core.Context) Error!Cursor(T) {
            return q.executeAs(T, io, ctx);
        }

        /// As `execute`, with documents of `P`, a projection of the model.
        pub fn executeAs(q: Self, comptime P: type, io: Io, ctx: core.Context) Error!Cursor(P) {
            var call: operations.Call = undefined;
            const memory = call.begin(q.session, io);
            defer call.end();
            return call.finish(q.open(P, io, ctx, memory));
        }

        /// The first document of the query, decoded into the arena of the
        /// query, or null.
        pub fn first(q: Self, io: Io, ctx: core.Context) Error!?T {
            var call: operations.Call = undefined;
            const memory = call.begin(q.session, io);
            defer call.end();
            return call.finish(q.readFirst(io, ctx, memory));
        }

        /// How many documents the conditions of the query match; its sort,
        /// skip and limit do not count. The capability `count` of the
        /// driver, else `Unsupported`.
        pub fn count(q: Self, io: Io, ctx: core.Context) Error!u64 {
            var call: operations.Call = undefined;
            const memory = call.begin(q.session, io);
            defer call.end();
            return call.finish(operations.countIn(T, q.session, io, ctx, memory, q.conditions));
        }

        fn open(q: *const Self, comptime P: type, io: Io, ctx: core.Context, memory: Allocator) Error!Cursor(P) {
            const find = try q.findRequest(P, memory, q.limit_count, q.batch_size);
            return operations.openCursor(T, P, q.session, io, ctx, memory, &find);
        }

        fn readFirst(q: *const Self, io: Io, ctx: core.Context, memory: Allocator) Error!?T {
            const find = try q.findRequest(T, memory, 1, null);
            return operations.readFirst(T, T, q.session, io, ctx, memory, &find, q.arena);
        }

        /// The find of the query, in `memory`.
        fn findRequest(q: *const Self, comptime P: type, memory: Allocator, n: u32, batch: ?u32) Error!driver.Client.FindRequest {
            return .{
                .ns = operations.namespace(T, q.session),
                .filter = try operations.encodeFilter(T, memory, q.conditions, &q.session.diag),
                .sort = if (q.order.write) |write| try write(memory, &q.order.bytes) else null,
                .projection = try operations.projectionOf(T, P, memory),
                .skip = q.skip_count,
                .limit = n,
                .batch_size = batch,
            };
        }

        /// Writes a sort literal of type `K` that `sort` copied.
        fn Writer(comptime K: type) type {
            return struct {
                fn write(memory: Allocator, bytes: *const [storage]u8) Error!bson.RawDocument {
                    const keys: *align(1) const K = @ptrCast(bytes);
                    return options_.sort(T, memory, keys.*);
                }
            };
        }
    };
}
