//! The JSON Schema of zefir in the tools of other languages, in a package of
//! its own: they run in Docker, so zefir's own build needs neither Node nor
//! Go.
//!
//!   zig build regex   write the regex vectors of zefir-validator's
//!                     `v.schemaOf` (src/validator/testdata/regex_vectors.zig),
//!                     then check them with ajv in Node (ECMA-262 with the
//!                     u flag) and with Go's regexp (RE2); each prints
//!                     `<n> records, <k> disagreements` and fails on one
//!   zig build oas     check the golden documents of zefir-openapi, and the
//!                     openapi.json of the guides, against the official JSON
//!                     Schema of OAS 3.1 and 3.2 (oas/, as spec.openapis.org
//!                     publishes it) with ajv; prints `<n> documents,
//!                     <k> invalid` and fails on one
//!   zig build check   build the Zig programs without running them; no
//!                     Docker needed

const std = @import("std");

/// The images of the checks, by exact tags.
const node_image = "node:24.22.1-alpine3.24";
const go_image = "golang:1.27.3-alpine3.24";
/// What each check in Node runs first: the packages of package-lock.json.
const npm_ci = "npm ci --silent --no-audit --no-fund";

pub fn build(b: *std.Build) void {
    // The programs run here, on the host, and only feed the checks.
    const host = b.graph.host;
    const zefir = b.dependency("zefir", .{ .target = host, .optimize = .Debug });
    const zefir_root = zefir.path(".");

    const regex_vectors = b.addExecutable(.{
        .name = "regex_vectors",
        .root_module = b.createModule(.{
            .root_source_file = zefir.path("src/validator/testdata/regex_vectors.zig"),
            .target = host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "validator", .module = zefir.module("zefir-validator") }},
        }),
    });

    const check = b.step("check", "Build the Zig programs without running them; no Docker needed");
    check.dependOn(&regex_vectors.step);

    const vectors = b.addRunArtifact(regex_vectors).addOutputFileArg("regex_vectors.json");
    const regex = b.step("regex", "Check the regular expressions of v.schemaOf with ajv (ECMA-262) and Go (RE2), in Docker");
    regex.dependOn(&dockerCheck(b, "check the vectors in node", node_image, "node", npm_ci ++ " && node regex.mjs \"$0\"", zefir_root, vectors).step);
    regex.dependOn(&dockerCheck(b, "check the vectors in go", go_image, "go", "go mod download && go run ./regex.go \"$0\"", zefir_root, vectors).step);

    const oas = b.step("oas", "Check the OpenAPI documents of zefir against the official JSON Schema of OAS 3.1 and 3.2 with ajv, in Docker");
    oas.dependOn(&dockerCheck(b, "check the documents against OAS", node_image, "node", npm_ci ++ " && node oas.mjs /pkg/oas /zefir", zefir_root, null).step);
}

/// Runs `command` in a container of `image`, in a copy of the directory
/// `dir` of this package (so that `npm ci` and the Go caches stay in the
/// container). The container reads this package at /pkg and zefir at
/// /zefir; with `data`, that file too, as "$0" of `command`. Docker needs
/// absolute paths for its mounts.
fn dockerCheck(
    b: *std.Build,
    name: []const u8,
    image: []const u8,
    dir: []const u8,
    command: []const u8,
    zefir_root: std.Build.LazyPath,
    data: ?std.Build.LazyPath,
) *std.Build.Step.Run {
    const script = b.fmt(
        \\set -eu
        \\pkg=$(cd "$1" && pwd)
        \\zefir=$(cd "$2" && pwd)
        \\shift 2
        \\file=/data/none
        \\if [ $# -gt 0 ]; then
        \\  file=/data/$(basename "$1")
        \\  set -- -v "$(cd "$(dirname "$1")" && pwd):/data:ro"
        \\fi
        \\exec docker run --rm -v "$pkg:/pkg:ro" -v "$zefir:/zefir:ro" "$@" {s} \
        \\  sh -c 'cp -r /pkg/{s} /work && cd /work && {s}' "$file"
    , .{ image, dir, command });
    const run = b.addSystemCommand(&.{ "sh", "-c", script, "sh" });
    run.setName(name);
    run.addDirectoryArg(b.path("."));
    run.addDirectoryArg(zefir_root);
    if (data) |file| run.addFileArg(file);
    // A check of Docker images, not of a file: run it every time.
    run.has_side_effects = true;
    return run;
}
