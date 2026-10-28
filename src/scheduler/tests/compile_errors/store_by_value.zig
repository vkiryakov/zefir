//! Must not compile: Store.init takes a pointer to the store.
const scheduler = @import("scheduler");

const BadStore = struct {
    pub const name = "bad";
};

test {
    var store: BadStore = .{};
    _ = &store;
    _ = scheduler.Store.init(store);
}
