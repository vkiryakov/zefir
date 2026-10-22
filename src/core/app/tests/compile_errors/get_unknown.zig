//! Must not compile: get of a type that is no bean of the App.
const core = @import("core");
const common = @import("common.zig");

const Foo = struct { id: u32 };

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{common.Uses}, .values = &.{ *common.Recorder, *const common.Config, *const common.Logger } };
};

test {
    var app: core.App(Root) = undefined;
    _ = app.get(Foo);
}
