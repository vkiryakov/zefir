//! zefir.App(Root): the container type of one application.
const std = @import("std");
const Options = @import("../app.zig").Options;
const plan = @import("plan.zig");
const store = @import("store.zig");

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
        /// `.{ &config, &logger }`.
        pub fn init(gpa: std.mem.Allocator, io: std.Io, values: anytype, options: Options) anyerror!@This() {
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
            const build_order = comptime plan.planOf(Root).build_order;
            log.debug("{s}", .{build_order});
            return .{ .internal = .{ .gpa = gpa, .io = io, .options = options, .block = block, .build_order = build_order } };
        }

        /// Destroys the beans App built, in reverse creation order, then
        /// frees the block. Values are never destroyed.
        pub fn deinit(app: *@This()) void {
            const block = app.internal.block;
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
