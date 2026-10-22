//! A golden application of zefir-openapi: every type of design §11 in a
//! request and in a response, as the codec reads and writes them. A type
//! read and written whose schemas differ (`Customer`, with `Address` in
//! it), a generic type (`Page(OrderView)`), a generic of an anonymous type,
//! which stands inline, a schema of another name (`.name`), a type that
//! writes itself (`.as`), any JSON (`std.json.Value`), and an error
//! handler of the application's own body.
//! Its document is src/openapi/tests/golden/shapes-3.1.json and -3.2.json.
//!
//! Application code: zefir ships no DTO, controller or error handler.
const std = @import("std");
const zefir = @import("zefir");
const http = zefir.http;
const v = zefir.validator;

pub const Request = @import("request.zig").Request;

pub const Size = enum { small, medium, large };

/// Values without a name are written as their number.
pub const Access = enum(u8) { read, write, _ };

pub const Address = struct {
    city: []const u8,
    zip: ?[]const u8 = null,

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .description = "Where an order goes.",
        .fields = .{ .zip = .{ .description = "The postal code, where the country has them." } },
    };
};

/// Read in an order, and written in the order the API shows: two schemas.
pub const Customer = struct {
    name: []const u8,
    address: Address,

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .example = .{ .name = "Ada", .address = .{ .city = "London" } },
    };
};

pub const Line = struct {
    sku: []const u8,
    count: u32 = 1,
};

/// An order as a client sends it: what a body can read.
pub const OrderRequest = struct {
    customer: Customer,
    quantity: u16,
    weight_kg: f32 = 1.5,
    priority: i8 = 0,
    express: bool = false,
    size: Size = .medium,
    note: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    lines: []const Line,
    total_cents: u64,
    offset: i64 = 0,
    ratio: f64 = 0.5,

    pub const field_rules = .{
        .weight_kg = v.rename("weightKg"),
        .total_cents = v.rename("totalCents"),
    };

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .description = "An order of a customer.",
        .examples = &.{.{
            .name = "one line",
            .summary = "A line of two",
            .value = .{
                .customer = .{ .name = "Ada", .address = .{ .city = "London", .zip = "N1 9GU" } },
                .quantity = 2,
                .lines = &.{.{ .sku = "A-1", .count = 2 }},
                .total_cents = 1250,
            },
        }},
    };
};

pub const Circle = struct {
    radius_mm: u32,

    pub const field_rules = .{ .radius_mm = v.rename("radiusMm") };
};

/// An object of one key: its variant.
pub const Shape = union(enum) {
    circle: Circle,
    square: u32,
    none,

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .description = "The shape of the parcel.",
        .fields = .{ .square = .{ .description = "The side, in millimetres." } },
    };
};

/// An amount, which writes itself as a string: "12.50".
pub const Money = struct {
    cents: u64,

    pub fn jsonStringify(self: Money, w: anytype) !void {
        try w.print("\"{d}.{d:0>2}\"", .{ self.cents / 100, self.cents % 100 });
    }

    pub const openapi: zefir.openapi.Doc(@This()) = .{ .description = "An amount, as a decimal string.", .as = []const u8 };
};

/// An order as the API shows it: what a response can write.
pub const OrderView = struct {
    id: u64,
    customer: Customer,
    size: Size,
    access: Access,
    code: [3]u8,
    scores: [3]u16,
    pair: struct { u8, []const u8 },
    shape: Shape,
    other_shape: ?Shape,
    total: Money,
    meta: std.json.Value,
    big: i128,
    small: f32,
    maybe_size: ?Size,
    comptime version: u32 = 2,
    nothing: void = {},

    pub const field_rules = .{ .other_shape = v.rename("otherShape"), .maybe_size = v.rename("maybeSize") };

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .description = "An order, as the API shows it.",
        .fields = .{ .version = .{ .description = "The version of this form." } },
    };
};

pub fn Page(comptime T: type) type {
    return struct {
        items: []const T,
        total: u64,

        pub const openapi: zefir.openapi.Doc(@This()) = .{ .description = "A page of results." };
    };
}

/// Its schema is named Parcel.
pub const Shipment = struct {
    id: u64,
    carrier: []const u8,

    pub const openapi: zefir.openapi.Doc(@This()) = .{ .name = "Parcel" };
};

pub const OrderIdPath = struct {
    id: u64,

    pub const openapi: zefir.openapi.Doc(@This()) = .{ .fields = .{ .id = .{ .description = "The id of the order." } } };
};

/// The body of every error.
pub const ApiError = struct {
    code: []const u8,
    message: []const u8,
    details: []const []const u8 = &.{},

    pub const openapi: zefir.openapi.Doc(@This()) = .{ .description = "What went wrong." };
};

fn view(id: u64) OrderView {
    return .{
        .id = id,
        .customer = .{ .name = "Ada", .address = .{ .city = "London" } },
        .size = .medium,
        .access = @fromBackingInt(7),
        .code = "A12".*,
        .scores = .{ 1, 2, 3 },
        .pair = .{ 7, "seven" },
        .shape = .{ .circle = .{ .radius_mm = 30 } },
        .other_shape = null,
        .total = .{ .cents = 1250 },
        .meta = .null,
        .big = -170141183460469231731687303715884105728,
        .small = 0.25,
        .maybe_size = null,
    };
}

/// The orders the list shows: built at compile time, they live as long as
/// the program.
const all_orders = [_]OrderView{view(1)};

pub const OrdersController = struct {
    const Create = http.post("", .{ .body = OrderRequest, .responses = .{ .created = .{} } });
    const Get = http.get("/{id}", .{ .path = OrderIdPath });
    const Shipments = http.get("/{id}/shipments", .{ .path = OrderIdPath });

    pub const http_routes = http.routes(.{
        .prefix = "/v1/orders",
        .methods = .{ .create = Create, .get = Get, .list = http.get("", .{}), .shipments = Shipments, .counts = http.get("/counts", .{}) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{
        .tag = "Orders",
        .routes = .{
            .create = .{ .summary = "Place an order" },
            .get = .{ .summary = "Get an order" },
            .list = .{ .summary = "List orders" },
            .shipments = .{ .summary = "List the parcels of an order" },
            .counts = .{ .summary = "Count the orders of each size" },
        },
    };

    pub fn create(_: *OrdersController, ctx: *http.Context) !http.Json(OrderView) {
        const in = try ctx.input(Create);
        var order = view(2);
        order.customer = in.body.customer;
        order.size = in.body.size;
        return .{ .value = order, .status = 201 };
    }

    pub fn get(_: *OrdersController, ctx: *http.Context) !http.Json(OrderView) {
        const in = try ctx.input(Get);
        if (in.path.id != 1) return error.OrderNotFound;
        return .{ .value = view(1) };
    }

    pub fn list(_: *OrdersController, _: *http.Context) !http.Json(Page(OrderView)) {
        return .{ .value = .{ .items = &all_orders, .total = all_orders.len } };
    }

    pub fn shipments(_: *OrdersController, ctx: *http.Context) !http.Json([]const Shipment) {
        const in = try ctx.input(Shipments);
        if (in.path.id != 1) return error.OrderNotFound;
        return .{ .value = &.{.{ .id = 1, .carrier = "Post" }} };
    }

    /// A page of rows of an anonymous type.
    pub fn counts(_: *OrdersController, _: *http.Context) !http.Json(Page(struct { size: Size, orders: u32 })) {
        return .{ .value = .{ .items = &.{.{ .size = .medium, .orders = 1 }}, .total = 1 } };
    }
};

pub const AppErrors = struct {
    pub fn mapError(err: anyerror) http.ErrorResponse(ApiError) {
        return switch (err) {
            error.OrderNotFound => .{ .status = 404, .body = .{ .code = "orders.not_found", .message = "No such order." } },
            else => .fallback(err, .{ .code = http.defaultCode(err), .message = http.defaultTitle(err) }),
        };
    }
};

/// Builds the server and its documents, for the tests.
pub const Service = struct {
    orders: OrdersController = .{},
    app_errors: AppErrors = .{},
    docs_3_1: zefir.openapi.Document = undefined,
    docs_3_2: zefir.openapi.Document = undefined,
    server: http.Server = undefined,

    pub fn start(s: *Service, gpa: std.mem.Allocator, io: std.Io, backend: http.Backend) !void {
        const options = .{
            .backend = backend,
            .prefix = "/api",
            .controllers = .{&s.orders},
            .error_handler = &s.app_errors,
        };
        const info: zefir.openapi.DocumentOptions.Info = .{ .title = "Orders API", .version = "2.0.0", .description = "The orders of a shop." };
        s.docs_3_1 = comptime zefir.openapi.document(@TypeOf(options), .{ .info = info });
        s.docs_3_2 = comptime zefir.openapi.document(@TypeOf(options), .{ .info = info, .version = .@"3.2" });
        s.server = try .init(gpa, options);
        errdefer s.server.deinit(io);
        try s.server.start(io);
    }

    pub fn deinit(s: *Service, io: std.Io) void {
        s.server.deinit(io);
    }
};

const json: [2][]const u8 = .{ "content-type", "application/json" };

pub const requests = [_]Request{
    .{ .method = .POST, .target = "/api/v1/orders", .headers = &.{json}, .status = 201, .body =
    \\{"customer":{"name":"Ada","address":{"city":"London","zip":null}},"quantity":2,"weightKg":0.5,"priority":-3,"express":true,
    \\"size":"large","note":"Leave it at the door","tags":["gift"],"lines":[{"sku":"A-1","count":2},{"sku":"B-2"}],
    \\"totalCents":1250,"offset":-9007199254740991,"ratio":0.125}
    },
    .{ .method = .POST, .target = "/api/v1/orders", .headers = &.{json}, .body = "{\"customer\":{\"name\":\"Ada\",\"address\":{\"city\":\"London\"}},\"quantity\":1,\"lines\":[],\"totalCents\":0}", .status = 201 },
    .{ .method = .POST, .target = "/api/v1/orders", .headers = &.{json}, .body = "{\"customer\":{\"name\":\"Ada\"},\"quantity\":70000,\"lines\":[],\"totalCents\":1}", .status = 422 },
    .{ .method = .POST, .target = "/api/v1/orders", .headers = &.{json}, .body = "{\"customer\":{\"name\":\"Ada\",\"address\":{\"city\":\"London\"}},\"quantity\":1,\"lines\":[],\"totalCents\":1,\"color\":\"red\"}", .status = 422 },
    .{ .method = .POST, .target = "/api/v1/orders", .headers = &.{json}, .body = "[1,2", .status = 400 },
    .{ .method = .GET, .target = "/api/v1/orders/1", .status = 200 },
    .{ .method = .GET, .target = "/api/v1/orders/9", .status = 404 },
    .{ .method = .GET, .target = "/api/v1/orders/x", .status = 422 },
    .{ .method = .GET, .target = "/api/v1/orders", .status = 200 },
    .{ .method = .GET, .target = "/api/v1/orders/1/shipments", .status = 200 },
    .{ .method = .GET, .target = "/api/v1/orders/9/shipments", .status = 404 },
    .{ .method = .GET, .target = "/api/v1/orders/counts", .status = 200 },
};
