//! The document in the tests of an application: `expectFile` compares it
//! with its file in the repository, so that a change of the API that the
//! file does not show fails the tests, and `zig build openapi` rewrites the
//! file from the code.
//!
//! ```zig
//! test "openapi.json matches the code" {
//!     var backend: http.testing.Backend = .init(testing.allocator);
//!     defer backend.deinit();
//!     var service: Service = .{ .todos = .{ .repo = &repo } };
//!     try service.start(testing.allocator, testing.io, backend.backend());
//!     defer service.deinit(testing.io);
//!     try zefir.openapi.testing.expectFile(testing.io, service.docs.document, "openapi.json");
//! }
//! ```
//!
//! The build of the application runs this test in the directory of the
//! file, and a step of its own runs it with `ZEFIR_OPENAPI_UPDATE=1`:
//!
//! ```zig
//! const run_tests = b.addRunArtifact(tests);
//! run_tests.setCwd(b.path("."));
//! const update = b.addRunArtifact(tests);
//! update.setCwd(b.path("."));
//! update.setEnvironmentVariable("ZEFIR_OPENAPI_UPDATE", "1");
//! b.step("openapi", "Rewrite openapi.json from the code").dependOn(&update.step);
//! ```
const std = @import("std");
const Document = @import("document.zig").Document;

/// Compares `document`, as `Document.write` writes it, with the file at
/// `path`, relative to the working directory of the test, or absolute. A
/// file that differs, or none, fails the test: it prints the first line
/// that differs, its number and both texts, and
/// `error: openapi.json is out of date; run `zig build openapi``. A `\r`
/// before a `\n` of the file is not a difference: a checkout on Windows may
/// have them. With `ZEFIR_OPENAPI_UPDATE=1` in the environment of the test
/// it writes the file instead.
pub fn expectFile(io: std.Io, document: Document, path: []const u8) !void {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try document.write(&out.writer);
    const written = out.written();
    if (try updating(gpa)) return std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = written });

    const file = try readFile(io, gpa, path) orelse {
        std.debug.print("{s}: no such file\n", .{path});
        return outOfDate(path);
    };
    defer gpa.free(file);
    const diff = firstDifference(file, written) orelse return;
    std.debug.print("{s}:{d}: the file and the document differ\n  file:     {s}\n  document: {s}\n", .{ path, diff.line, diff.file, diff.document });
    return outOfDate(path);
}

/// The bytes of the file at `path`, null when there is none.
fn readFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// Whether the environment of the test asks for the file to be written:
/// `ZEFIR_OPENAPI_UPDATE=1`.
fn updating(gpa: std.mem.Allocator) !bool {
    const value = std.process.Environ.getAlloc(std.testing.environ, gpa, "ZEFIR_OPENAPI_UPDATE") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return false,
        else => return err,
    };
    defer gpa.free(value);
    return std.mem.eql(u8, value, "1");
}

fn outOfDate(path: []const u8) error{DocumentOutOfDate} {
    std.debug.print("error: {s} is out of date; run `zig build openapi`\n", .{std.fs.path.basename(path)});
    return error.DocumentOutOfDate;
}

/// The first line where the file and the document differ: its number,
/// from 1, and the text of each, "(none)" past its end.
const Difference = struct { line: usize, file: []const u8, document: []const u8 };

fn firstDifference(file: []const u8, document: []const u8) ?Difference {
    var file_lines = std.mem.splitScalar(u8, file, '\n');
    var document_lines = std.mem.splitScalar(u8, document, '\n');
    var line: usize = 1;
    while (true) : (line += 1) {
        const a = file_lines.next();
        const b = document_lines.next();
        if (a == null and b == null) return null;
        const file_line = if (a) |text| std.mem.trimEnd(u8, text, "\r") else null;
        if (file_line != null and b != null and std.mem.eql(u8, file_line.?, b.?)) continue;
        return .{ .line = line, .file = file_line orelse "(none)", .document = b orelse "(none)" };
    }
}

const testing = std.testing;

test "firstDifference: the first line that differs; \\r before \\n is none" {
    try testing.expectEqual(null, firstDifference("{\n  \"a\": 1\n}\n", "{\n  \"a\": 1\n}\n"));
    try testing.expectEqual(null, firstDifference("{\r\n  \"a\": 1\r\n}\r\n", "{\n  \"a\": 1\n}\n"));
    const changed = firstDifference("{\n  \"a\": 1\n}\n", "{\n  \"a\": 2\n}\n").?;
    try testing.expectEqual(2, changed.line);
    try testing.expectEqualStrings("  \"a\": 1", changed.file);
    try testing.expectEqualStrings("  \"a\": 2", changed.document);
    const longer = firstDifference("{}\n", "{}\n\n").?;
    try testing.expectEqual(3, longer.line);
    try testing.expectEqualStrings("(none)", longer.file);
    // Without the newline at its end.
    try testing.expectEqual(2, firstDifference("{}", "{}\n").?.line);
}

test "expectFile: the bytes of the document pass, with \\r\\n too; the file of another is found out" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const document: Document = .{ .root = .{ .object = &.{.{ .key = "openapi", .value = .{ .string = "3.1.2" } }} } };
    const path = ".zig-cache/tmp/" ++ tmp.sub_path ++ "/openapi.json";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "openapi.json", .data = "{\n  \"openapi\": \"3.1.2\"\n}\n" });
    try expectFile(testing.io, document, path);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "openapi.json", .data = "{\r\n  \"openapi\": \"3.1.2\"\r\n}\r\n" });
    try expectFile(testing.io, document, path);
    // What expectFile reports, without its lines: another file, and none.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "openapi.json", .data = "{\n  \"openapi\": \"3.1.1\"\n}\n" });
    const other = (try readFile(testing.io, testing.allocator, path)).?;
    defer testing.allocator.free(other);
    try testing.expectEqual(2, firstDifference(other, "{\n  \"openapi\": \"3.1.2\"\n}\n").?.line);
    try testing.expectEqual(null, try readFile(testing.io, testing.allocator, ".zig-cache/tmp/" ++ tmp.sub_path ++ "/none.json"));
}
