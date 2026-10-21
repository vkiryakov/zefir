//! Must not compile: a type that writes itself, whose Doc does not say
//! what its JSON looks like.
const zefir = @import("zefir");

const Money = struct {
    cents: u64,

    pub fn jsonStringify(self: Money, w: anytype) !void {
        try w.print("\"{d}\"", .{self.cents});
    }

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .description = "An amount of money.",
    };
};

test {
    _ = Money.openapi;
}
