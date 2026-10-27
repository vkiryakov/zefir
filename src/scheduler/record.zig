//! What a store keeps of a job and of each claim of it, how a call names a
//! job, and the filters and pages of the lists. `scheduler.Client` and the
//! store contract `scheduler.Store` speak in these types.

const std = @import("std");
const Duration = std.Io.Duration;
const Allocator = std.mem.Allocator;
const Diagnostics = @import("Diagnostics.zig");
const Instant = @import("Instant.zig");
const job_type = @import("Job.zig");
const payload_json = @import("payload.zig");

/// Which job: the name of its type and its key. `.of(SendInvoice,
/// "order-42")` in code, or `.{ .job = "send-invoice", .key = "order-42" }`
/// in an admin page. The record of a declared repeating job has the key "".
pub const Ref = struct {
    job: []const u8,
    key: []const u8,

    /// The job of type `J` with `key`; the compiler checks `J`.
    pub fn of(comptime J: type, key: []const u8) Ref {
        job_type.assertJob(J);
        return .{ .job = J.scheduler_job.name, .key = key };
    }

    /// The record of the declaration of `J`: the key "". This is how the
    /// parked record of a declaration that left the code is removed:
    /// `client.cancel(io, ctx, .declared(NightlyCleanup), .{})`.
    pub fn declared(comptime J: type) Ref {
        job_type.assertJob(J);
        return .{ .job = J.scheduler_job.name, .key = "" };
    }
};

/// The options of a call of the client: `d.message()` says why it failed.
pub const CallOptions = struct { diagnostics: ?*Diagnostics = null };

/// Which records `list` gives: null takes any.
pub const ListFilter = struct { job: ?[]const u8 = null, tenant: ?[]const u8 = null, state: ?State = null };

/// Which rows of the history `history` gives: null takes any. `outcome`
/// takes the outcomes without a handler too: `.skipped`, and `.abandoned`
/// for the attempts whose effects are unknown (financial control).
pub const HistoryFilter = struct {
    job: ?[]const u8 = null,
    key: ?[]const u8 = null,
    tenant: ?[]const u8 = null,
    outcome: ?RunOutcome = null,
};

/// One page of a list: `after` is the `next` of the page before, a text
/// of the store; null starts at the beginning.
pub const Page = struct { after: ?[]const u8 = null, limit: u32 = 100 };
/// Records in the order (job, key); `next` is null after the last page.
pub const RecordPage = struct { records: []const Record, next: ?[]const u8 };
/// Rows of the history, the newest first; `next` is null after the last
/// page.
pub const RunPage = struct { runs: []const Run, next: ?[]const u8 };

/// Where a job is: waiting for its time, running, paused, or finished and
/// kept for its history. A cancelled job has no record.
pub const State = enum { pending, running, paused, succeeded, failed };

/// The outcome of one claim.
pub const RunOutcome = enum {
    succeeded,
    /// The handler returned an error.
    failed,
    timed_out,
    /// The worker itself stopped the run; `error_name` says why:
    /// "Shutdown", "LeaseUnconfirmed", "LeaseLost" (taken over),
    /// "Cancelled" (the record was removed).
    interrupted,
    /// The handler did not run: a run of a repeating job later than its
    /// `.skip` allows.
    skipped,
    /// The owner's instance was lost before it reported: the next owner
    /// writes this row, and the effects of the attempt are unknown.
    abandoned,
};

/// The 16 random bytes of one life of a record: a record created again
/// with the same key has a new life.
pub const Life = [16]u8;

/// How long to keep something, by the store's clock: nothing, for a time,
/// or always.
pub const Retention = union(enum) { none, keep_for: Duration, forever };

/// What a store keeps of a job.
pub const Record = struct {
    job: []const u8,
    key: []const u8,
    tenant: ?[]const u8,
    state: State,
    /// "" for a one-shot job; else the canonical text of its schedule.
    plan: []const u8,
    /// The JSON of the payload.
    payload: []const u8,
    /// The time of the run that the job waits for or runs; the same for
    /// every attempt of that run.
    scheduled_at: Instant,
    /// Pending: when it may be claimed. Paused: when it may be claimed
    /// after `unpause`. Running, succeeded and failed: null.
    run_at: ?Instant,
    attempt: u32,
    /// The claims of this life: one more with each claim.
    fence: u64,
    /// One more with each change of the client.
    revision: u64,
    /// Running and asked to pause: it pauses when the run ends.
    pause_requested: bool,
    /// Running: the instance that holds the claim.
    owner: ?[]const u8,
    /// Running: when the store gave it to its owner, and until when the
    /// lease lasts, by the store's clock.
    claimed_at: ?Instant,
    lease_until: ?Instant,
    last: ?LastRun,
    created_at: Instant,
    /// When `create` made the record or `update` last changed it; claims,
    /// renewals and finishes leave it as it is.
    updated_at: Instant,
    /// Succeeded and failed: when it finished, and when the store may drop
    /// it (null: kept always).
    finished_at: ?Instant,
    expires_at: ?Instant,
    /// The traceparent of the caller of `schedule`.
    trace: ?[]const u8,
    life: Life,
    /// Since when, by the store's clock, no instance that claimed the job
    /// could read it; null while it reads.
    unreadable_since: ?Instant,

    /// The payload as `J.Payload`, with its strings in `arena`. A field
    /// that `J.Payload` does not know is skipped, and a missing one takes
    /// its default; a job without `Payload` reads it as `void`.
    pub fn payloadAs(r: Record, comptime J: type, arena: Allocator) payload_json.DecodeError!job_type.PayloadOf(J) {
        return payload_json.decode(J, arena, r.payload);
    }
};

/// What a record shows of its last run.
pub const LastRun = struct {
    outcome: RunOutcome,
    /// The name of the error or the reason: "PaymentDeclined", "Timeout",
    /// "LeaseLost", "Cancelled", "UnreadablePayload".
    error_name: ?[]const u8,
    attempt: u32,
    started_at: Instant,
    finished_at: Instant,
};

/// A row of the history: one claim, the only row of its (life, fence).
pub const Run = struct {
    job: []const u8,
    key: []const u8,
    tenant: ?[]const u8,
    life: Life,
    fence: u64,
    attempt: u32,
    scheduled_at: Instant,
    started_at: Instant,
    finished_at: Instant,
    outcome: RunOutcome,
    error_name: ?[]const u8,
    instance: []const u8,
    expires_at: ?Instant,
};

/// The rule of the name of a job: 1–64 bytes of a–z, 0–9, '-', '_' and
/// '.', starting with a letter or a digit.
pub fn validJobName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (!std.ascii.isLower(name[0]) and !std.ascii.isDigit(name[0])) return false;
    for (name) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-' and c != '_' and c != '.') return false;
    }
    return true;
}

/// The rule of a key: 1–256 bytes of UTF-8 without NUL.
pub fn validKey(key: []const u8) bool {
    return validText(key, 256);
}

/// The rule of a tenant: 1–128 bytes of UTF-8 without NUL.
pub fn validTenant(tenant: []const u8) bool {
    return validText(tenant, 128);
}

fn validText(text: []const u8, most: usize) bool {
    if (text.len == 0 or text.len > most) return false;
    if (std.mem.findScalar(u8, text, 0) != null) return false;
    return std.unicode.utf8ValidateSlice(text);
}
