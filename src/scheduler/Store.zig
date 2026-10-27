//! The store contract of the scheduler: the scheduler keeps its jobs only
//! through it, so the same code runs on any store that keeps its rules. A
//! store is a type with `pub const name: []const u8` and the methods of
//! `Store.VTable`, with `self: *T` in place of `*anyopaque`, handed out
//! through `Store.init`:
//!
//! ```zig
//! pub fn store(self: *MyStore) scheduler.Store {
//!     return .init(self);
//! }
//! ```
//!
//! A mistake in a method stops the build with a message that names the
//! method and the signature to write. `scheduler.MemoryStore` keeps the
//! records in memory, `mongo.SchedulerStore` in MongoDB; a store that
//! passes `scheduler.testing.conformance` works with the scheduler. The
//! store keeps records and changes them only on condition; what comes next
//! (the next run, a retry, a skip, a pause, how long to keep) the
//! scheduler decides, the same for every store.
//!
//! A record is one job: `(job, key)` is unique in the store. A record
//! created again with the same key, after a cancel or over a finished one,
//! is a new life: a new `life`, and its `fence` and `attempt` count from 0.
//! `pending` waits for `run_at`; `running` has an `owner`, a `fence` and a
//! `lease_until`; `paused` waits for `unpause` and keeps `run_at`;
//! `succeeded` and `failed` are finished and kept until `expires_at`, or
//! always. A removed record is gone.
//!
//! When a record may be claimed, the store keeps by itself and sets with
//! every change of state: a pending record from its `run_at`, a running
//! one from its `lease_until`, a paused or finished one never. A claim
//! takes a record whose time came by the store's clock if its job is in the
//! claim's `any_key`, or in `keyed_only` and its key is not "": the record
//! of a declared job (key "") goes only to an instance that declares it.
//! `run_at` of a running, succeeded or failed record is null; a change of
//! the client to a running record (`Patch.run_at`) shows as a new
//! `scheduled_at` with `attempt` 0. A claim is known by `(life, owner,
//! fence)`, which `renew` and `finish` carry: the run of a removed record
//! never renews or finishes a new record with the same key, even of the
//! same owner and fence. A change of the client holds on `(life, revision,
//! state)`, which `update` expects: only a change of the client raises
//! `revision`, and a new life starts again at revision 0 and pending, so
//! the life keeps a change read on a removed record from landing on a new
//! record with the same key. Every transition of `finish` clears
//! `pause_requested`: the pause it asked for is done.
//!
//! The rules:
//!
//! 1. Concurrency. Any tasks and threads call a store at once; it guards
//!    what they share with `std.Io` primitives (a lock of the OS would stop
//!    a thread of the runtime).
//! 2. `io` is the one the store was made with, and every wait goes through
//!    it.
//! 3. The deadline of `ctx`. With less than 1 ms left before sending, the
//!    call is `error.DeadlineExceeded`, and nothing was done. After sending,
//!    the store waits no longer than the deadline; when it passes, the
//!    store resolves the outcome (rule 7) or answers
//!    `error.OutcomeUnknown`.
//! 4. Cancellation. The store checks the token before sending
//!    (`error.Cancelled`). A cancel of the task ends a wait, and the task
//!    stays cancelled.
//! 5. Memory. The request and its slices are borrowed until the call
//!    returns. What the result points to comes from `options.allocator`,
//!    during the call only; after a call the store holds no reference to
//!    the caller's memory.
//! 6. Atomic by record. Each operation on one record is atomic; a claim
//!    gives a record to one claimer.
//! 7. Unknown outcomes. The store resolves one where it can, reading the
//!    record again by `tag`, `life`, `owner` and `fence`; else it answers
//!    `error.OutcomeUnknown`. A definite answer it is not sure of breaks
//!    the contract. It sends again only what changes nothing the second
//!    time: an insert of the same life, a write on the same condition.
//! 8. Durability. A definite success survives a restart of the store
//!    (MongoDB: the journal on disk, `j: true`); `MemoryStore` is the
//!    exception, and says so.
//! 9. No retries but those of rule 7: retries are the scheduler's.
//! 10. Errors: only `StoreError`; the texts of `Diagnostics` never hold a
//!     payload or a password.
//!
//! Every time the store writes is its own clock, to the millisecond:
//! whether a record is due, whether a lease expired, `claimed_at`,
//! `finished_at`, `created_at`, `.after`, `expires_at`. `now` is the
//! process's estimate of that clock, without I/O.

const std = @import("std");
const Io = std.Io;
const Duration = Io.Duration;
const Allocator = std.mem.Allocator;
const core = @import("core");
const Diagnostics = @import("Diagnostics.zig");
const Instant = @import("Instant.zig");
const record = @import("record.zig");
const signature = @import("signature.zig");
const Ref = record.Ref;
const Record = record.Record;
const Run = record.Run;
const LastRun = record.LastRun;
const Life = record.Life;
const State = record.State;
const Retention = record.Retention;

const Store = @This();

ptr: *anyopaque,
vtable: *const VTable,

/// What a store returns: a closed set, each name in its class of
/// `outcome`.
pub const StoreError = error{
    /// The request breaks a rule of the store (a name too long for it…).
    /// Nothing was done.
    InvalidArgument,
    /// The store cannot be reached or is busy (no link, the pool). Nothing
    /// was done.
    Unavailable,
    /// Less than 1 ms was left of the deadline of `ctx` before sending.
    /// Nothing was done.
    DeadlineExceeded,
    /// The token or the task was cancelled before sending. Nothing was done.
    Cancelled,
    /// The store refused, and the change is known not to be applied: a
    /// refusal before it ran (rights, login), or one that reading the
    /// record again confirmed.
    Refused,
    /// The request may have arrived, and its outcome is unknown: reading
    /// the record again failed, or cannot tell whether the request may
    /// still apply.
    OutcomeUnknown,
    /// A record of the store does not read (damaged, or of another
    /// format). The call may have changed the store: a store that applied
    /// a change and cannot read the record it changed answers so, as a
    /// claim that took a record before it read it.
    Corrupt,
    OutOfMemory,
};

/// What the calls of the client return: the errors of the store, and a race
/// of changes lost 8 times in a row.
pub const Error = StoreError || error{Contended};

/// Whether a call that failed may have changed the store.
pub const Outcome = enum {
    /// Nothing was changed.
    not_applied,
    /// The change may have been applied.
    unknown,
};

/// The class of `err`: `OutcomeUnknown`, `Corrupt` and `OutOfMemory` are
/// `.unknown`, the rest `.not_applied`. The switch is the table: a new name
/// of `Error` stops the build until it has a class.
pub fn outcome(err: Error) Outcome {
    return switch (err) {
        error.OutcomeUnknown, error.Corrupt, error.OutOfMemory => .unknown,
        error.InvalidArgument,
        error.Unavailable,
        error.DeadlineExceeded,
        error.Cancelled,
        error.Refused,
        error.Contended,
        => .not_applied,
    };
}

/// The store behind the interface: one constant table per store type,
/// built by `init`.
pub const VTable = struct {
    /// "memory", "mongodb": for logs and the report of the conformance
    /// suite.
    name: []const u8,
    now: *const fn (ptr: *anyopaque, io: Io) Instant,
    create: *const fn (ptr: *anyopaque, io: Io, ctx: core.Context, request: *const CreateRequest, options: CallOptions) StoreError!CreateResult,
    get: *const fn (ptr: *anyopaque, io: Io, ctx: core.Context, ref: *const Ref, options: CallOptions) StoreError!?Record,
    update: *const fn (ptr: *anyopaque, io: Io, ctx: core.Context, request: *const UpdateRequest, options: CallOptions) StoreError!UpdateResult,
    remove: *const fn (ptr: *anyopaque, io: Io, ctx: core.Context, ref: *const Ref, options: CallOptions) StoreError!bool,
    list: *const fn (ptr: *anyopaque, io: Io, ctx: core.Context, request: *const ListRequest, options: CallOptions) StoreError!record.RecordPage,
    claim: *const fn (ptr: *anyopaque, io: Io, ctx: core.Context, request: *const ClaimRequest, options: CallOptions) StoreError!ClaimResult,
    renew: *const fn (ptr: *anyopaque, io: Io, ctx: core.Context, request: *const RenewRequest, options: CallOptions) StoreError!RenewResult,
    finish: *const fn (ptr: *anyopaque, io: Io, ctx: core.Context, request: *const FinishRequest, options: CallOptions) StoreError!FinishResult,
    history: *const fn (ptr: *anyopaque, io: Io, ctx: core.Context, request: *const HistoryRequest, options: CallOptions) StoreError!record.RunPage,
};

pub const CallOptions = struct {
    /// The memory of the result; usually the arena of the call.
    allocator: Allocator,
    diagnostics: ?*Diagnostics = null,
};

const interface = "scheduler: Store.init";

/// The interface of `impl: *T`, where `T` has `pub const name: []const u8`
/// and the methods of `VTable` with `self: *T` in place of `*anyopaque`.
/// The table is built at compile time; a missing method or another
/// signature stops the build with a message that names it and the
/// signature to write.
pub fn init(impl: anytype) Store {
    const Ptr = @TypeOf(impl);
    const T = signature.expectPointer(interface, "store", Ptr);
    comptime {
        if (!@hasDecl(T, "name") or !signature.isString(@TypeOf(T.name)))
            @compileError(interface ++ ": " ++ signature.shortName(T) ++ " has no pub const name: []const u8");
        signature.expectMethod(interface, T, "now", fn (Ptr, Io) Instant, "pub fn now(self: *" ++ signature.shortName(T) ++ ", io: std.Io) scheduler.Instant");
        signature.expectMethod(interface, T, "create", fn (Ptr, Io, core.Context, *const CreateRequest, CallOptions) StoreError!CreateResult, operation(T, "create", "request: *const scheduler.Store.CreateRequest", "scheduler.Store.CreateResult"));
        signature.expectMethod(interface, T, "get", fn (Ptr, Io, core.Context, *const Ref, CallOptions) StoreError!?Record, operation(T, "get", "ref: *const scheduler.Ref", "?scheduler.Record"));
        signature.expectMethod(interface, T, "update", fn (Ptr, Io, core.Context, *const UpdateRequest, CallOptions) StoreError!UpdateResult, operation(T, "update", "request: *const scheduler.Store.UpdateRequest", "scheduler.Store.UpdateResult"));
        signature.expectMethod(interface, T, "remove", fn (Ptr, Io, core.Context, *const Ref, CallOptions) StoreError!bool, operation(T, "remove", "ref: *const scheduler.Ref", "bool"));
        signature.expectMethod(interface, T, "list", fn (Ptr, Io, core.Context, *const ListRequest, CallOptions) StoreError!record.RecordPage, operation(T, "list", "request: *const scheduler.Store.ListRequest", "scheduler.RecordPage"));
        signature.expectMethod(interface, T, "claim", fn (Ptr, Io, core.Context, *const ClaimRequest, CallOptions) StoreError!ClaimResult, operation(T, "claim", "request: *const scheduler.Store.ClaimRequest", "scheduler.Store.ClaimResult"));
        signature.expectMethod(interface, T, "renew", fn (Ptr, Io, core.Context, *const RenewRequest, CallOptions) StoreError!RenewResult, operation(T, "renew", "request: *const scheduler.Store.RenewRequest", "scheduler.Store.RenewResult"));
        signature.expectMethod(interface, T, "finish", fn (Ptr, Io, core.Context, *const FinishRequest, CallOptions) StoreError!FinishResult, operation(T, "finish", "request: *const scheduler.Store.FinishRequest", "scheduler.Store.FinishResult"));
        signature.expectMethod(interface, T, "history", fn (Ptr, Io, core.Context, *const HistoryRequest, CallOptions) StoreError!record.RunPage, operation(T, "history", "request: *const scheduler.Store.HistoryRequest", "scheduler.RunPage"));
    }
    const gen = struct {
        fn self(ptr: *anyopaque) Ptr {
            return @ptrCast(@alignCast(ptr));
        }
        fn nowFn(ptr: *anyopaque, io: Io) Instant {
            return T.now(self(ptr), io);
        }
        fn createFn(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const CreateRequest, options: CallOptions) StoreError!CreateResult {
            return T.create(self(ptr), io, ctx, request, options);
        }
        fn getFn(ptr: *anyopaque, io: Io, ctx: core.Context, ref: *const Ref, options: CallOptions) StoreError!?Record {
            return T.get(self(ptr), io, ctx, ref, options);
        }
        fn updateFn(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const UpdateRequest, options: CallOptions) StoreError!UpdateResult {
            return T.update(self(ptr), io, ctx, request, options);
        }
        fn removeFn(ptr: *anyopaque, io: Io, ctx: core.Context, ref: *const Ref, options: CallOptions) StoreError!bool {
            return T.remove(self(ptr), io, ctx, ref, options);
        }
        fn listFn(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const ListRequest, options: CallOptions) StoreError!record.RecordPage {
            return T.list(self(ptr), io, ctx, request, options);
        }
        fn claimFn(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const ClaimRequest, options: CallOptions) StoreError!ClaimResult {
            return T.claim(self(ptr), io, ctx, request, options);
        }
        fn renewFn(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const RenewRequest, options: CallOptions) StoreError!RenewResult {
            return T.renew(self(ptr), io, ctx, request, options);
        }
        fn finishFn(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const FinishRequest, options: CallOptions) StoreError!FinishResult {
            return T.finish(self(ptr), io, ctx, request, options);
        }
        fn historyFn(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const HistoryRequest, options: CallOptions) StoreError!record.RunPage {
            return T.history(self(ptr), io, ctx, request, options);
        }
        const vtable: VTable = .{
            .name = T.name,
            .now = nowFn,
            .create = createFn,
            .get = getFn,
            .update = updateFn,
            .remove = removeFn,
            .list = listFn,
            .claim = claimFn,
            .renew = renewFn,
            .finish = finishFn,
            .history = historyFn,
        };
    };
    return .{ .ptr = impl, .vtable = &gen.vtable };
}

/// How to declare the method of an operation, for the messages.
fn operation(comptime T: type, comptime method: []const u8, comptime param: []const u8, comptime result: []const u8) []const u8 {
    return "pub fn " ++ method ++ "(self: *" ++ signature.shortName(T) ++ ", io: std.Io, ctx: core.Context, " ++ param ++
        ", options: scheduler.Store.CallOptions) scheduler.StoreError!" ++ result;
}

/// The store's clock as the process knows it, without I/O. The scheduler
/// takes it only for the first run of a new repeating job.
pub fn now(s: Store, io: Io) Instant {
    return s.vtable.now(s.ptr, io);
}

/// A record of a new life, pending from `request.run_at`; a finished record
/// with the same `(job, key)` is replaced, a live one stays as it is.
pub fn create(s: Store, io: Io, ctx: core.Context, request: *const CreateRequest, options: CallOptions) StoreError!CreateResult {
    return s.vtable.create(s.ptr, io, ctx, request, options);
}

/// The record of `ref`, or null.
pub fn get(s: Store, io: Io, ctx: core.Context, ref: *const Ref, options: CallOptions) StoreError!?Record {
    return s.vtable.get(s.ptr, io, ctx, ref, options);
}

/// `request.set`, when the record's life, revision and state are those of
/// `request.expect`.
pub fn update(s: Store, io: Io, ctx: core.Context, request: *const UpdateRequest, options: CallOptions) StoreError!UpdateResult {
    return s.vtable.update(s.ptr, io, ctx, request, options);
}

/// Removes the record in any state; true when it was there.
pub fn remove(s: Store, io: Io, ctx: core.Context, ref: *const Ref, options: CallOptions) StoreError!bool {
    return s.vtable.remove(s.ptr, io, ctx, ref, options);
}

/// The records of the filter, a page at a time: those of a job together,
/// their keys in order; which job comes first is the store's choice.
pub fn list(s: Store, io: Io, ctx: core.Context, request: *const ListRequest, options: CallOptions) StoreError!record.RecordPage {
    return s.vtable.list(s.ptr, io, ctx, request, options);
}

/// Claims the due records of the request's jobs, the oldest first, at most
/// `request.max`.
pub fn claim(s: Store, io: Io, ctx: core.Context, request: *const ClaimRequest, options: CallOptions) StoreError!ClaimResult {
    return s.vtable.claim(s.ptr, io, ctx, request, options);
}

/// Renews the lease of a claim.
pub fn renew(s: Store, io: Io, ctx: core.Context, request: *const RenewRequest, options: CallOptions) StoreError!RenewResult {
    return s.vtable.renew(s.ptr, io, ctx, request, options);
}

/// Writes the rows of the history, then the transition of a claim.
pub fn finish(s: Store, io: Io, ctx: core.Context, request: *const FinishRequest, options: CallOptions) StoreError!FinishResult {
    return s.vtable.finish(s.ptr, io, ctx, request, options);
}

/// The rows of the filter, the newest first, a page at a time.
pub fn history(s: Store, io: Io, ctx: core.Context, request: *const HistoryRequest, options: CallOptions) StoreError!record.RunPage {
    return s.vtable.history(s.ptr, io, ctx, request, options);
}

/// When a record starts waiting; the store resolves `.after` by its clock.
pub const Moment = union(enum) { at: Instant, after: Duration };

/// A mark of a write, by which a store knows its own change after a lost
/// reply: 16 random bytes.
pub const Tag = [16]u8;

pub const CreateRequest = struct {
    job: []const u8,
    key: []const u8,
    tenant: ?[]const u8 = null,
    life: Life,
    plan: []const u8,
    payload: []const u8,
    trace: ?[]const u8 = null,
    /// `run_at` and `scheduled_at` are this moment.
    run_at: Moment,
};

pub const CreateResult = enum {
    created,
    /// A finished record of the same key was replaced.
    replaced,
    /// A live record of the key is there; it was not changed.
    existing,
};

/// What `update` sets; null and false leave a field alone.
pub const Patch = struct {
    /// Pending or paused only; when the record may be claimed, the store
    /// sets by the state after the change. A finished record that becomes
    /// pending or paused loses its `finished_at` and `expires_at`.
    state: ?State = null,
    /// Sets `run_at` and `scheduled_at` to this moment and `attempt` to 0;
    /// a running record keeps its null `run_at`.
    run_at: ?Moment = null,
    plan: ?[]const u8 = null,
    pause_requested: ?bool = null,
    /// The retry of a failed record: due now, so pending (unless `state`
    /// says paused), `run_at` the store's now and `attempt` 0, without
    /// `unreadable_since`, `expires_at` and `finished_at`; `scheduled_at`
    /// and with it the run key stay.
    reset: bool = false,
};

pub const UpdateRequest = struct {
    ref: Ref,
    /// The record as the change read it: a record of another life, made
    /// again with the key since, is not changed.
    expect: struct { life: Life, revision: u64, state: State },
    set: Patch,
    tag: Tag,
};

pub const UpdateResult = union(enum) {
    /// The new revision.
    updated: u64,
    /// The change was not applied: the record is of another life, or has
    /// another revision or state. Here it is now.
    conflict: Record,
    not_found,
};

pub const ListRequest = struct { filter: record.ListFilter, page: record.Page };

pub const ClaimRequest = struct {
    owner: []const u8,
    /// The jobs this instance declares with `.repeat`: their records with
    /// any key, the record of the declaration (key "") too.
    any_key: []const []const u8,
    /// The other jobs the worker knows: only their records with a key that
    /// is not "". The record of a declaration that is not here is never
    /// claimed.
    keyed_only: []const []const u8,
    /// At most this many records; 1 or more.
    max: u32,
    lease: Duration,
    /// The mark of the claim: the k-th record claimed gets its own, this
    /// one and its number (`<tag>-<k>`), so that after a lost reply the
    /// store finds exactly it.
    tag: Tag,
};

pub const ClaimResult = struct {
    /// The records after the claim: running, `attempt` and `fence` one more,
    /// `claimed_at` and `lease_until` by the store's clock. The oldest
    /// first.
    claimed: []const Claimed,
    /// When fewer than `max` were claimed: how soon the nearest record that
    /// this claim would take may be claimed (0 or less: already); null when
    /// there is none. Records it would not take (declarations of
    /// `keyed_only` jobs) do not count, or a parked record with a past
    /// `run_at` would wake the poll.
    next_in: ?Duration,
};

pub const Claimed = struct {
    record: Record,
    /// The record was running with an expired lease: whose it was.
    took_over: ?TookOver,
};

/// The claim that a claim took over: its owner and when it was made.
pub const TookOver = struct { owner: []const u8, claimed_at: Instant };

pub const RenewRequest = struct { ref: Ref, life: Life, owner: []const u8, fence: u64, lease: Duration };

pub const RenewResult = enum {
    renewed,
    /// A record of the same life, but another claim: it was taken over.
    lost,
    /// No record, or another life: it was removed (cancel).
    removed,
};

pub const FinishRequest = struct {
    ref: Ref,
    life: Life,
    owner: []const u8,
    fence: u64,
    revision: u64,
    /// The mark of the transition: the store writes it into the record, and
    /// reading the record after a lost reply tells "applied" from "taken
    /// over".
    tag: Tag,
    next: Next,
    /// What the record shows of the run; the store sets `finished_at`.
    /// null leaves `last` alone (the return of a job no instance reads).
    last: ?LastRun,
    /// The rows of the history to write before the transition (0–2: of the
    /// abandoned attempt this claim took over, and of this run) and how
    /// long to keep them; `.none` writes none. The store sets their
    /// `finished_at` and `expires_at`.
    history: struct { runs: []const Run = &.{}, keep: Retention = .none } = .{},
};

pub const Next = union(enum) {
    /// Waits again: pending or paused, from `run_at`; `scheduled_at` is
    /// this moment, or the moment of `run_at` when null; `unreadable_since`
    /// is what to write (null clears it).
    wait: struct { state: State, run_at: Moment, scheduled_at: ?Instant, attempt: u32, unreadable_since: ?Instant = null },
    /// Finished and kept: succeeded or failed, for a time or always.
    done: struct { state: State, keep: Retention },
    /// Removes the record.
    delete,
};

pub const FinishResult = union(enum) {
    done,
    /// Not this claim: the record was taken over or removed, or it is
    /// another life.
    lost,
    /// This owner's claim, but another revision: the record as it is now.
    changed: Record,
};

pub const HistoryRequest = struct { filter: record.HistoryFilter, page: record.Page };
