//! The options of the collection API's operations, which `Collection`
//! names: `mongo.Collection.InsertManyOptions`. Each one has the fields of
//! all: `allocator`, `comment`, `diagnostics` and `failure_reply`. An
//! option at its default is not sent.
//!
//! There is no `maxTimeMS`: the deadline comes from the context only, and
//! the driver writes it. There is no `writeConcern` or `readConcern`
//! either: a standalone server writes with `w: 1`; who needs them puts
//! them in the body of `mongo.Client.write` or `runCommand`.

const std = @import("std");
const bson = @import("../bson.zig");
const errors = @import("../contract/errors.zig");
const Diagnostics = errors.Diagnostics;

pub const InsertOneOptions = struct {
    /// The memory of the result, and of the call's scratch, which is
    /// freed before the call returns.
    allocator: std.mem.Allocator,
    /// Let the document past the collection's validator.
    bypass_document_validation: bool = false,
    /// Sent with the command, for the server's logs and profiler.
    comment: ?bson.Value = null,
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, the whole reply of
    /// the server, from `allocator`; the slot must hold null.
    failure_reply: ?*?bson.OwnedDocument = null,
};

pub const InsertManyOptions = struct {
    /// The memory of the result, and of the call's scratch, which is
    /// freed before the call returns.
    allocator: std.mem.Allocator,
    /// Whether the server stops at the first document it refuses, and no
    /// batch follows; false inserts all it can.
    ordered: bool = true,
    /// Let the documents past the collection's validator.
    bypass_document_validation: bool = false,
    /// Sent with each batch, for the server's logs and profiler.
    comment: ?bson.Value = null,
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, the whole reply of
    /// the server, from `allocator`; the slot must hold null.
    failure_reply: ?*?bson.OwnedDocument = null,
};
