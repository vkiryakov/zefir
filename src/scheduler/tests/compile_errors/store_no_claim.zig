//! Must not compile: a store without the method claim.
const scheduler = @import("scheduler");
const Methods = @import("stores.zig").Methods;

const BadStore = struct {
    x: u8 = 0,

    pub const name = "bad";
    const M = Methods(BadStore);
    pub const now = M.now;
    pub const create = M.create;
    pub const get = M.get;
    pub const update = M.update;
    pub const remove = M.remove;
    pub const list = M.list;
    pub const renew = M.renew;
    pub const finish = M.finish;
    pub const history = M.history;
};

test {
    var store: BadStore = .{};
    _ = scheduler.Store.init(&store);
}
