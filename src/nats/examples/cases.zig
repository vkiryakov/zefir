//! The examples of README.md, the guide of zefir-nats. Every program needs
//! a NATS server and zio, so tests/nats builds and runs them, and checks
//! that README.md shows their runs as they printed; readme_test.zig checks,
//! without a server, that README.md shows every file as it is and no Zig
//! code that is not a part of them.

/// The programs README.md shows whole, in its order.
pub const programs = [_][]const u8{ "pub_sub", "queue_group", "request_reply", "scatter_gather", "user_password_auth", "zio_app" };

/// The programs whose runs README.md shows as they printed: tests/nats runs
/// them against its servers and checks the guide. The others print what
/// changes from run to run, so README.md shows a run of each as a sample.
pub const server_programs = [_][]const u8{ "pub_sub", "request_reply", "scatter_gather", "user_password_auth" };

/// The other files whose lines README.md shows: the snippets, which the
/// build compiles and runs none of.
pub const files = [_][]const u8{"fragments"};

/// The programs that README.md at the root of the repository shows too,
/// as they are and with a run: its "nats in a minute".
pub const root_readme = [_][]const u8{"minute"};
