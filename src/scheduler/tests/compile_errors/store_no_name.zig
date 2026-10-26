//! Must not compile: a store names itself with pub const name.
const scheduler = @import("scheduler");

const BadStore = struct {
    x: u8 = 0,
};

test {
    var store: BadStore = .{};
    _ = scheduler.Store.init(&store);
}
