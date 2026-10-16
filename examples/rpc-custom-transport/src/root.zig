//! rpc-mailbox: a transport of zefir-rpc over a message broker, the way
//! AMQP brokers such as RabbitMQ carry RPC. A sample for authors of
//! transports, in a package of its own: it uses only the public API of
//! zefir-rpc and passes the conformance suite, `rpc.testing.conformance`.
//!
//! The broker is a small one in memory, `Broker`: named queues of
//! messages. A call goes as AMQP RPC goes:
//!
//! 1. A server declares one queue per contract, `rpc.<service>.v<version>`,
//!    and a task per queue hands the requests to the engine (`Server`).
//! 2. A client declares a reply queue of its own and publishes each request
//!    to the queue of its contract, with `reply_to`, the name of its reply
//!    queue, and `correlation_id`, the id of the call's slot in
//!    `rpc.transport.Pending` (`Client`).
//! 3. The server publishes the response to `reply_to` with the same
//!    `correlation_id`; the client's task hands it to the call that waits
//!    in that slot. The server answers only in reply queues (`reply.…`),
//!    and each task drops a message of the kind it does not read.
//!
//! ```zig
//! var broker: mailbox.Broker = .init(gpa, .{});
//! defer broker.deinit();
//!
//! var server_side: mailbox.Server = .init(&broker);
//! var server = try rpc.Server.init(gpa, .{ .transport = server_side.serverTransport(), .handlers = .{&users} });
//! defer server.deinit(io);
//! try server.start(io);
//!
//! var client_side: mailbox.Client = try .init(&broker, .{});
//! defer client_side.deinit(io); // also after a connect that failed
//! try client_side.connect(io);
//! var client = try rpc.Client.init(gpa, .{ .transport = client_side.clientTransport() });
//! defer client.deinit();
//! ```
//!
//! A transport for a real broker keeps this shape and puts its library in
//! place of `Broker`: queue.declare, basic.publish with `reply_to` and
//! `correlation_id`, basic.consume in a task, basic.ack in `Reply.release`.
//! The broker and both sides run on one `std.Io`.

const std = @import("std");
const core = @import("zefir-core");
const rpc = @import("zefir-rpc");

const Entry = rpc.Metadata.Entry;
const Pending = rpc.transport.Pending;

/// The broker: named queues of messages, the part of RabbitMQ that RPC
/// needs. A queue has one consumer, the side that declared it. Publishing
/// never waits: to a queue that is full or not there, it fails at once.
pub const Broker = struct {
    gpa: std.mem.Allocator,
    options: Options,
    /// Guards `queues`; held only to look a queue up and put a message in.
    mutex: std.Io.Mutex = .init,
    queues: std.StringArrayHashMapUnmanaged(*Queue) = .empty,

    pub const Options = struct {
        /// How many messages a queue of a server holds.
        queue_capacity: u32 = 1024,
        /// The largest body of a request or a response:
        /// `rpc.transport.Info.max_body_bytes` of both sides.
        max_body_bytes: usize = 1 << 20,
    };

    /// `gpa` is thread-safe: both sides allocate messages from their tasks.
    pub fn init(gpa: std.mem.Allocator, options: Options) Broker {
        return .{ .gpa = gpa, .options = options };
    }

    /// After the servers are closed and the clients deinitialized: no queue
    /// is left.
    pub fn deinit(b: *Broker) void {
        std.debug.assert(b.queues.count() == 0);
        b.queues.deinit(b.gpa);
        b.* = undefined;
    }

    pub const DeclareError = error{ QueueExists, OutOfMemory };

    /// A new queue under `name` for `capacity` messages; one per name.
    fn declare(b: *Broker, io: std.Io, name: []const u8, capacity: u32) DeclareError!*Queue {
        // A Debug allocator may take a cancelable lock.
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        const queue = try Queue.create(b.gpa, name, capacity);
        errdefer queue.destroy(io);
        b.mutex.lockUncancelable(io);
        defer b.mutex.unlock(io);
        const slot = try b.queues.getOrPut(b.gpa, queue.name);
        if (slot.found_existing) return error.QueueExists;
        slot.value_ptr.* = queue;
        return queue;
    }

    /// Takes `queue` out of the broker: a publish to its name fails with
    /// NoRoute from now on, and its consumer gets the messages already in
    /// it, then `error.Closed`. A second call does nothing.
    fn unbind(b: *Broker, io: std.Io, queue: *Queue) void {
        b.mutex.lockUncancelable(io);
        defer b.mutex.unlock(io);
        if (b.queues.get(queue.name) == queue) _ = b.queues.swapRemove(queue.name);
        queue.messages.close(io);
    }

    /// No queue has this name: no server serves the contract, or its
    /// server drains; for a response, the client is gone (AMQP: NO_ROUTE).
    /// Or the queue is full.
    pub const PublishError = error{ NoRoute, QueueFull };

    /// Puts `message` into the queue `name`, without waiting. On success
    /// the message is the consumer's to free, on an error still the
    /// caller's.
    fn publish(b: *Broker, io: std.Io, name: []const u8, message: *Message) PublishError!void {
        b.mutex.lockUncancelable(io);
        defer b.mutex.unlock(io);
        const queue = b.queues.get(name) orelse return error.NoRoute;
        const put = queue.messages.putUncancelable(io, &.{message}, 0) catch return error.NoRoute;
        if (put == 0) return error.QueueFull;
    }

    /// Publishes a copy of `response` to the reply queue `reply_to`.
    fn reply(b: *Broker, io: std.Io, reply_to: []const u8, correlation_id: u64, response: *const rpc.Response) (PublishError || error{OutOfMemory})!void {
        // A Debug allocator may take a cancelable lock.
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        const message = try Message.create(b.gpa, correlation_id);
        errdefer message.destroy();
        message.content = .{ .response = try copyResponse(message.arena.allocator(), response.*) };
        try b.publish(io, reply_to, message);
    }
};

/// A queue of the broker and room for its messages.
const Queue = struct {
    gpa: std.mem.Allocator,
    name: []u8,
    buffer: []*Message,
    messages: std.Io.Queue(*Message),

    fn create(gpa: std.mem.Allocator, name: []const u8, capacity: u32) error{OutOfMemory}!*Queue {
        const queue = try gpa.create(Queue);
        errdefer gpa.destroy(queue);
        const own_name = try gpa.dupe(u8, name);
        errdefer gpa.free(own_name);
        const buffer = try gpa.alloc(*Message, capacity);
        queue.* = .{ .gpa = gpa, .name = own_name, .buffer = buffer, .messages = .init(buffer) };
        return queue;
    }

    /// A message still in the queue, without waiting; null when none is.
    fn takeLeft(queue: *Queue, io: std.Io) ?*Message {
        var one: [1]*Message = undefined;
        const n = queue.messages.getUncancelable(io, &one, 0) catch return null;
        return if (n == 1) one[0] else null;
    }

    /// Frees the queue with the messages left in it, once it is unbound
    /// and its consumer has ended.
    fn destroy(queue: *Queue, io: std.Io) void {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        while (queue.takeLeft(io)) |message| message.destroy();
        queue.gpa.free(queue.buffer);
        queue.gpa.free(queue.name);
        queue.gpa.destroy(queue);
    }
};

/// What a queue holds: a request or a response, with its own copy of every
/// byte in an arena. Whoever takes it from the queue frees it.
const Message = struct {
    arena: std.heap.ArenaAllocator,
    /// The id of the call's slot in the client's `Pending`; the response
    /// brings it back.
    correlation_id: u64,
    content: union(enum) { request: Request, response: rpc.Response },

    const Request = struct {
        /// The client's reply queue.
        reply_to: []const u8,
        route: rpc.Route,
        request_id: [16]u8,
        codec: []const u8,
        /// The time the client had left when it published.
        timeout: std.Io.Duration,
        /// When the client published, on the awake clock: the broker runs
        /// in this process, so both sides read the same clock. The server's
        /// deadline counts from here, so the time in the queue comes off
        /// `timeout`.
        published_at: std.Io.Timestamp,
        metadata: []const Entry,
        body: []const u8,
    };

    fn create(gpa: std.mem.Allocator, correlation_id: u64) error{OutOfMemory}!*Message {
        const message = try gpa.create(Message);
        message.* = .{ .arena = .init(gpa), .correlation_id = correlation_id, .content = undefined };
        return message;
    }

    fn destroy(message: *Message) void {
        const gpa = message.arena.child_allocator;
        message.arena.deinit();
        gpa.destroy(message);
    }

    /// `Pending.Delivery.release` of a response.
    fn free(context: *anyopaque) void {
        destroy(@ptrCast(@alignCast(context)));
    }
};

/// The server side: `rpc.ServerTransport`.
pub const Server = struct {
    broker: *Broker,
    /// Serializes `start`, `drain` and `close`.
    lifecycle: std.Io.Mutex = .init,
    /// Written under `lifecycle`; the tasks and `Call.send` read it.
    phase: std.atomic.Value(Phase) = .init(.idle),
    dispatcher: rpc.transport.Dispatcher = undefined,
    /// One queue per contract while the server side runs.
    queues: []*Queue = &.{},
    /// A task per queue; only `start` and `close` touch the group.
    group: std.Io.Group = .init,
    /// Set once `start` has started every task: a start that fails leaves
    /// no call behind.
    started: std.Io.Event = .unset,

    const Phase = enum(u8) { idle, running, draining, closing, closed };

    pub fn init(broker: *Broker) Server {
        return .{ .broker = broker };
    }

    pub fn serverTransport(s: *Server) rpc.ServerTransport {
        return .init(s);
    }

    pub fn info(s: *Server) rpc.transport.Info {
        return infoOf(s.broker);
    }

    /// Declares a queue for each contract of the routes and starts a task
    /// on each. A contract that another server serves on this broker:
    /// `error.AddressInUse`.
    pub fn start(s: *Server, io: std.Io, dispatcher: rpc.transport.Dispatcher) rpc.ServerTransport.StartError!void {
        s.lifecycle.lockUncancelable(io);
        defer s.lifecycle.unlock(io);
        switch (s.phase.load(.acquire)) {
            .idle, .closed => {},
            .running, .draining, .closing => return error.AddressInUse,
        }
        const queues = try s.declareQueues(io, dispatcher.service().routes);
        s.dispatcher = dispatcher;
        s.queues = queues;
        // No task waits on it: the group is empty.
        s.started.reset();
        s.phase.store(.running, .release);
        for (queues) |queue| {
            s.group.concurrent(io, receive, .{ s, queue, io }) catch |err| {
                // The tasks that began end before their first request.
                s.group.cancel(io);
                s.phase.store(.idle, .release);
                s.deleteQueues(io);
                return err;
            };
        }
        s.started.set(io);
    }

    fn declareQueues(s: *Server, io: std.Io, routes: []const rpc.Route) rpc.ServerTransport.StartError![]*Queue {
        // A Debug allocator may take a cancelable lock.
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        const gpa = s.broker.gpa;
        var queues: std.ArrayList(*Queue) = .empty;
        errdefer {
            for (queues.items) |queue| {
                s.broker.unbind(io, queue);
                queue.destroy(io);
            }
            queues.deinit(gpa);
        }
        for (routes) |route| {
            var buffer: [max_queue_name]u8 = undefined;
            const name = queueName(&buffer, route) orelse return error.InvalidConfiguration;
            for (queues.items) |queue| {
                if (std.mem.eql(u8, queue.name, name)) break;
            } else {
                try queues.ensureUnusedCapacity(gpa, 1);
                const queue = s.broker.declare(io, name, s.broker.options.queue_capacity) catch |err| return switch (err) {
                    error.QueueExists => error.AddressInUse,
                    error.OutOfMemory => error.OutOfMemory,
                };
                queues.appendAssumeCapacity(queue);
            }
        }
        return queues.toOwnedSlice(gpa);
    }

    /// Unbinds and frees the queues, refusing the requests still in them:
    /// they never reached the engine, and their clients need not wait for
    /// their deadlines.
    fn deleteQueues(s: *Server, io: std.Io) void {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        for (s.queues) |queue| {
            s.broker.unbind(io, queue);
            while (queue.takeLeft(io)) |message| {
                s.refuse(io, message, stopping);
                message.destroy();
            }
            queue.destroy(io);
        }
        s.broker.gpa.free(s.queues);
        s.queues = &.{};
    }

    /// Unbinds the queues: a new request finds no queue and its client gets
    /// `error.Unavailable` at once; the requests already in a queue still
    /// reach the engine.
    pub fn drain(s: *Server, io: std.Io) void {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        s.lifecycle.lockUncancelable(io);
        defer s.lifecycle.unlock(io);
        if (s.phase.load(.acquire) != .running) return;
        s.phase.store(.draining, .release);
        for (s.queues) |queue| s.broker.unbind(io, queue);
    }

    /// Ends the tasks, refuses what is left in the queues and frees them.
    /// It waits only for a task in the middle of a request, which does no
    /// I/O but the engine's `admit` and `start`.
    pub fn close(s: *Server, io: std.Io) void {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        s.lifecycle.lockUncancelable(io);
        defer s.lifecycle.unlock(io);
        switch (s.phase.load(.acquire)) {
            .idle, .closed => return,
            .running, .draining => {},
            // Under `lifecycle`, a close ends before another looks.
            .closing => unreachable,
        }
        // Before the tasks end: one with a request in hand abandons it.
        s.phase.store(.closing, .release);
        s.group.cancel(io);
        s.deleteQueues(io);
        s.phase.store(.closed, .release);
    }

    /// The task of one queue.
    fn receive(s: *Server, queue: *Queue, io: std.Io) void {
        // A start that fails cancels the task here.
        s.started.wait(io) catch return;
        // Ends at `close` (canceled) or once a drained queue is empty.
        while (queue.messages.getOne(io)) |message| {
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            s.handle(io, message);
        } else |_| {}
    }

    /// One request: to the engine, or refused. The message is freed once
    /// its head has been to `admit` and its body copied. Anything the
    /// server may not answer is dropped unanswered (`answerable`).
    fn handle(s: *Server, io: std.Io, message: *Message) void {
        defer message.destroy();
        const request = answerable(message) orelse return;
        if (s.closing()) return s.refuse(io, message, stopping);
        const head: rpc.transport.RequestHead = .{
            .route = request.route,
            .request_id = request.request_id,
            .codec = request.codec,
            .timeout = request.timeout,
            // Not the moment it left the queue: the client's budget runs
            // from the publish.
            .received_at = request.published_at,
            .metadata = request.metadata,
            // Not the reply queue: with its name and a correlation id
            // anyone who may publish to it could answer for the server,
            // and logs show the peer.
            .peer = .none,
        };
        const incoming = switch (s.dispatcher.admit(io, &head, request.body.len)) {
            .accepted => |incoming| incoming,
            .rejected => |failure| return s.refuse(io, message, failure),
        };
        // `close` began while the engine decided: the call never starts.
        if (s.closing()) {
            incoming.abandon(io);
            return s.refuse(io, message, stopping);
        }
        const call = Call.create(s, request.reply_to, message.correlation_id) catch {
            incoming.abandon(io);
            return s.refuse(io, message, out_of_memory);
        };
        @memcpy(incoming.body(), request.body);
        // The engine may answer and release the call before `start`
        // returns: after null, `call` is not touched.
        if (incoming.start(io, .init(call))) |failure| {
            call.destroy();
            s.refuse(io, message, failure);
        }
    }

    fn closing(s: *const Server) bool {
        return switch (s.phase.load(.acquire)) {
            .closing, .closed => true,
            .idle, .running, .draining => false,
        };
    }

    /// Answers a request that did not run, marked as refused.
    fn refuse(s: *Server, io: std.Io, message: *const Message, failure: rpc.Failure) void {
        const request = answerable(message) orelse return;
        const response: rpc.Response = .{ .status = .{ .failure = failure }, .refused = true };
        // A client that is gone takes nothing.
        s.broker.reply(io, request.reply_to, message.correlation_id, &response) catch {};
    }
};

const stopping: rpc.Failure = .{ .code = .unavailable, .app_code = "rpc.unavailable", .message = "Server is stopping" };
const out_of_memory: rpc.Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Out of memory" };

/// The names of the clients' reply queues begin with it, and the server
/// answers nowhere else.
const reply_prefix = "reply.";

/// The request in `message` if the server may answer it: a request whose
/// `reply_to` is a reply queue. Null for anything else, which the server
/// drops unanswered: a response, such as one another server published
/// here, and a `reply_to` that names another queue. A client that may
/// publish requests could name in it the request queue of another
/// service, and the answers of this server would land there.
fn answerable(message: *const Message) ?*const Message.Request {
    return switch (message.content) {
        .request => |*request| if (isReplyQueue(request.reply_to)) request else null,
        .response => null,
    };
}

fn isReplyQueue(name: []const u8) bool {
    return name.len > reply_prefix.len and std.mem.startsWith(u8, name, reply_prefix);
}

/// A call the engine runs: its `rpc.transport.Reply`.
const Call = struct {
    server: *Server,
    reply_to: []u8,
    correlation_id: u64,

    fn create(s: *Server, reply_to: []const u8, correlation_id: u64) error{OutOfMemory}!*Call {
        const gpa = s.broker.gpa;
        const call = try gpa.create(Call);
        errdefer gpa.destroy(call);
        call.* = .{ .server = s, .reply_to = try gpa.dupe(u8, reply_to), .correlation_id = correlation_id };
        return call;
    }

    fn destroy(call: *Call) void {
        const gpa = call.server.broker.gpa;
        gpa.free(call.reply_to);
        gpa.destroy(call);
    }

    /// Publishes the response to the client's reply queue.
    pub fn send(call: *Call, io: std.Io, response: *const rpc.Response) rpc.transport.Reply.SendError!void {
        const s = call.server;
        if (s.phase.load(.acquire) == .closed) return error.Closed;
        if (response.body.len > s.broker.options.max_body_bytes) return error.ResponseTooLarge;
        s.broker.reply(io, call.reply_to, call.correlation_id, response) catch |err| return switch (err) {
            // The client is gone, and the response with it.
            error.NoRoute => error.Closed,
            error.QueueFull => error.Unexpected,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    /// The call is over. An AMQP transport acknowledges the request here:
    /// basic.ack, or basic.nack with requeue for `.not_started`, so that
    /// another server runs a call that this one never began.
    pub fn release(call: *Call, io: std.Io, disposition: rpc.transport.Reply.Disposition) void {
        _ = disposition;
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        call.destroy();
    }
};

/// The client side: `rpc.ClientTransport`.
pub const Client = struct {
    broker: *Broker,
    /// The calls that wait for their responses, by `correlation_id`.
    pending: Pending,
    max_pending: u32,
    /// The reply queue and the task that reads it, once `connect` has run.
    replies: ?*Queue = null,
    task: std.Io.Future(void) = undefined,
    /// The `std.Io` of `connect`: in Debug, `call` checks that it gets the
    /// same.
    io_vtable: ?*const std.Io.VTable = null,

    pub const Options = struct {
        /// The most calls that wait for their responses at once; one more
        /// gets `error.TooManyPendingRequests`.
        max_pending: u32 = 1024,
    };

    /// No I/O: takes the room for `max_pending` calls.
    pub fn init(broker: *Broker, options: Options) error{OutOfMemory}!Client {
        return .{
            .broker = broker,
            .pending = try .init(broker.gpa, .{ .max_pending = options.max_pending }),
            .max_pending = options.max_pending,
        };
    }

    pub const ConnectError = Broker.DeclareError || std.Io.ConcurrentError || std.Io.RandomSecureError;

    /// Declares the client's reply queue, `reply.<16 hex digits>`, and
    /// starts the task that reads it; a second `connect` does nothing. From
    /// now on the client stays at its address until `deinit`, and its calls
    /// run on this `io`. The name comes from `io.randomSecure`: whoever
    /// knows it may publish a response that the client takes as the
    /// server's.
    pub fn connect(c: *Client, io: std.Io) ConnectError!void {
        if (c.replies != null) return;
        var token: [8]u8 = undefined;
        try io.randomSecure(&token);
        var buffer: [max_queue_name]u8 = undefined;
        const name = std.fmt.bufPrint(&buffer, reply_prefix ++ "{s}", .{&std.fmt.bytesToHex(token, .lower)}) catch unreachable;
        // Room for a response to every call that may wait.
        const queue = try c.broker.declare(io, name, c.max_pending);
        errdefer {
            c.broker.unbind(io, queue);
            queue.destroy(io);
        }
        // A task of the transport: canceling a call does not stop it.
        c.task = try io.concurrent(receive, .{ c, queue, io });
        c.replies = queue;
        c.io_vtable = io.vtable;
    }

    /// No call may be in flight.
    pub fn deinit(c: *Client, io: std.Io) void {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        if (c.replies) |queue| {
            c.broker.unbind(io, queue);
            c.task.cancel(io);
            queue.destroy(io);
        }
        c.pending.deinit();
        c.* = undefined;
    }

    pub fn clientTransport(c: *Client) rpc.ClientTransport {
        return .init(c);
    }

    pub fn info(c: *Client) rpc.transport.Info {
        return infoOf(c.broker);
    }

    pub fn call(c: *Client, io: std.Io, request: *const rpc.transport.Request, options: rpc.ClientTransport.CallOptions) rpc.ClientTransport.CallError!rpc.Response {
        // A cancelation pending on entry comes before any other outcome.
        try io.checkCancel();
        const replies = c.replies orelse return error.Unavailable;
        // Rule 2 of rpc.ClientTransport: a wait on another `io` would not
        // end when the task of the call is canceled.
        if (std.debug.runtime_safety and c.io_vtable != io.vtable)
            @panic("rpc-mailbox: Client.call with another std.Io than connect's; pass the io the client connected on");
        if (request.body.len > c.broker.options.max_body_bytes) return error.RequestTooLarge;
        var buffer: [max_queue_name]u8 = undefined;
        const queue_name = queueName(&buffer, request.route) orelse return error.Unexpected;
        const deadline = request.ctx.deadline orelse core.Deadline.after(now(io), .max);
        if (deadline.remaining(now(io)).nanoseconds < std.time.ns_per_ms) return error.Timeout;

        const slot = try c.pending.acquire(io);
        defer releaseSlot(c, io, slot);
        // The time left, right before publishing.
        const published_at = now(io);
        const left = deadline.remaining(published_at);
        if (left.nanoseconds < std.time.ns_per_ms) return error.Timeout;
        const message = try requestMessage(c.broker.gpa, io, request, replies.name, slot.id, left, published_at);
        c.broker.publish(io, queue_name, message) catch |err| {
            freeMessage(io, message);
            // No queue: no server serves the contract, or its server
            // drains. A full queue: the server is behind. Either way the
            // call surely did not run.
            return switch (err) {
                error.NoRoute, error.QueueFull => error.Unavailable,
            };
        };

        const delivery = try c.pending.wait(io, slot, deadline);
        // The response is the transport's message until this release: it
        // is copied into the caller's allocator first.
        defer freeDelivery(io, delivery);
        return take(io, delivery.response, options);
    }

    /// The task that reads the reply queue: hands each response to the
    /// call in its slot, and drops anything else.
    fn receive(c: *Client, queue: *Queue, io: std.Io) void {
        while (queue.messages.getOne(io)) |message| {
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            const response = switch (message.content) {
                .response => |response| response,
                .request => {
                    message.destroy();
                    continue;
                },
            };
            const delivery: Pending.Delivery = .{ .response = response, .context = message, .release = Message.free };
            // Late: its call returned with Timeout or Canceled.
            if (!c.pending.complete(io, message.correlation_id, delivery)) message.destroy();
        } else |_| {}
    }
};

/// The request as a message, with a copy of every byte.
fn requestMessage(
    gpa: std.mem.Allocator,
    io: std.Io,
    request: *const rpc.transport.Request,
    reply_to: []const u8,
    correlation_id: u64,
    timeout: std.Io.Duration,
    published_at: std.Io.Timestamp,
) error{OutOfMemory}!*Message {
    // A Debug allocator may take a cancelable lock.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    const message = try Message.create(gpa, correlation_id);
    errdefer message.destroy();
    const a = message.arena.allocator();
    message.content = .{ .request = .{
        .reply_to = try a.dupe(u8, reply_to),
        .route = .{ .service = try a.dupe(u8, request.route.service), .version = request.route.version, .method = try a.dupe(u8, request.route.method) },
        .request_id = request.request_id,
        .codec = try a.dupe(u8, request.codec),
        .timeout = timeout,
        .published_at = published_at,
        .metadata = try copyEntries(a, request.metadata),
        .body = try a.dupe(u8, request.body),
    } };
    return message;
}

/// The response in the caller's allocator, within the caller's limits.
fn take(io: std.Io, response: rpc.Response, options: rpc.ClientTransport.CallOptions) rpc.ClientTransport.CallError!rpc.Response {
    if (response.body.len > options.max_response_bytes or
        response.metadata.len > options.max_response_metadata_entries or
        rpc.transport.metadataBytes(response.metadata) > options.max_response_metadata_bytes)
        return error.ResponseTooLarge;
    // The caller's allocator; a Debug allocator may take a cancelable lock.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    return copyResponse(options.allocator, response);
}

fn copyResponse(a: std.mem.Allocator, response: rpc.Response) error{OutOfMemory}!rpc.Response {
    return .{
        .status = switch (response.status) {
            .ok => .ok,
            .failure => |f| .{ .failure = .{
                .code = f.code,
                .app_code = try a.dupe(u8, f.app_code),
                .message = try a.dupe(u8, f.message),
                .field = if (f.field) |field| try a.dupe(u8, field) else null,
            } },
        },
        .metadata = try copyEntries(a, response.metadata),
        .body = try a.dupe(u8, response.body),
        .refused = response.refused,
    };
}

fn copyEntries(a: std.mem.Allocator, entries: []const Entry) error{OutOfMemory}![]const Entry {
    const copy = try a.alloc(Entry, entries.len);
    for (entries, copy) |entry, *c| c.* = .{ .key = try a.dupe(u8, entry.key), .value = try a.dupe(u8, entry.value) };
    return copy;
}

fn releaseSlot(c: *Client, io: std.Io, slot: Pending.Slot) void {
    // It may free a response that came too late.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    c.pending.release(io, slot);
}

fn freeMessage(io: std.Io, message: *Message) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    message.destroy();
}

fn freeDelivery(io: std.Io, delivery: Pending.Delivery) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    delivery.release(delivery.context);
}

fn infoOf(broker: *const Broker) rpc.transport.Info {
    return .{
        .name = "mailbox",
        // No queue for a contract: no server, or one that drains.
        .reports_unprocessed = true,
        .max_body_bytes = broker.options.max_body_bytes,
    };
}

/// "rpc." ++ a service of up to 64 characters ++ ".v65535".
const max_queue_name = 80;

/// The queue of the route's contract, `rpc.<service>.v<version>`; null for
/// a service name longer than the rules allow.
fn queueName(buffer: *[max_queue_name]u8, route: rpc.Route) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "rpc.{s}.v{d}", .{ route.service, route.version }) catch null;
}

fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
}

/// What the tests of this package and of its users need.
pub const testing = struct {
    /// The harness of `rpc.testing.conformance.run`: a broker with a client
    /// side and a server side.
    pub const Harness = struct {
        broker: Broker = undefined,
        server: Server = undefined,
        client: Client = undefined,
        /// A second server side for the same contracts (T14).
        rival: Server = undefined,

        pub fn setUp(h: *Harness, io: std.Io, gpa: std.mem.Allocator) !rpc.testing.conformance.Pair {
            h.broker = .init(gpa, .{});
            errdefer h.broker.deinit();
            h.server = .init(&h.broker);
            h.rival = .init(&h.broker);
            h.client = try .init(&h.broker, .{});
            errdefer h.client.deinit(io);
            try h.client.connect(io);
            return .{ .client = h.client.clientTransport(), .server = h.server.serverTransport() };
        }

        pub fn tearDown(h: *Harness, io: std.Io, pair: rpc.testing.conformance.Pair) void {
            _ = pair;
            h.client.deinit(io);
            h.server.close(io);
            h.rival.close(io);
            h.broker.deinit();
        }

        /// One more server side on the broker: its `start` fails while the
        /// first one serves the same contracts.
        pub fn sameAddress(h: *Harness, io: std.Io, pair: rpc.testing.conformance.Pair) !rpc.ServerTransport {
            _ = io;
            _ = pair;
            return h.rival.serverTransport();
        }
    };
};

test "the mailbox keeps the rules of rpc transports" {
    var harness: testing.Harness = .{};
    var report = try rpc.testing.conformance.run(std.testing.io, std.testing.allocator, &harness, .{});
    defer report.deinit();
    if (report.failedCount() > 0) {
        std.debug.print("{f}", .{&report});
        return error.TestUnexpectedResult;
    }
}

/// Answers every request with its own body.
const Echo = struct {
    fn handle(_: *anyopaque, _: *rpc.Context, request: []const u8) anyerror![]const u8 {
        return request;
    }
};

const users_route: rpc.Route = .{ .service = "users", .version = 1, .method = "echo" };

/// One call of `users_route` through the client side; the body of its
/// success.
fn echoOnce(client: *Client, io: std.Io, arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    const request: rpc.transport.Request = .{
        .route = users_route,
        .request_id = @splat(1),
        .codec = "json",
        .ctx = core.Context.root.withDeadline(.after(now(io), .fromSeconds(10))),
        .metadata = &.{},
        .body = body,
    };
    const response = try client.clientTransport().call(io, &request, .{ .allocator = arena, .max_response_bytes = 1024 });
    if (response.status != .ok) return error.TestUnexpectedResult;
    return response.body;
}

test "the server answers only in reply queues: a reply_to that names another queue gets nothing" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var broker: Broker = .init(gpa, .{});
    defer broker.deinit();
    // The request queue of another service, as a client that may publish
    // requests could name it in reply_to.
    const orders = try broker.declare(io, "rpc.orders.v1", 16);
    defer {
        broker.unbind(io, orders);
        orders.destroy(io);
    }
    var server_side: Server = .init(&broker);
    var echo: Echo = .{};
    var server: rpc.RawServer = try .init(gpa, .{
        .transport = server_side.serverTransport(),
        .methods = &.{.{ .route = users_route, .handler = .{ .ptr = &echo, .handle = Echo.handle } }},
    });
    defer server.deinit(io);
    try server.start(io);
    var client: Client = try .init(&broker, .{});
    defer client.deinit(io);
    try client.connect(io);

    const forged: rpc.transport.Request = .{
        .route = users_route,
        .request_id = @splat(2),
        .codec = "json",
        .ctx = .root,
        .metadata = &.{},
        .body = "\"forged\"",
    };
    const message = try requestMessage(gpa, io, &forged, "rpc.orders.v1", 1, .fromSeconds(10), now(io));
    broker.publish(io, "rpc.users.v1", message) catch |err| {
        message.destroy();
        return err;
    };
    // A call of the client's own still goes through.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try std.testing.expectEqualStrings("\"own\"", try echoOnce(&client, io, arena.allocator(), "\"own\""));
    // Once the server has stopped, every call it took has ended: nothing
    // went into the queue of orders.
    try server.shutdown(io);
    if (orders.takeLeft(io)) |landed| {
        landed.destroy();
        return error.TestUnexpectedResult;
    }
}

test "a task drops a message of the other kind: a response in a request queue, a request in a reply queue" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var broker: Broker = .init(gpa, .{});
    defer broker.deinit();
    var server_side: Server = .init(&broker);
    var echo: Echo = .{};
    var server: rpc.RawServer = try .init(gpa, .{
        .transport = server_side.serverTransport(),
        .methods = &.{.{ .route = users_route, .handler = .{ .ptr = &echo, .handle = Echo.handle } }},
    });
    defer server.deinit(io);
    try server.start(io);
    var client: Client = try .init(&broker, .{});
    defer client.deinit(io);
    try client.connect(io);

    // A response where the server reads requests, as another server would
    // publish it, answering a reply_to that named this queue.
    try broker.reply(io, "rpc.users.v1", 1, &.{ .status = .ok, .body = "{}" });
    // A request where the client reads responses.
    const stray: rpc.transport.Request = .{
        .route = users_route,
        .request_id = @splat(3),
        .codec = "json",
        .ctx = .root,
        .metadata = &.{},
        .body = "{}",
    };
    const message = try requestMessage(gpa, io, &stray, client.replies.?.name, 1, .fromSeconds(10), now(io));
    broker.publish(io, client.replies.?.name, message) catch |err| {
        message.destroy();
        return err;
    };
    // Both tasks dropped them and go on.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try std.testing.expectEqualStrings("\"after\"", try echoOnce(&client, io, arena.allocator(), "\"after\""));
    try server.shutdown(io);
}
