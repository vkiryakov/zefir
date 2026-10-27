const std = @import("std");
const confy = @import("confy");
const log = @import("log");

const Config = struct {
    log_level: log.Level = .info,
    slack: struct {
        webhook_url: confy.Secret,
    },
};

/// Posts error records to a Slack channel through an incoming webhook.
const SlackAlerts = struct {
    gpa: std.mem.Allocator,
    http: std.http.Client,
    webhook_url: confy.Secret,

    /// The handler. The logger calls it on the subscriber's own thread, once
    /// per record, so a slow post holds up no request.
    fn send(context: ?*anyopaque, event: *const log.Event) anyerror!void {
        const slack: *SlackAlerts = @ptrCast(@alignCast(context.?));
        // event.line is the record as stdout gets it, secrets already redacted.
        const text = try std.fmt.allocPrint(slack.gpa, ":rotating_light: *{s}* in `{s}`\n```{s}```", .{ event.message, event.scope, event.line });
        defer slack.gpa.free(text);
        const body = try std.json.Stringify.valueAlloc(slack.gpa, .{ .text = text }, .{});
        defer slack.gpa.free(body);
        const response = try slack.http.fetch(.{
            .location = .{ .url = slack.webhook_url.expose() },
            .payload = body, // a payload makes it a POST
            .headers = .{ .content_type = .{ .override = "application/json" } },
        });
        if (response.status != .ok) return error.SlackRejected;
    }
};

pub fn main(init: std.process.Init) !void {
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{ .env(".env"), .osEnv() },
    });

    const logger: log.Logger = try .init(init.gpa, init.io, .{
        .service = .{ .name = "orders", .version = "3.0.0" },
        .level = config.log_level,
        .mode = .{ .queued = .{} },
    });
    defer logger.deinit();

    var slack: SlackAlerts = .{
        .gpa = init.gpa,
        .http = .{ .allocator = init.gpa, .io = init.io },
        .webhook_url = config.slack.webhook_url,
    };
    defer slack.http.deinit();

    const alerts = try logger.subscribe(.{
        .levels = &.{.err}, // error records only
        .scope = "payments", // from payments and its subscopes only
        .context = &slack,
        .handler = SlackAlerts.send,
    });
    defer logger.unsubscribe(alerts); // runs first: before the client and the logger go

    const payments = logger.scoped("payments");
    payments.info("Charge started", .{ .order_id = 7, .amount_cents = 4200 });
    payments.err("Charge declined", .{ .order_id = 7, .reason = "card_expired" });
    logger.scoped("http").err("Upstream timeout", .{ .path = "/v1/orders" }); // another scope: not sent
}
