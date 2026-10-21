//! `http.sse.Manager(Events)`: the subscriptions of this
//! process to SSE streams, by key, and the events they get. `Events` is a
//! `union(enum)`, a variant per event: the name of a variant is the name
//! of its event, and its value is the data, as JSON. The SSE route declares
//! the same union in `.events`. A controller keeps a pointer to the
//! manager; the route's handler subscribes the request under a key, such
//! as the id of its user, and any task publishes to every subscriber of a
//! key.
//!
//! ```zig
//! pub const LiveEvent = union(enum) {
//!     @"todo.created": TodoResponse,
//!     @"todo.deleted": TodoIdPath,
//! };
//!
//! var live: http.sse.Manager(dto.LiveEvent) = .init(gpa, .{});
//! defer live.deinit(io);
//!
//! // The handler of an `http.sse.get("/events", .{ .events = dto.LiveEvent })` route:
//! pub fn events(self: *TodosV1Controller, ctx: *http.sse.Context) !void {
//!     _ = try self.live.subscribe(ctx, owner(ctx)); // returns at once; the stream lives on
//! }
//!
//! // Anywhere else, in the publisher's own context:
//! try self.live.publish(ctx.operation(), ctx.io(), owner(ctx), .{ .event = .{ .@"todo.created" = .from(todo) } });
//! ```
//!
//! The compiler checks every event: a name the union does not have, or
//! data of another type, does not build. A publisher never waits for
//! delivery: the event goes into the queue of each subscriber, and a
//! subscriber whose queue goes over its limits (`.queue`) is closed, so a
//! client that falls behind costs no more memory than the limits. The
//! manager is thread-safe: zio runs the streams and the publishers on
//! several threads.
const std = @import("std");
const core = @import("core");
const v = @import("validator");
const sse = @import("../sse.zig");
const routes = @import("../routes.zig");
const plan = @import("../plan.zig");
const json_out = @import("../output/json_out.zig");
const format = @import("format.zig");
const Hub = @import("Hub.zig");

/// The manager of the streams whose events are the variants of `Events`, a
/// `union(enum)`.
pub fn Manager(comptime Events: type) type {
    comptime checkEvents(Events);
    return struct {
        const Self = @This();

        /// Internal to the server: the subscriptions and their queues.
        internal: Hub,

        /// The limits of a manager.
        pub const Options = Hub.Options;
        pub const SubscriptionId = Hub.SubscriptionId;
        pub const SubscribeError = Hub.SubscribeError;
        /// `InvalidEvent` (500): CR, LF or NUL in `.id`. `EventTooLarge`
        /// (500, logged): the event, as the stream sends it, is longer than
        /// `.queue.max_bytes`, so no queue could hold it; it goes to nobody,
        /// and the subscribers stay. And the errors of the transforms of the
        /// data, as `v.TransformError` of each variant's type says.
        pub const PublishError = error{ InvalidEvent, EventTooLarge } || DataErrors(Events);

        /// One event: `.event`, the variant of `Events` with its data; and
        /// optionally `.id`, a string the client sends back as
        /// `Last-Event-ID` when it reconnects, and `.retry`, the
        /// milliseconds the client waits before it reconnects.
        pub const Event = struct {
            event: Events,
            id: ?[]const u8 = null,
            retry: ?u64 = null,
        };

        pub fn init(gpa: std.mem.Allocator, options: Options) Self {
            return .{ .internal = .init(gpa, options) };
        }

        /// Closes the streams still open, as `close` does, waits until they
        /// have ended and their `.on_close` has run, and frees the manager.
        /// Usually after the server's `deinit`, when none is open; an
        /// `.on_close` may still publish through it meanwhile.
        pub fn deinit(m: *Self, io: std.Io) void {
            m.internal.deinit(io);
        }

        /// Opens the stream of the request under `key` and returns at once;
        /// the stream lives on until the client leaves, `close(key)`, its
        /// queue overflows or the server stops, and then the route's
        /// `.on_close` runs. It sends the head of the stream: 200,
        /// `Content-Type: text/event-stream`, `Cache-Control: no-cache` and
        /// `X-Accel-Buffering: no`, with the fields the middleware set. From
        /// here on the request is counted among the server's streams, not in
        /// `.max_in_flight`, and its deadline no longer applies. The key is
        /// copied.
        pub fn subscribe(m: *Self, ctx: *sse.Context, key: []const u8) SubscribeError!SubscriptionId {
            return m.internal.subscribe(ctx, key);
        }

        /// Sends `event` to every subscriber of `key`, in the publisher's
        /// own context, and returns at once: each gets it in its queue, and
        /// a subscriber whose queue it would take over the limits is
        /// closed. No subscriber: nothing happens.
        ///
        /// The name of the event is the name of the variant; its data, the
        /// value of the variant as JSON, through its transforms and by the
        /// outside names of its `field_rules`, as `http.Json(T)` writes it,
        /// and `{}` for a variant of `void`:
        ///
        /// ```zig
        /// try live.publish(ctx.operation(), ctx.io(), key, .{ .event = .{ .@"todo.created" = .from(todo) }, .id = "42" });
        /// ```
        ///
        /// `op` is the publisher's: publishing never waits, so its deadline
        /// and token do not stop it.
        pub fn publish(m: *Self, op: core.Context, io: std.Io, key: []const u8, event: Event) PublishError!void {
            _ = op;
            if (event.id) |text| if (!format.validField(text)) return error.InvalidEvent;
            var arena: std.heap.ArenaAllocator = .init(m.internal.gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const data = switch (event.event) {
                inline else => |payload| if (@TypeOf(payload) == void) "{}" else try json_out.encode(a, payload, .{}),
            };
            const bytes = try format.alloc(a, .{ .event = @tagName(event.event), .id = event.id, .retry = event.retry, .data = data });
            return m.internal.publish(io, key, bytes);
        }

        /// Ends every stream of `key`, such as when its user signs out: what
        /// was published to it before goes out, then the end of the
        /// response, and its `.on_close` runs; what is published after is
        /// not sent. A client may connect again.
        pub fn close(m: *Self, io: std.Io, key: []const u8) void {
            m.internal.close(io, key);
        }
    };
}

/// `Events` is a `union(enum)` whose names fit the line of an event.
fn checkEvents(comptime Events: type) void {
    if (!routes.isEventUnion(Events))
        @compileError("zefir.http: http.sse.Manager takes a union(enum) of the stream's events, such as http.sse.Manager(dto.LiveEvent); got " ++ plan.typeName(Events));
    for (@typeInfo(Events).@"union".field_names) |name| {
        if (!format.validField(name))
            @compileError("zefir.http: http.sse.Manager(" ++ plan.typeName(Events) ++ "): the event ." ++ name ++ " has CR, LF or NUL in its name, which would break its line");
    }
}

/// The errors of the transforms of the data of every variant of `Events`,
/// and `error.OutOfMemory`.
fn DataErrors(comptime Events: type) type {
    var E: type = std.mem.Allocator.Error;
    for (@typeInfo(Events).@"union".field_types) |T| {
        if (T != void) E = E || v.TransformError(T);
    }
    return E;
}
