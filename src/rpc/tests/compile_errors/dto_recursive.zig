const rpc = @import("rpc");

const GetTreeRequest = struct { root: u64 };
const Node = struct { name: []const u8, children: []const Node };

const TreeApi = rpc.Contract(.{
    .name = "tree",
    .version = 1,
    .methods = .{ .get = rpc.method(GetTreeRequest, Node) },
});

test {
    _ = TreeApi;
}
