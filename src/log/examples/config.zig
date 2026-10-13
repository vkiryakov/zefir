//! zefir-log with structured values: a nested configuration with a key
//! marked sensitive, a type with its own text, bytes as hex, the call site,
//! a request's trace ids and std.log routed through the logger.
//! `zig build test` runs it; it fails if the logger loses a record.

const std = @import("std");
const core = @import("core");
const log = @import("log");

/// std.log goes through the logger once `installStdLog` is called.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

/// A key from a vault: marked, so the logger never writes it.
const ApiKey = struct {
    value: []const u8,
    pub const zefir_sensitive = true;
};

// Check the marker, as core advises for every marked type: a missing or
// private one fails the build here instead of leaking the key.
comptime {
    std.debug.assert(log.isSensitive(ApiKey));
}

/// An amount that logs as "19.99 EUR".
const Money = struct {
    cents: i64,
    pub fn format(m: Money, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d:0>2} EUR", .{ @divTrunc(m.cents, 100), @abs(@rem(m.cents, 100)) });
    }
};

const Config = struct {
    port: u16,
    database: struct {
        host: []const u8,
        password: []const u8, // redacted by its name
        pool: struct { min: u8, max: u8 },
    },
    vault_key: ApiKey, // redacted by its type: the name is not a secret name
    regions: []const []const u8,
};

pub fn main(init: std.process.Init) !void {
    const logger: log.Logger = try .init(init.gpa, init.io, .{
        .service = .{ .name = "billing", .version = "2.1.0" },
    });
    defer logger.deinit();
    logger.installStdLog();

    const config: Config = .{
        .port = 9000,
        .database = .{ .host = "postgres.internal", .password = "change-me", .pool = .{ .min = 2, .max = 16 } },
        .vault_key = .{ .value = "sk-live-123" },
        .regions = &.{ "eu-west", "us-east" },
    };
    logger.info("Configuration loaded", .{ .src = @src(), .config = config });

    // In a request handler: the trace ids come from the request's context.
    const trace: core.TraceContext = .{
        .trace_id = try .parseHex("4bf92f3577b34da6a3ce929d0e0e4736"),
        .span_id = try .parseHex("00f067aa0ba902b7"),
        .flags = .{ .sampled = true },
        .state = .empty,
    };
    const ctx = core.Context.root.withTrace(trace);
    const digest = [_]u8{ 0x9f, 0x86, 0xd0, 0x81 };
    logger.scoped("billing.invoices").withContext(ctx).info("Invoice paid", .{
        .invoice_id = 1001,
        .amount = Money{ .cents = 1999 },
        .receipt_digest = log.hex(&digest),
    });

    // Libraries that log through std.log end up in the same stream.
    std.log.scoped(.cache).info("warmed up {d} entries", .{128});

    const counts = logger.stats();
    if (counts.written != 3 or counts.dropped.write_failed != 0) return error.LostRecords;
}
