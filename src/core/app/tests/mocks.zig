//! Mocks for the tests of zefir.App: a recorder the mocks write their
//! lifecycle into, the ready objects of a root, and the shapes of zefir's
//! clients and servers for the shop of design §3.
const std = @import("std");
const names = @import("../names.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Timestamp = Io.Clock.Timestamp;

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

pub const mongo = struct {
    pub const Client = struct {
        rec: *Recorder,
        uri: []const u8,

        pub fn init(gpa: Allocator, io: Io, rec: *Recorder, uri: []const u8) !Client {
            _ = gpa;
            _ = io;
            return .{ .rec = rec, .uri = uri };
        }
        pub fn start(c: *Client, _: Io) !void {
            c.rec.add("start", "mongo.Client");
        }
        pub fn shutdown(c: *Client, _: Io, _: Timestamp) !void {
            c.rec.add("shutdown", "mongo.Client");
        }
        pub fn deinit(c: *Client, _: Io) void {
            c.rec.add("deinit", "mongo.Client");
        }
    };

    /// A handle on one database of a client, passed by value.
    pub const Database = struct {
        client: *Client,
        name: []const u8,
        ids: *bson.ObjectId.Generator,

        pub fn init(client: *Client, name: []const u8, ids: *bson.ObjectId.Generator) Database {
            return .{ .client = client, .name = name, .ids = ids };
        }
    };

    pub const bson = struct {
        pub const ObjectId = struct {
            /// One per application: its init takes only io.
            pub const Generator = struct {
                next: u64,

                pub fn init(io: Io) Generator {
                    _ = io;
                    return .{ .next = 1 };
                }
            };
        };
    };
};

pub const nats = struct {
    pub const Client = struct {
        rec: *Recorder,

        pub fn init(gpa: Allocator, io: Io, rec: *Recorder) !Client {
            _ = gpa;
            _ = io;
            return .{ .rec = rec };
        }
        pub fn start(c: *Client, _: Io) !void {
            c.rec.add("start", "nats.Client");
        }
        pub fn wait(_: *Client, _: Io) !void {}
        pub fn shutdown(c: *Client, _: Io, _: Timestamp) !void {
            c.rec.add("shutdown", "nats.Client");
        }
        pub fn deinit(c: *Client, _: Io) void {
            c.rec.add("deinit", "nats.Client");
        }
    };
};

pub const rpc_nats = struct {
    /// The transport of rpc over NATS. Its start, with a third param, is
    /// the rpc server's to call: the type declares the marker, and App only
    /// builds and frees it.
    pub const Transport = struct {
        client: *nats.Client,

        pub const app_lifecycle = false;

        pub fn init(gpa: Allocator, client: *nats.Client) !Transport {
            _ = gpa;
            return .{ .client = client };
        }
        pub fn start(_: *Transport, _: Io, _: *anyopaque) !void {}
        pub fn deinit(t: *Transport) void {
            t.client.rec.add("deinit", "Transport");
        }
    };
};

/// A server over the tuple of pointers `parts.<list>`, whose types declare
/// `label`: `init(gpa, rec, parts)`. It keeps them type-erased, as a server
/// keeps its controllers, and records its lifecycle as `what`.
fn ServerOf(comptime what: []const u8, comptime list: []const u8, comptime label: []const u8) type {
    return struct {
        const Server = @This();

        rec: *Recorder,
        gpa: Allocator,
        names: [][]const u8,
        ptrs: []*anyopaque,

        pub fn init(gpa: Allocator, rec: *Recorder, parts: anytype) !Server {
            const items = @field(parts, list);
            const n = @typeInfo(@TypeOf(items)).@"struct".field_types.len;
            const item_names = try gpa.alloc([]const u8, n);
            errdefer gpa.free(item_names);
            const ptrs = try gpa.alloc(*anyopaque, n);
            inline for (items, 0..) |it, k| {
                const T = @typeInfo(@TypeOf(it)).pointer.child;
                if (!@hasDecl(T, label)) @compileError(what ++ ": " ++ @typeName(T) ++ " does not declare " ++ label);
                item_names[k] = comptime names.name(T);
                ptrs[k] = it;
            }
            return .{ .rec = rec, .gpa = gpa, .names = item_names, .ptrs = ptrs };
        }
        /// Item k, cast back from the server's type-erased pointer.
        pub fn item(s: *const Server, comptime T: type, k: usize) *T {
            return @ptrCast(@alignCast(s.ptrs[k]));
        }
        pub fn start(s: *Server, _: Io) !void {
            s.rec.add("start", what);
        }
        pub fn wait(_: *Server, _: Io) !void {}
        pub fn requestStop(s: *Server, _: Io) void {
            s.rec.add("requestStop", what);
        }
        pub fn shutdown(s: *Server, _: Io, _: Timestamp) !void {
            s.rec.add("shutdown", what);
        }
        pub fn isReady(_: *const Server) bool {
            return true;
        }
        pub fn deinit(s: *Server) void {
            s.rec.add("deinit", what);
            s.gpa.free(s.names);
            s.gpa.free(s.ptrs);
        }
    };
}

pub const http = struct {
    pub const Server = ServerOf("http.Server", "controllers", "http_routes");
};

pub const rpc = struct {
    pub const Server = ServerOf("rpc.Server", "handlers", "rpc_handler");
};
