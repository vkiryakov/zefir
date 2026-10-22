//! The driver contract of odm: odm reaches a database only through it.
//! A driver is three types, each handed out through its interface:
//!
//! - a driver, with `pub const name: []const u8` and `open`, as
//!   `odm.Driver.init(&driver)`;
//! - a client of one server and login, with the methods of
//!   `odm.Client.VTable` and `pub const capabilities: odm.Capabilities`,
//!   as `odm.Client.init(client)` from `open`;
//! - a cursor, with `next` and `deinit`, as `odm.RawCursor.init(cursor)`
//!   from `find` and `aggregate`.
//!
//! ```zig
//! pub fn driver(self: *MyDriver) odm.Driver {
//!     return .init(self);
//! }
//! ```
//!
//! A mistake in a method stops the build with a message that names the
//! method and the signature to write. zefir-mongo's `mongo.OdmDriver` is
//! the reference driver, and `odm.testing.FakeDriver` a driver without a
//! network; a driver is "zefir compatible" when it passes
//! `odm.testing.conformance`. The rules:
//!
//! 1. Concurrency. Any number of tasks and threads call a `Client` at
//!    once; the driver guards what they share with `std.Io` primitives. A
//!    `RawCursor` serves one task at a time.
//! 2. `io` is the instance that the client was opened with (`Driver.open`),
//!    and every wait goes through it.
//! 3. `open` does no network I/O: it checks the settings, copies them and
//!    readies the pool. `connect` checks both the link and the login; it
//!    may be called again after a failure, and does nothing on a client
//!    that is connected.
//! 4. The deadline of `ctx`. With less than 1 ms left before sending, the
//!    call is `error.DeadlineExceeded`, and nothing went out. Otherwise the
//!    driver waits no longer than the deadline (zefir-mongo also sends
//!    `maxTimeMS`); when it passes after sending, the call is
//!    `error.Timeout`.
//! 5. Cancelation. The driver checks the token before sending
//!    (`error.Cancelled`) and after the reply (`error.Interrupted`).
//!    Canceling the task ends a wait, and the task keeps its cancelation.
//! 6. Memory. The request and its slices are borrowed until the call
//!    returns. What the result points to (`upserted_id`, the reply of a
//!    command) comes from `options.allocator`, during the call only. A
//!    document of `RawCursor.next` is borrowed until the next call of the
//!    cursor. After a call the driver holds no reference to the caller's
//!    memory.
//! 7. Writes. Each document of `insert` has its `_id` already: the driver
//!    sends the documents as they are, in order, and stops at the first
//!    one that the server refused. A refusal of a unique index (code
//!    11000) is `error.DuplicateKey` with `Diagnostics.index`, any other
//!    `error.WriteFailed`. An `update` of mode `.replace` holds the whole
//!    document in `update`, without `_id`.
//! 8. A `find` with `limit = 1` leaves no cursor open on the server.
//! 9. `close` refuses new calls (`error.Closed`), cuts the calls in flight
//!    at once, closes the cursors that the server holds within a short
//!    budget of its own and closes the connections. A second `close`
//!    waits for the first. The task's cancelation waits until it returns.
//!    After `close`, `next` of its cursors is `error.Closed` without I/O.
//! 10. `deinit` frees memory and does no I/O; it comes after `close` and
//!    after `deinit` of every cursor of the client.
//! 11. Errors. Only `odm.DriverError`, each name in its class of
//!    `odm.outcome`. The texts of `Diagnostics` never hold a password.
//! 12. No retries: the driver sends each command at most once.
//! 13. The capabilities are exactly the optional methods that the type of
//!    the client declares.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const bson = @import("mongo-bson");
const errors = @import("errors.zig");
const signature = @import("signature.zig");
const DriverError = errors.DriverError;
const Diagnostics = errors.Diagnostics;

/// The settings of one connection: a server and a login. The driver copies
/// them in `open`; they are borrowed for that call only.
pub const ConnectionConfig = struct {
    /// The connection string of the driver. The user and the pool are its
    /// options (zefir-mongo:
    /// mongodb://user@host:27017/?maxPoolSize=20&maxIdleTimeMS=60000).
    uri: []const u8,
    /// The password of the user of `uri`, when the string holds none.
    password: ?[]const u8 = null,
    /// Why the driver refused the settings or did not connect; it never
    /// holds the password.
    diagnostics: ?*Diagnostics = null,

    /// zefir-log writes the settings as "[REDACTED]".
    pub const zefir_sensitive = true;
};

/// The operations of a client beyond those every driver has: `connect`,
/// `ping`, `close`, `deinit`, `stats`, `insert`, `update`, `delete` and
/// `find`. Without one, odm's call needing it is `error.Unsupported`.
pub const Capabilities = struct {
    aggregate: bool = false,
    count: bool = false,
    /// `createIndexes`.
    indexes: bool = false,
    command: bool = false,
};

/// A driver: it opens clients by their settings.
pub const Driver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// The driver behind the interface: one constant table per driver type,
    /// built by `init`.
    pub const VTable = struct {
        name: []const u8,
        open: *const fn (ptr: *anyopaque, io: Io, config: *const ConnectionConfig) OpenError!Client,
    };

    /// Settings that the driver cannot take (`InvalidArgument`), or that it
    /// does not do (`Unsupported`), such as an option of the connection
    /// string it lacks; `config.diagnostics` says which.
    pub const OpenError = error{ InvalidArgument, Unsupported, OutOfMemory };

    /// The driver's name, such as "zefir-mongo".
    pub fn name(d: Driver) []const u8 {
        return d.vtable.name;
    }

    /// A client of the settings, without network I/O (rule 3): its
    /// `connect` makes the first connection.
    pub fn open(d: Driver, io: Io, config: *const ConnectionConfig) OpenError!Client {
        return d.vtable.open(d.ptr, io, config);
    }

    const interface = "odm.Driver";

    /// The interface of `impl: *T`, where `T` has `pub const name: []const u8`
    /// and `pub fn open(self: *T, io: std.Io, config: *const
    /// odm.ConnectionConfig) odm.Driver.OpenError!odm.Client`. The table is
    /// built at compile time; a missing declaration or another signature
    /// stops the build with a message that names it.
    pub fn init(impl: anytype) Driver {
        const Ptr = @TypeOf(impl);
        const T = signature.expectPointer(interface, "driver", Ptr);
        comptime {
            if (!@hasDecl(T, "name") or !isString(@TypeOf(T.name)))
                @compileError(interface ++ ".init: " ++ @typeName(T) ++ " has no pub const name: []const u8");
            signature.expectMethod(interface, T, "open", fn (Ptr, Io, *const ConnectionConfig) OpenError!Client, "pub fn open(self: *@This(), io: std.Io, config: *const odm.ConnectionConfig) odm.Driver.OpenError!odm.Client");
        }
        const gen = struct {
            fn openFn(ptr: *anyopaque, io: Io, config: *const ConnectionConfig) OpenError!Client {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                return T.open(self, io, config);
            }
            const vtable: VTable = .{ .name = T.name, .open = openFn };
        };
        return .{ .ptr = impl, .vtable = &gen.vtable };
    }
};

/// A client of a driver: one server and login, with its pool. The
/// wrappers below call the driver by the rules at the top of this file.
pub const Client = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// The client behind the interface: one constant table per client type,
    /// built by `init`. An optional operation is null when the client lacks
    /// its capability.
    pub const VTable = struct {
        capabilities: Capabilities,
        connect: *const fn (ptr: *anyopaque, io: Io, ctx: core.Context, d: ?*Diagnostics) DriverError!void,
        ping: *const fn (ptr: *anyopaque, io: Io, ctx: core.Context, d: ?*Diagnostics) DriverError!void,
        close: *const fn (ptr: *anyopaque, io: Io) void,
        deinit: *const fn (ptr: *anyopaque) void,
        stats: *const fn (ptr: *anyopaque) ?PoolStats,
        insert: *const fn (ptr: *anyopaque, io: Io, ctx: core.Context, request: *const InsertRequest, options: CallOptions) DriverError!InsertResult,
        update: *const fn (ptr: *anyopaque, io: Io, ctx: core.Context, request: *const UpdateRequest, options: CallOptions) DriverError!UpdateResult,
        delete: *const fn (ptr: *anyopaque, io: Io, ctx: core.Context, request: *const DeleteRequest, options: CallOptions) DriverError!DeleteResult,
        find: *const fn (ptr: *anyopaque, io: Io, ctx: core.Context, request: *const FindRequest, options: CallOptions) DriverError!RawCursor,
        aggregate: ?*const fn (ptr: *anyopaque, io: Io, ctx: core.Context, request: *const AggregateRequest, options: CallOptions) DriverError!RawCursor,
        count: ?*const fn (ptr: *anyopaque, io: Io, ctx: core.Context, request: *const CountRequest, options: CallOptions) DriverError!u64,
        create_indexes: ?*const fn (ptr: *anyopaque, io: Io, ctx: core.Context, request: *const IndexRequest, options: CallOptions) DriverError!void,
        command: ?*const fn (ptr: *anyopaque, io: Io, ctx: core.Context, request: *const CommandRequest, options: CallOptions) DriverError!bson.RawDocument,
    };

    /// A collection of a database.
    pub const Namespace = struct { database: []const u8, collection: []const u8 };

    pub const CallOptions = struct {
        /// The memory of what the result points to; usually the arena of
        /// odm's call.
        allocator: Allocator,
        /// When not null, the driver puts the details of an error here.
        diagnostics: ?*Diagnostics = null,
    };

    /// Documents to insert, each with its `_id` (rule 7).
    pub const InsertRequest = struct { ns: Namespace, documents: []const bson.RawDocument };
    pub const InsertResult = struct { inserted: u64 };

    pub const UpdateMode = enum { one, many, replace };

    pub const UpdateRequest = struct {
        ns: Namespace,
        filter: bson.RawDocument,
        /// The operators (`$set`…) for `.one` and `.many`; the document
        /// without `_id` for `.replace`.
        update: bson.RawDocument,
        mode: UpdateMode,
        upsert: bool = false,
    };

    pub const UpdateResult = struct {
        matched: u64,
        modified: u64,
        /// The `_id` of the document that an upsert inserted; its bytes are
        /// in `options.allocator`.
        upserted_id: ?bson.Value = null,
    };

    pub const DeleteRequest = struct { ns: Namespace, filter: bson.RawDocument, many: bool };
    pub const DeleteResult = struct { deleted: u64 };

    pub const FindRequest = struct {
        ns: Namespace,
        filter: bson.RawDocument,
        sort: ?bson.RawDocument = null,
        projection: ?bson.RawDocument = null,
        skip: u32 = 0,
        /// 0: no limit. 1 leaves no cursor on the server (rule 8).
        limit: u32 = 0,
        batch_size: ?u32 = null,
    };

    pub const AggregateRequest = struct { ns: Namespace, pipeline: []const bson.RawDocument, batch_size: ?u32 = null };
    pub const CountRequest = struct { ns: Namespace, filter: bson.RawDocument };

    /// One index to create.
    pub const IndexSpec = struct {
        name: []const u8,
        keys: bson.RawDocument,
        unique: bool = false,
        sparse: bool = false,
        expire_after_seconds: ?u32 = null,
    };

    pub const IndexRequest = struct { ns: Namespace, indexes: []const IndexSpec };

    /// Any command, run in `database`.
    pub const CommandRequest = struct { database: []const u8, body: bson.RawDocument };

    /// The pool of the driver: the odm_pool_connections_* of the metrics.
    pub const PoolStats = struct { connections: usize, idle: usize, in_use: usize, waiting: usize };

    /// Checks the link and the login (rule 3); `d` says why it failed.
    pub fn connect(c: Client, io: Io, ctx: core.Context, d: ?*Diagnostics) DriverError!void {
        return c.vtable.connect(c.ptr, io, ctx, d);
    }

    /// One round trip to the server.
    pub fn ping(c: Client, io: Io, ctx: core.Context, d: ?*Diagnostics) DriverError!void {
        return c.vtable.ping(c.ptr, io, ctx, d);
    }

    /// Ends the client's work (rule 9).
    pub fn close(c: Client, io: Io) void {
        c.vtable.close(c.ptr, io);
    }

    /// Frees the client, after `close` and after its cursors (rule 10).
    pub fn deinit(c: Client) void {
        c.vtable.deinit(c.ptr);
    }

    /// A snapshot of the pool, or null when the driver keeps none.
    pub fn stats(c: Client) ?PoolStats {
        return c.vtable.stats(c.ptr);
    }

    pub fn insert(c: Client, io: Io, ctx: core.Context, request: *const InsertRequest, options: CallOptions) DriverError!InsertResult {
        return c.vtable.insert(c.ptr, io, ctx, request, options);
    }

    pub fn update(c: Client, io: Io, ctx: core.Context, request: *const UpdateRequest, options: CallOptions) DriverError!UpdateResult {
        return c.vtable.update(c.ptr, io, ctx, request, options);
    }

    pub fn delete(c: Client, io: Io, ctx: core.Context, request: *const DeleteRequest, options: CallOptions) DriverError!DeleteResult {
        return c.vtable.delete(c.ptr, io, ctx, request, options);
    }

    /// A cursor over the documents that match; `deinit` it.
    pub fn find(c: Client, io: Io, ctx: core.Context, request: *const FindRequest, options: CallOptions) DriverError!RawCursor {
        return c.vtable.find(c.ptr, io, ctx, request, options);
    }

    /// A cursor over the documents of the pipeline; `error.Unsupported`
    /// without the capability `aggregate`.
    pub fn aggregate(c: Client, io: Io, ctx: core.Context, request: *const AggregateRequest, options: CallOptions) DriverError!RawCursor {
        const f = c.vtable.aggregate orelse return unsupported(options.diagnostics, "aggregate");
        return f(c.ptr, io, ctx, request, options);
    }

    /// `error.Unsupported` without the capability `count`.
    pub fn count(c: Client, io: Io, ctx: core.Context, request: *const CountRequest, options: CallOptions) DriverError!u64 {
        const f = c.vtable.count orelse return unsupported(options.diagnostics, "count");
        return f(c.ptr, io, ctx, request, options);
    }

    /// `error.Unsupported` without the capability `indexes`.
    pub fn createIndexes(c: Client, io: Io, ctx: core.Context, request: *const IndexRequest, options: CallOptions) DriverError!void {
        const f = c.vtable.create_indexes orelse return unsupported(options.diagnostics, "indexes");
        return f(c.ptr, io, ctx, request, options);
    }

    /// The server's reply, from `options.allocator`; `error.Unsupported`
    /// without the capability `command`.
    pub fn command(c: Client, io: Io, ctx: core.Context, request: *const CommandRequest, options: CallOptions) DriverError!bson.RawDocument {
        const f = c.vtable.command orelse return unsupported(options.diagnostics, "command");
        return f(c.ptr, io, ctx, request, options);
    }

    pub fn capabilities(c: Client) Capabilities {
        return c.vtable.capabilities;
    }

    /// The error of an operation whose capability the client lacks, which
    /// `d` names; the call starts `d` afresh, as a driver's call does.
    fn unsupported(d: ?*Diagnostics, comptime capability: []const u8) error{Unsupported} {
        if (d) |x| {
            x.* = .{};
            x.set(null, null, "odm: the driver has no capability '" ++ capability ++ "'", .{});
        }
        return error.Unsupported;
    }

    const interface = "odm.Client";

    /// The interface of `impl: *T`, where `T` has
    /// `pub const capabilities: odm.Capabilities` and the methods of
    /// `VTable` with `self: *T` in place of `*anyopaque`: `aggregate`,
    /// `count`, `createIndexes` and `command` exactly when their
    /// capability is true (rule 13). The table is built at compile time; a
    /// missing method, an extra one, or another signature stops the build
    /// with a message that names it and the signature to write.
    pub fn init(impl: anytype) Client {
        const Ptr = @TypeOf(impl);
        const T = signature.expectPointer(interface, "client", Ptr);
        const caps: Capabilities = comptime capabilitiesOf(T);
        comptime {
            signature.expectMethod(interface, T, "connect", fn (Ptr, Io, core.Context, ?*Diagnostics) DriverError!void, "pub fn connect(self: *@This(), io: std.Io, ctx: core.Context, d: ?*odm.Diagnostics) odm.DriverError!void");
            signature.expectMethod(interface, T, "ping", fn (Ptr, Io, core.Context, ?*Diagnostics) DriverError!void, "pub fn ping(self: *@This(), io: std.Io, ctx: core.Context, d: ?*odm.Diagnostics) odm.DriverError!void");
            signature.expectMethod(interface, T, "close", fn (Ptr, Io) void, "pub fn close(self: *@This(), io: std.Io) void");
            signature.expectMethod(interface, T, "deinit", fn (Ptr) void, "pub fn deinit(self: *@This()) void");
            signature.expectMethod(interface, T, "stats", fn (Ptr) ?PoolStats, "pub fn stats(self: *@This()) ?odm.Client.PoolStats");
            signature.expectMethod(interface, T, "insert", fn (Ptr, Io, core.Context, *const InsertRequest, CallOptions) DriverError!InsertResult, operation("insert", "InsertRequest", "odm.Client.InsertResult"));
            signature.expectMethod(interface, T, "update", fn (Ptr, Io, core.Context, *const UpdateRequest, CallOptions) DriverError!UpdateResult, operation("update", "UpdateRequest", "odm.Client.UpdateResult"));
            signature.expectMethod(interface, T, "delete", fn (Ptr, Io, core.Context, *const DeleteRequest, CallOptions) DriverError!DeleteResult, operation("delete", "DeleteRequest", "odm.Client.DeleteResult"));
            signature.expectMethod(interface, T, "find", fn (Ptr, Io, core.Context, *const FindRequest, CallOptions) DriverError!RawCursor, operation("find", "FindRequest", "odm.RawCursor"));
            expectOptional(T, caps.aggregate, "aggregate", "aggregate", fn (Ptr, Io, core.Context, *const AggregateRequest, CallOptions) DriverError!RawCursor, operation("aggregate", "AggregateRequest", "odm.RawCursor"));
            expectOptional(T, caps.count, "count", "count", fn (Ptr, Io, core.Context, *const CountRequest, CallOptions) DriverError!u64, operation("count", "CountRequest", "u64"));
            expectOptional(T, caps.indexes, "indexes", "createIndexes", fn (Ptr, Io, core.Context, *const IndexRequest, CallOptions) DriverError!void, operation("createIndexes", "IndexRequest", "void"));
            expectOptional(T, caps.command, "command", "command", fn (Ptr, Io, core.Context, *const CommandRequest, CallOptions) DriverError!bson.RawDocument, operation("command", "CommandRequest", "bson.RawDocument"));
        }
        const gen = struct {
            fn self(ptr: *anyopaque) Ptr {
                return @ptrCast(@alignCast(ptr));
            }
            fn connectFn(ptr: *anyopaque, io: Io, ctx: core.Context, d: ?*Diagnostics) DriverError!void {
                return T.connect(self(ptr), io, ctx, d);
            }
            fn pingFn(ptr: *anyopaque, io: Io, ctx: core.Context, d: ?*Diagnostics) DriverError!void {
                return T.ping(self(ptr), io, ctx, d);
            }
            fn closeFn(ptr: *anyopaque, io: Io) void {
                T.close(self(ptr), io);
            }
            fn deinitFn(ptr: *anyopaque) void {
                T.deinit(self(ptr));
            }
            fn statsFn(ptr: *anyopaque) ?PoolStats {
                return T.stats(self(ptr));
            }
            fn insertFn(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const InsertRequest, options: CallOptions) DriverError!InsertResult {
                return T.insert(self(ptr), io, ctx, request, options);
            }
            fn updateFn(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const UpdateRequest, options: CallOptions) DriverError!UpdateResult {
                return T.update(self(ptr), io, ctx, request, options);
            }
            fn deleteFn(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const DeleteRequest, options: CallOptions) DriverError!DeleteResult {
                return T.delete(self(ptr), io, ctx, request, options);
            }
            fn findFn(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const FindRequest, options: CallOptions) DriverError!RawCursor {
                return T.find(self(ptr), io, ctx, request, options);
            }
            fn aggregateFn(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const AggregateRequest, options: CallOptions) DriverError!RawCursor {
                return T.aggregate(self(ptr), io, ctx, request, options);
            }
            fn countFn(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const CountRequest, options: CallOptions) DriverError!u64 {
                return T.count(self(ptr), io, ctx, request, options);
            }
            fn createIndexesFn(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const IndexRequest, options: CallOptions) DriverError!void {
                return T.createIndexes(self(ptr), io, ctx, request, options);
            }
            fn commandFn(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const CommandRequest, options: CallOptions) DriverError!bson.RawDocument {
                return T.command(self(ptr), io, ctx, request, options);
            }
            const vtable: VTable = .{
                .capabilities = caps,
                .connect = connectFn,
                .ping = pingFn,
                .close = closeFn,
                .deinit = deinitFn,
                .stats = statsFn,
                .insert = insertFn,
                .update = updateFn,
                .delete = deleteFn,
                .find = findFn,
                .aggregate = if (caps.aggregate) aggregateFn else null,
                .count = if (caps.count) countFn else null,
                .create_indexes = if (caps.indexes) createIndexesFn else null,
                .command = if (caps.command) commandFn else null,
            };
        };
        return .{ .ptr = impl, .vtable = &gen.vtable };
    }

    /// The capabilities that `T` declares.
    fn capabilitiesOf(comptime T: type) Capabilities {
        if (!@hasDecl(T, "capabilities") or @TypeOf(T.capabilities) != Capabilities)
            @compileError(interface ++ ".init: " ++ @typeName(T) ++ " has no pub const capabilities: odm.Capabilities");
        return T.capabilities;
    }

    /// Stops the build unless `T` has the method of an optional operation
    /// exactly when its capability is `on`, and of type `Expected`.
    fn expectOptional(
        comptime T: type,
        comptime on: bool,
        comptime capability: []const u8,
        comptime method: []const u8,
        comptime Expected: type,
        comptime declaration: []const u8,
    ) void {
        if (!on) {
            if (@hasDecl(T, method))
                @compileError(interface ++ ".init: " ++ @typeName(T) ++ " has a method " ++ method ++ ", but capabilities." ++ capability ++ " is false");
            return;
        }
        if (!@hasDecl(T, method))
            @compileError(interface ++ ".init: " ++ @typeName(T) ++ ".capabilities." ++ capability ++ " is true, but " ++ @typeName(T) ++ " has no method " ++ method ++ "; expected " ++ declaration);
        signature.expectMethod(interface, T, method, Expected, declaration);
    }

    /// How to declare the method of an operation, for the messages.
    fn operation(comptime method: []const u8, comptime request: []const u8, comptime result: []const u8) []const u8 {
        return "pub fn " ++ method ++ "(self: *@This(), io: std.Io, ctx: core.Context, request: *const odm.Client." ++ request ++ ", options: odm.Client.CallOptions) odm.DriverError!" ++ result;
    }
};

/// The documents of a `find` or an `aggregate`, from a driver. It serves one
/// task at a time.
pub const RawCursor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// The cursor behind the interface: one constant table per cursor type,
    /// built by `init`.
    pub const VTable = struct {
        next: *const fn (ptr: *anyopaque, io: Io, ctx: core.Context, d: ?*Diagnostics) DriverError!?bson.RawDocument,
        /// Closes the cursor on the server, if it is open there, and frees
        /// it.
        deinit: *const fn (ptr: *anyopaque, io: Io) void,
    };

    /// The next document, borrowed until the next call of the cursor; null
    /// at the end. After `close` of its client, `error.Closed` without I/O.
    pub fn next(c: RawCursor, io: Io, ctx: core.Context, d: ?*Diagnostics) DriverError!?bson.RawDocument {
        return c.vtable.next(c.ptr, io, ctx, d);
    }

    /// Closes the cursor on the server, if it is open there, and frees it.
    pub fn deinit(c: RawCursor, io: Io) void {
        c.vtable.deinit(c.ptr, io);
    }

    const interface = "odm.RawCursor";

    /// The interface of `impl: *T`, where `T` has `pub fn next(self: *T, io:
    /// std.Io, ctx: core.Context, d: ?*odm.Diagnostics)
    /// odm.DriverError!?bson.RawDocument` and `pub fn deinit(self: *T, io:
    /// std.Io) void`. The table is built at compile time; a missing method
    /// or another signature stops the build with a message that names it.
    pub fn init(impl: anytype) RawCursor {
        const Ptr = @TypeOf(impl);
        const T = signature.expectPointer(interface, "cursor", Ptr);
        comptime {
            signature.expectMethod(interface, T, "next", fn (Ptr, Io, core.Context, ?*Diagnostics) DriverError!?bson.RawDocument, "pub fn next(self: *@This(), io: std.Io, ctx: core.Context, d: ?*odm.Diagnostics) odm.DriverError!?bson.RawDocument");
            signature.expectMethod(interface, T, "deinit", fn (Ptr, Io) void, "pub fn deinit(self: *@This(), io: std.Io) void");
        }
        const gen = struct {
            fn nextFn(ptr: *anyopaque, io: Io, ctx: core.Context, d: ?*Diagnostics) DriverError!?bson.RawDocument {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                return T.next(self, io, ctx, d);
            }
            fn deinitFn(ptr: *anyopaque, io: Io) void {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                T.deinit(self, io);
            }
            const vtable: VTable = .{ .next = nextFn, .deinit = deinitFn };
        };
        return .{ .ptr = impl, .vtable = &gen.vtable };
    }
};

/// Whether a declaration of type `S` is a string: a slice of bytes or a
/// pointer to an array of them, as a string literal is.
fn isString(comptime S: type) bool {
    return switch (@typeInfo(S)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}
