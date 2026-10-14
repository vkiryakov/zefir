//! The data of a call that applications, the engine and transports share:
//! where it goes, its metadata and the response.

const std = @import("std");
const core = @import("core");

/// The address of a method: a service, its major version and a method.
/// Service and method names are 1 to 64 characters from `[A-Za-z0-9_-]`,
/// and the version is above 0; the engine refuses other routes.
pub const Route = struct {
    service: []const u8,
    version: u16,
    method: []const u8,
};

/// The metadata of a request or a response: ordered key-value pairs, like
/// headers.
pub const Metadata = struct {
    /// A key is 1 to 64 characters from `[a-z0-9_-]`. A value is printable
    /// ASCII (0x20–0x7E) without a space at either end, and may be empty.
    /// Transports keep the order and the repeated keys as they are; the
    /// engine checks them, not the transport.
    pub const Entry = struct { key: []const u8, value: []const u8 };

    /// Metadata to read, such as that of a request in `rpc.Context`: the
    /// entries in order, repeated keys included.
    pub const View = struct {
        entries: []const Entry,

        /// The first value of `key`; null when there is none.
        pub fn get(view: View, key: []const u8) ?[]const u8 {
            for (view.entries) |entry| {
                if (std.mem.eql(u8, entry.key, key)) return entry.value;
            }
            return null;
        }

        /// The values of `key`, in order.
        pub fn getAll(view: View, key: []const u8) ValueIterator {
            return .{ .entries = view.entries, .key = key };
        }

        /// All entries, in order.
        pub fn iterator(view: View) Iterator {
            return .{ .entries = view.entries };
        }

        pub const ValueIterator = struct {
            entries: []const Entry,
            key: []const u8,
            index: usize = 0,

            pub fn next(it: *ValueIterator) ?[]const u8 {
                while (it.index < it.entries.len) {
                    const entry = it.entries[it.index];
                    it.index += 1;
                    if (std.mem.eql(u8, entry.key, it.key)) return entry.value;
                }
                return null;
            }
        };

        pub const Iterator = struct {
            entries: []const Entry,
            index: usize = 0,

            pub fn next(it: *Iterator) ?Entry {
                if (it.index == it.entries.len) return null;
                defer it.index += 1;
                return it.entries[it.index];
            }
        };
    };
};

/// The server's answer: success with a body, or a failure. The status
/// travels in the transport's envelope, not in the JSON body.
pub const Response = struct {
    status: Status,
    metadata: []const Metadata.Entry = &.{},
    /// Success: the encoded response. Failure: details in the framework's
    /// format (the JSON list of validation violations) or nothing.
    /// Transports carry the bytes as they are.
    body: []const u8 = "",
    /// The server guarantees that the call did not run: it refused the call
    /// at admission, like `REFUSED_STREAM` in gRPC. Retrying is safe.
    refused: bool = false,
};

/// Success or failure. Closed for good: a new variant would break every
/// `switch` over it, in transports and in applications.
pub const Status = union(enum) {
    ok,
    failure: Failure,
};

/// A failure: a class and a message, as in `core.ErrorInfo`, plus a code for
/// programs and the validation violations.
pub const Failure = struct {
    code: core.ErrorCode,
    /// A stable code for programs, such as "users.not_found". Codes that
    /// start with "rpc." belong to the framework.
    app_code: []const u8,
    /// For people; never the server's internals.
    message: []const u8,
    /// The path of the first validation violation, such as "items[2].name",
    /// for clients that show one field.
    field: ?[]const u8 = null,
    /// All validation violations; empty for other failures. On the wire they
    /// are the body of the failure: `rpc.Server` encodes them and
    /// `rpc.Client` decodes them, so in the engine and in transports this is
    /// always empty.
    violations: []const Violation = &.{},
    /// There were more than 100 violations; the rest were dropped.
    violations_truncated: bool = false,
};

/// One validation violation, as zefir-validator reports it: field "name",
/// code "validation.not_empty", message "must not be empty".
pub const Violation = struct {
    /// The path of the value, such as "items[2].name"; null when the
    /// violation is about the whole request.
    field: ?[]const u8,
    code: []const u8,
    message: []const u8,
};

test "a metadata view reads the first value, all values of a key and every entry in order" {
    const view: Metadata.View = .{ .entries = &.{
        .{ .key = "x-a", .value = "1" },
        .{ .key = "x-b", .value = "" },
        .{ .key = "x-a", .value = "2" },
    } };
    try std.testing.expectEqualStrings("1", view.get("x-a").?);
    try std.testing.expectEqualStrings("", view.get("x-b").?);
    try std.testing.expectEqual(@as(?[]const u8, null), view.get("x-c"));

    var values = view.getAll("x-a");
    try std.testing.expectEqualStrings("1", values.next().?);
    try std.testing.expectEqualStrings("2", values.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), values.next());
    var none = view.getAll("x-c");
    try std.testing.expectEqual(@as(?[]const u8, null), none.next());

    var it = view.iterator();
    try std.testing.expectEqualStrings("x-a", it.next().?.key);
    try std.testing.expectEqualStrings("x-b", it.next().?.key);
    try std.testing.expectEqualStrings("2", it.next().?.value);
    try std.testing.expectEqual(@as(?Metadata.Entry, null), it.next());
}

test "a response defaults to no metadata, no body and not refused" {
    const response: Response = .{ .status = .ok };
    try std.testing.expectEqual(@as(usize, 0), response.metadata.len);
    try std.testing.expectEqualStrings("", response.body);
    try std.testing.expect(!response.refused);
}

test "a failure defaults to no field and no violations" {
    const failure: Failure = .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" };
    try std.testing.expectEqual(@as(?[]const u8, null), failure.field);
    try std.testing.expectEqual(@as(usize, 0), failure.violations.len);
    try std.testing.expect(!failure.violations_truncated);
}

test "status is closed: exactly ok and failure" {
    const Tag = @typeInfo(Status).@"union".tag_type.?;
    const info = @typeInfo(Tag).@"enum";
    try std.testing.expectEqual(std.lang.Type.Enum.Mode.exhaustive, info.mode);
    try std.testing.expectEqual(@as(usize, 2), info.field_names.len);
    try std.testing.expectEqualStrings("ok", info.field_names[0]);
    try std.testing.expectEqualStrings("failure", info.field_names[1]);
}
