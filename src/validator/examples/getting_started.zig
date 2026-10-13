const std = @import("std");
const log = @import("log");
const v = @import("validator");

const Currency = enum { eur, usd, gbp };

const Item = struct {
    sku: []const u8,
    quantity: u16,
    unit_price: f64,

    pub const field_rules = .{
        .sku = .{ v.length(6, 12), v.alphanumeric },
        .quantity = v.range(1, 99),
        .unit_price = v.positive,
    };
};

const Order = struct {
    id: []const u8,
    customer_id: u64,
    currency: Currency,
    items: []const Item, // every item is checked by the rules of Item
    express: bool = false,
    note: ?[]const u8 = null,

    pub const field_rules = .{
        .id = v.uuid, // one rule
        .customer_id = v.positive,
        .currency = v.oneOf(.{ .eur, .usd }),
        .items = .{ v.notEmpty, v.maxItems(50) }, // a tuple: its rules run in order
        .note = v.maxLength(500), // null skips the rule
    };
};

pub fn main(init: std.process.Init) !void {
    const logger: log.Logger = try .init(init.gpa, init.io, .{
        .service = .{ .name = "order-service" },
        .format = .text,
    });
    defer logger.deinit();

    const request: Order = .{
        .id = "3f9c1a2e-8b4d-4c6a-9e1f-5a7b2c8d0e41",
        .customer_id = 1042,
        .currency = .eur,
        .items = &.{
            .{ .sku = "BOOK0042", .quantity = 2, .unit_price = 12.5 },
            .{ .sku = "PEN0007", .quantity = 0, .unit_price = 1.9 },
        },
    };

    var path_buf: [256]u8 = undefined;
    if (v.check(&request, &path_buf)) |violation| {
        logger.warn("Invalid order", .{ .field = violation.field, .code = violation.code, .reason = violation.message });
    } else {
        logger.info("Order accepted", .{});
    }
}
