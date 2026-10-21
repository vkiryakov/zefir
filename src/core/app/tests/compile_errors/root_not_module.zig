//! Must not compile: the root is a type that declares no module.
const core = @import("core");

const Config = struct { port: u16 = 8080 };

test {
    _ = core.App(Config);
}
