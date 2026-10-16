const rpc = @import("rpc");

const Shape = union(enum) { circle: f64, square: f64 };
const DrawRequest = struct { shape: Shape };

const CanvasApi = rpc.Contract(.{
    .name = "canvas",
    .version = 2,
    .methods = .{ .draw = rpc.method(DrawRequest, void) },
});

test {
    _ = CanvasApi;
}
