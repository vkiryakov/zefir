const v = @import("validator");

const Handle = opaque {
    pub fn validateSelf(_: *const Handle) ?v.Violation {
        return null;
    }
};

test {
    var path_buf: [64]u8 = undefined;
    const handle: *const Handle = @ptrFromInt(0x1000);
    _ = v.check(handle, &path_buf);
}
