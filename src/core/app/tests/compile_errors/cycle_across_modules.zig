//! Must not compile: two services of two modules that take each other,
//! which needs the modules to import each other.
const core = @import("core");

const UserService = struct { orders: *OrderService };
const OrderService = struct { users: *UserService };

const UsersM = struct {
    pub const module: core.app.Module = .{ .imports = &.{OrdersM}, .providers = &.{UserService}, .exports = &.{UserService} };
};
const OrdersM = struct {
    pub const module: core.app.Module = .{ .imports = &.{UsersM}, .providers = &.{OrderService}, .exports = &.{OrderService} };
};
const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{UsersM} };
};

test {
    _ = core.App(Root);
}
