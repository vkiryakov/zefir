//! The examples of README.md, the guide of zefir-openapi. build.zig runs the
//! test of its small application, service_test.zig, which compares the
//! document with openapi.json, and readme_test.zig, which checks README.md
//! against what it shows. The small application's main.zig imports zio:
//! tests/http builds it.

/// The files of the small application, which README.md shows whole.
pub const files = [_][]const u8{
    "dto",
    "TodoRepository",
    "TodosController",
    "errors",
    "Service",
    "main",
    "service_test",
};

/// The files of the service of the http guide, src/http/examples, which
/// README.md shows parts of; build.zig gives each as `http-<name>`, and the
/// document of the service, openapi.json there, as `http-openapi.json`.
pub const http_files = [_][]const u8{
    "dto",
    "auth",
    "TodosV1Controller",
    "SessionController",
    "Service",
};

/// The golden documents of zefir-openapi's tests, src/openapi/tests/golden,
/// which README.md shows parts of: a stream of events in OpenAPI 3.2.
/// build.zig gives each as `golden-<name>`.
pub const golden = [_][]const u8{"secure-3.2"};
