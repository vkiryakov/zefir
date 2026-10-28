//! A MemoryStore whose pause of a pending record at revision 0 stalls
//! between the read of its client and the write, as the task of a client
//! may, until one pause has met a new life: meanwhile the record moves on
//! to revision 1, a claim of the load takes it on that revision, and it is
//! removed and created again with a new life, pending at revision 0. The
//! pause then meets the new life, whose revision and state are those it
//! expects, and an update holds on the life too: it is refused with a
//! conflict. A store that let it land would have a load that notes the
//! pause for the life it read see a claim of a paused record that never
//! was.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const scheduler = @import("../root.zig");
const Store = scheduler.Store;
const MemoryStore = scheduler.MemoryStore;

pub const StalledPause = struct {
    memory: MemoryStore,
    vtable: Store.VTable,
    gpa: Allocator,
    /// A pause stalls now: one at a time.
    stalling: std.atomic.Value(bool) = .init(false),
    /// The lives of the records the stalls created.
    lives: u64 = 0,
    /// A pause met a new life, after a claim of the life before, and was
    /// refused.
    refused: std.atomic.Value(bool) = .init(false),

    /// Made in place: the store points at its fields.
    pub fn init(s: *StalledPause, gpa: Allocator, io: Io, options: MemoryStore.Options) void {
        s.* = .{ .memory = .init(gpa, io, options), .vtable = undefined, .gpa = gpa };
        s.vtable = s.memory.store().vtable.*;
        s.vtable.name = "stalled-pause";
        s.vtable.update = update;
    }

    pub fn deinit(s: *StalledPause) void {
        s.memory.deinit();
    }

    pub fn store(s: *StalledPause) Store {
        return .{ .ptr = &s.memory, .vtable = &s.vtable };
    }

    /// Until a pause has met a new life, the pause of a pending record at
    /// revision 0 stalls first.
    fn update(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const Store.UpdateRequest, options: Store.CallOptions) scheduler.StoreError!Store.UpdateResult {
        const memory: *MemoryStore = @ptrCast(@alignCast(ptr));
        const s: *StalledPause = @fieldParentPtr("memory", memory);
        const pause = request.set.state == .paused and request.expect.state == .pending and request.expect.revision == 0;
        if (!pause or s.refused.load(.acquire) or s.stalling.swap(true, .acquire)) return memory.update(io, ctx, request, options);
        defer s.stalling.store(false, .release);
        const reborn = s.stall(io, ctx, &request.ref);
        const result = try memory.update(io, ctx, request, options);
        if (reborn and result == .conflict and !std.mem.eql(u8, &result.conflict.life, &request.expect.life)) s.refused.store(true, .release);
        return result;
    }

    /// What other clients and a claim of the load do while the pause
    /// stalls: the record of `ref` moves on to revision 1, due now; a claim
    /// takes it on that revision; it is removed and created again with a
    /// new life. Whether it got so far, waiting 2 s at most for the claim.
    fn stall(s: *StalledPause, io: Io, ctx: core.Context, ref: *const scheduler.Ref) bool {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const options: Store.CallOptions = .{ .allocator = arena.allocator() };
        const before = (s.memory.get(io, ctx, ref, options) catch return false) orelse return false;
        const life = before.life;
        const moved: Store.UpdateRequest = .{ .ref = ref.*, .expect = .{ .life = life, .revision = 0, .state = .pending }, .set = .{ .run_at = .{ .after = .zero } }, .tag = @splat(0xEE) };
        const result = s.memory.update(io, ctx, &moved, options) catch return false;
        if (result != .updated) return false;
        const give_up = Io.Clock.awake.now(io).addDuration(.fromSeconds(2));
        while (true) {
            _ = arena.reset(.retain_capacity);
            const now = (s.memory.get(io, ctx, ref, options) catch return false) orelse return false;
            if (!std.mem.eql(u8, &now.life, &life) or now.revision != 1) return false;
            if (now.state == .running) break;
            if (Io.Clock.awake.now(io).nanoseconds > give_up.nanoseconds) return false;
            io.sleep(.fromMicroseconds(100), .awake) catch {
                io.recancel();
                return false;
            };
        }
        _ = s.memory.remove(io, ctx, ref, options) catch return false;
        s.lives += 1;
        var new_life: scheduler.Life = @splat(0xEE);
        std.mem.writeInt(u64, new_life[1..9], s.lives, .little);
        const request: Store.CreateRequest = .{ .job = ref.job, .key = ref.key, .life = new_life, .plan = "", .payload = "{}", .run_at = .{ .after = .zero } };
        const created = s.memory.create(io, ctx, &request, options) catch return false;
        return created == .created;
    }
};
