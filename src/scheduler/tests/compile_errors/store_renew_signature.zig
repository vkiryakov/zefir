//! Must not compile: renew answers whether it renewed, not a RenewResult.
const std = @import("std");
const core = @import("core");
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
    pub const claim = M.claim;
    pub const finish = M.finish;
    pub const history = M.history;

    pub fn renew(_: *BadStore, _: std.Io, _: core.Context, _: *const scheduler.Store.RenewRequest, _: scheduler.Store.CallOptions) scheduler.StoreError!bool {
        return true;
    }
};

test {
    var store: BadStore = .{};
    _ = scheduler.Store.init(&store);
}
