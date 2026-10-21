//! The JSON Schema of zefir in the tools of other languages, in a package of
//! its own: they run in Docker, so zefir's own build needs neither Node nor
//! Go.
//!
//!   zig build regex   write the regex vectors of zefir-validator's
//!                     `v.schemaOf` (src/validator/testdata/regex_vectors.zig),
//!                     then check them with ajv in Node (ECMA-262 with the
//!                     u flag) and with Go's regexp (RE2); each prints
//!                     `<n> records, <k> disagreements` and fails on one
//!   zig build check   build the Zig programs without running them; no
//!                     Docker needed

const std = @import("std");

/// The images of the checks, by exact tags.
const node_image = "node:24.22.1-alpine3.24";
const go_image = "golang:1.27.3-alpine3.24";

pub fn build(b: *std.Build) void {
    // The programs run here, on the host, and only feed the checks.
    const host = b.graph.host;
    const zefir = b.dependency("zefir", .{ .target = host, .optimize = .Debug });

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
    regex.dependOn(&dockerCheck(b, node_image, "node", "npm ci --silent --no-audit --no-fund && node regex.mjs", vectors).step);
    regex.dependOn(&dockerCheck(b, go_image, "go", "go mod download && go run ./regex.go", vectors).step);
}

/// Runs `command <file>` in a container of `image`, in a copy of the
/// directory `dir` of this package (so that `npm ci` and the Go caches stay
/// in the container), with the file `vectors` readable at /data. Docker
/// needs absolute paths for its mounts.
fn dockerCheck(b: *std.Build, image: []const u8, dir: []const u8, command: []const u8, vectors: std.Build.LazyPath) *std.Build.Step.Run {
    const script = b.fmt(
        \\set -eu
        \\src=$(cd "$1" && pwd)
        \\data=$(cd "$(dirname "$2")" && pwd)
        \\exec docker run --rm -v "$src:/src:ro" -v "$data:/data:ro" {s} \
        \\  sh -c 'cp -r /src /work && cd /work && {s} "/data/$0"' "$(basename "$2")"
    , .{ image, command });
    const run = b.addSystemCommand(&.{ "sh", "-c", script, "sh" });
    run.setName(b.fmt("check the vectors in {s}", .{dir}));
    run.addDirectoryArg(b.path(dir));
    run.addFileArg(vectors);
    // A check of Docker images, not of a file: run it every time.
    run.has_side_effects = true;
    return run;
}
