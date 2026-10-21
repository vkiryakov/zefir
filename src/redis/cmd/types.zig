//! The types of the results and the arguments of the catalog, which the
//! module exports as `redis.*`.

/// A field of a hash and its value: a hash of any fields, in place of a
/// struct, for `cmd.hset`, `cmd.hgetall` and the fields of `cmd.xadd`.
/// Read, the pairs keep the order of the server.
pub const FieldValue = struct {
    field: []const u8,
    value: []const u8,
};
