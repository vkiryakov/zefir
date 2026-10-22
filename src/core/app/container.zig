//! zefir.App(Root): the container type of one application.
const std = @import("std");
const app_ns = @import("../app.zig");
const lifecycle = @import("lifecycle.zig");
const plan = @import("plan.zig");
const store = @import("store.zig");

const Options = app_ns.Options;
const State = app_ns.State;
const Failure = app_ns.Failure;

const log = std.log.scoped(.zefir_app);

/// The application whose root module is Root. Naming the type checks the
/// whole graph: `test { _ = zefir.App(AppModule); }` checks an application
/// without starting anything.
pub fn App(comptime Root: type) type {
    return struct {
        /// App's own fields, as in `http.Server`: read them in tests only.
        internal: Internal,

        pub const Internal = struct {
            gpa: std.mem.Allocator,
            io: std.Io,
            options: Options,
            /// App's one allocation: every bean, the entries and the status.
            /// The App value may move; the block does not.
            block: *Block,
            /// "build order: " and the labels of the beans in creation order.
            build_order: []const u8,
        };

        const Block = store.BlockOf(Root);
        const Values = store.ValuesOf(Root);

        comptime {
            _ = plan.planOf(Root);
        }

        /// Builds every bean in creation order, without I/O and without
        /// tasks. If one fails, the beans built before it are destroyed in
        /// reverse order and its error is returned. `values` is a tuple of
        /// pointers, one per type of `Root.module.values`, in any order:
        /// `.{ &config, &logger }`. `error.InvalidConfiguration`, before
        /// anything is built, when `options.shutdown_timeout` is zero or less.
        pub fn init(gpa: std.mem.Allocator, io: std.Io, values: anytype, options: Options) anyerror!@This() {
            // No stop could end in time.
            if (options.shutdown_timeout.nanoseconds <= 0) return error.InvalidConfiguration;
            const given: Values = store.takeValues(Root, Values, values);
            const steps = comptime store.stepsOf(Root, Block, Values);
            const before = comptime store.entriesBefore(Root);
            const block = try gpa.create(Block);
            block.status = .{};
            for (steps, 0..) |step, i| step(block, gpa, io, &given) catch |err| {
                store.deinitReverse(block.entries[0..before[i]], io);
                gpa.destroy(block);
                return err;
            };
            block.status.internal.entries = &block.entries;
            block.watches = @splat(.{});
            block.runtime = .{ .io = io, .shutdown_timeout = options.shutdown_timeout, .status = &block.status, .watches = &block.watches };
            const build_order = comptime plan.planOf(Root).build_order;
            log.debug("{s}", .{build_order});
            return .{ .internal = .{ .gpa = gpa, .io = io, .options = options, .block = block, .build_order = build_order } };
        }

        /// `start`, then `wait`: for `main`. When the stop runs out of time
        /// (`error.ShutdownTimeout`), tasks may still use the beans and
        /// nothing may be freed: `run` writes which bean did not stop, to
        /// the log and straight to stderr, and ends the process with code 1.
        /// Any other error is returned; `failure()` says whose it is.
        pub fn run(app: *@This()) anyerror!void {
            return lifecycle.run(&app.internal.block.runtime);
        }

        /// Starts the beans in creation order and returns once all are
        /// ready. When one fails, those already started are stopped in
        /// reverse order, within a budget of their own, and its error is
        /// returned. A stop requested meanwhile lets the current start end,
        /// starts no more and returns `{}`. `error.InvalidState` unless the
        /// App was just built: there is no restart.
        pub fn start(app: *@This()) anyerror!void {
            return lifecycle.start(&app.internal.block.runtime);
        }

        /// Waits for the end of the stop. `{}`: stopped on request; a
        /// bean's error: it stopped by itself, and App stopped the rest
        /// (`failure()` names it); `error.ShutdownTimeout`: the stop ran out
        /// of its budget. Canceling `wait` stops nothing.
        pub fn wait(app: *@This()) anyerror!void {
            return lifecycle.wait(&app.internal.block.runtime);
        }

        /// Begins the stop. From any task and any thread, but not from a
        /// signal handler; never waits; a second call does nothing.
        pub fn requestStop(app: *@This()) void {
            lifecycle.requestStop(&app.internal.block.runtime);
        }

        /// `requestStop`, then `wait`.
        pub fn shutdown(app: *@This()) anyerror!void {
            app.requestStop();
            return app.wait();
        }

        pub fn state(app: *const @This()) State {
            return app.internal.block.status.state();
        }

        /// Running, and every bean with `isReady` is ready. False from the
        /// first step of the stop on.
        pub fn isReady(app: *const @This()) bool {
            return app.internal.block.status.isReady();
        }

        /// The first cause of the stop or of the failure; null when all
        /// went well.
        pub fn failure(app: *const @This()) ?Failure {
            return lifecycle.failure(&app.internal.block.runtime);
        }

        /// Destroys the beans App built, in reverse creation order, then
        /// frees the block. A running App is stopped first. Values are
        /// never destroyed.
        pub fn deinit(app: *@This()) void {
            const block = app.internal.block;
            if (!lifecycle.finish(&block.runtime)) return;
            store.deinitReverse(&block.entries, app.internal.io);
            app.internal.gpa.destroy(block);
            app.* = undefined;
        }

        /// The bean of type T (a type is one bean), for tests and `main`.
        /// Name the type to have its fields completed:
        /// `const svc: *UserService = app.get(UserService);`.
        pub fn get(app: *const @This(), comptime T: type) *T {
            return &app.internal.block.beans[comptime store.beanIndex(Root, T)];
        }
    };
}
