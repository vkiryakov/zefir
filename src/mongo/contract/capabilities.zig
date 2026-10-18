//! What a driver declares it can do, and the revision of the contract it
//! is written for.

/// The revision of the contract that this zefir-mongo defines. It grows
/// with each new rule or addition; every addition comes with a default,
/// so a driver of an earlier revision still builds and works.
pub const contract_revision: u16 = 1;

/// What `mongo.Client.capabilities` returns.
pub const Capabilities = struct {
    /// The revision the driver is written for, as a number and never as
    /// `mongo.contract_revision`: rebuilt against a later zefir, the
    /// driver would claim rules it does not know.
    revision: u16,
    /// For logs and the conformance report: "zefir-mongo", "fake".
    name: []const u8,

    // Required in revision 1: a driver declares all four.
    commands: bool = false,
    cursors: bool = false,
    aggregation: bool = false,
    batched_writes: bool = false,

    // Reserved for later revisions: a driver of revision 1 leaves them
    // false.
    sessions: bool = false,
    transactions: bool = false,
    change_streams: bool = false,
    retryable_reads: bool = false,
    retryable_writes: bool = false,
    /// Choosing a member of a replica set for reads.
    read_preference: bool = false,
    tailable_cursors: bool = false,
    /// The `bulkWrite` command of MongoDB 8.0.
    bulk_write_command: bool = false,
    compression: bool = false,

    /// From the hello of the latest connection; null before `connect`. It
    /// may change.
    server: ?ServerInfo = null,
};

/// What the server said about itself in hello.
pub const ServerInfo = struct {
    kind: ServerKind,
    max_wire_version: i32,
    max_bson_object_size: u32,
    max_message_size_bytes: u32,
    max_write_batch_size: u32,
};

/// The kind of server. Revision 1 knows only a standalone mongod; later
/// revisions add kinds, so a `switch` over it needs `else`.
pub const ServerKind = enum(u8) { standalone, _ };
