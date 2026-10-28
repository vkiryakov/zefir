//! zefir-log with structured values: std.log routed through the logger, a
//! nested configuration, keys of a type marked sensitive, a type with its
//! own text, bytes as hex, the call site and a request's trace ids.

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

// A missing or private marker would leak the key: check it at compile time.
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

    // Libraries that log through std.log end up in the same stream.
    logger.installStdLog(); // std.log goes to the logger from here on
    std.log.scoped(.cache).info("warmed up {d} entries", .{128});

    const config: Config = .{
        .port = 9000,
        .database = .{ .host = "postgres.internal", .password = "change-me", .pool = .{ .min = 2, .max = 16 } },
        .vault_key = .{ .value = "sk-live-123" },
        .regions = &.{ "eu-west", "us-east" },
    };
    logger.info("Configuration loaded", .{ .config = config });

    const key: ApiKey = .{ .value = "sk-live-123" };
    const backup: ?ApiKey = null;
    logger.info("Vault keys loaded", .{ .vault = "payments", .key = key, .backup = backup, .all = &[_]ApiKey{ key, key } });

    // In a request handler, the trace ids come from the request's context;
    // here, from a trace built by hand.
    const trace: core.TraceContext = .{
        .trace_id = try .parseHex("4bf92f3577b34da6a3ce929d0e0e4736"),
        .span_id = try .parseHex("00f067aa0ba902b7"),
        .flags = .{ .sampled = true },
        .state = .empty,
    };
    const ctx = core.Context.root.withTrace(trace);
    const digest = [_]u8{ 0x9f, 0x86, 0xd0, 0x81 };
    const invoices = logger.scoped("billing.invoices").withContext(ctx);
    invoices.info("Invoice paid", .{ .src = @src(), .invoice_id = 1001, .amount = Money{ .cents = 1999 }, .receipt_digest = log.hex(&digest) });
}
