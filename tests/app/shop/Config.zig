//! The settings of the shop, from the environment through confy, with the
//! prefix SHOP_: SHOP_PORT, SHOP_MONGO_URI, SHOP_MONGO_PASSWORD and
//! SHOP_NATS_URL.

const zefir = @import("zefir");

/// The port of the HTTP server, on every IPv4 interface.
port: u16 = 8080,
mongo: struct {
    uri: []const u8 = "mongodb://127.0.0.1:27017",
    /// The password of the user that the URI names, if it names one: kept
    /// out of the URI, and out of every log.
    password: ?zefir.confy.Secret = null,
} = .{},
nats: struct {
    url: []const u8 = "nats://127.0.0.1:4222",
} = .{},
