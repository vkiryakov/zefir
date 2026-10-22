//! The end-to-end tests of zefir.App: real servers of zefir-http and
//! zefir-rpc, beans of one App, on zio with one executor and with four;
//! then programs with such an App, in processes of their own, stopped by
//! SIGTERM.

test {
    _ = @import("servers.zig");
    _ = @import("stop.zig");
    _ = @import("failfast.zig");
    _ = @import("budget.zig");
    _ = @import("processes.zig");
}
