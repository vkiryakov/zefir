//! Not a fixture: the methods of a store for the fixtures of Store.init.
//! Each fixture's `BadStore` takes the methods it needs from
//! `Methods(BadStore)`, so that its own mistake is the only one.
const std = @import("std");
const core = @import("core");
const scheduler = @import("scheduler");
const Io = std.Io;
const Store = scheduler.Store;
const E = scheduler.StoreError;

pub fn Methods(comptime T: type) type {
    return struct {
        pub fn now(_: *T, _: Io) scheduler.Instant {
            return .fromUnixMs(0);
        }
        pub fn create(_: *T, _: Io, _: core.Context, _: *const Store.CreateRequest, _: Store.CallOptions) E!Store.CreateResult {
            return .created;
        }
        pub fn get(_: *T, _: Io, _: core.Context, _: *const scheduler.Ref, _: Store.CallOptions) E!?scheduler.Record {
            return null;
        }
        pub fn update(_: *T, _: Io, _: core.Context, _: *const Store.UpdateRequest, _: Store.CallOptions) E!Store.UpdateResult {
            return .not_found;
        }
        pub fn remove(_: *T, _: Io, _: core.Context, _: *const scheduler.Ref, _: Store.CallOptions) E!bool {
            return false;
        }
        pub fn list(_: *T, _: Io, _: core.Context, _: *const Store.ListRequest, _: Store.CallOptions) E!scheduler.RecordPage {
            return .{ .records = &.{}, .next = null };
        }
        pub fn claim(_: *T, _: Io, _: core.Context, _: *const Store.ClaimRequest, _: Store.CallOptions) E!Store.ClaimResult {
            return .{ .claimed = &.{}, .next_in = null };
        }
        pub fn renew(_: *T, _: Io, _: core.Context, _: *const Store.RenewRequest, _: Store.CallOptions) E!Store.RenewResult {
            return .removed;
        }
        pub fn finish(_: *T, _: Io, _: core.Context, _: *const Store.FinishRequest, _: Store.CallOptions) E!Store.FinishResult {
            return .lost;
        }
        pub fn history(_: *T, _: Io, _: core.Context, _: *const Store.HistoryRequest, _: Store.CallOptions) E!scheduler.RunPage {
            return .{ .runs = &.{}, .next = null };
        }
    };
}
