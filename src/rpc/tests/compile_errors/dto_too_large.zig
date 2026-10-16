const rpc = @import("rpc");

const GetImageRequest = struct { id: u64 };
const Image = struct { id: u64, pixels: [256 * 256]u32 };

const ImageApi = rpc.Contract(.{
    .name = "images",
    .version = 1,
    .methods = .{ .getImage = rpc.method(GetImageRequest, Image) },
});

test {
    _ = ImageApi;
}
