//! Must not compile: a copy of a bean App drives. The copy would be a
//! second client: App starts, stops and frees the first one only.
const std = @import("std");
const core = @import("core");

const Client = struct {
    connected: bool = false,

    pub fn start(c: *Client, _: std.Io) !void {
        c.connected = true;
    }
    pub fn shutdown(c: *Client, _: std.Io, _: std.Io.Clock.Timestamp) !void {
        c.connected = false;
    }
    pub fn deinit(_: *Client) void {}
};

const InfraModule = struct {
    pub const module: core.app.Module = .{ .factories = &.{Clients}, .exports = &.{Client} };

    pub const Clients = struct {
        pub fn client() Client {
            return .{};
        }
    };
};

const Stats = struct { client: Client };

const Reports = struct {
    pub const module: core.app.Module = .{ .imports = &.{InfraModule}, .providers = &.{Stats} };
};
const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{ InfraModule, Reports } };
};

test {
    _ = core.App(Root);
}
