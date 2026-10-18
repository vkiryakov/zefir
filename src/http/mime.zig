//! The content type of a file by its extension: what `ctx.response.file`
//! and the static files send as `Content-Type`. Text types say
//! `charset=utf-8`; an extension
//! the table does not know is `application/octet-stream`, which a browser
//! downloads instead of showing.
const std = @import("std");

/// For a file whose extension the table does not know.
pub const unknown = "application/octet-stream";

/// The extensions, in lowercase, and their types.
const table = [_]struct { []const u8, []const u8 }{
    .{ "html", "text/html; charset=utf-8" },
    .{ "htm", "text/html; charset=utf-8" },
    .{ "css", "text/css; charset=utf-8" },
    .{ "js", "text/javascript; charset=utf-8" },
    .{ "mjs", "text/javascript; charset=utf-8" },
    .{ "cjs", "text/javascript; charset=utf-8" },
    .{ "json", "application/json" },
    .{ "jsonld", "application/ld+json" },
    .{ "map", "application/json" },
    .{ "webmanifest", "application/manifest+json" },
    .{ "txt", "text/plain; charset=utf-8" },
    .{ "csv", "text/csv; charset=utf-8" },
    .{ "md", "text/markdown; charset=utf-8" },
    .{ "ics", "text/calendar; charset=utf-8" },
    .{ "xml", "application/xml" },
    .{ "xhtml", "application/xhtml+xml" },
    .{ "rss", "application/rss+xml" },
    .{ "atom", "application/atom+xml" },
    .{ "yaml", "application/yaml" },
    .{ "yml", "application/yaml" },
    .{ "svg", "image/svg+xml" },
    .{ "png", "image/png" },
    .{ "apng", "image/apng" },
    .{ "jpg", "image/jpeg" },
    .{ "jpeg", "image/jpeg" },
    .{ "gif", "image/gif" },
    .{ "webp", "image/webp" },
    .{ "avif", "image/avif" },
    .{ "ico", "image/x-icon" },
    .{ "bmp", "image/bmp" },
    .{ "pdf", "application/pdf" },
    .{ "zip", "application/zip" },
    .{ "gz", "application/gzip" },
    .{ "tar", "application/x-tar" },
    .{ "wasm", "application/wasm" },
    .{ "woff", "font/woff" },
    .{ "woff2", "font/woff2" },
    .{ "ttf", "font/ttf" },
    .{ "otf", "font/otf" },
    .{ "eot", "application/vnd.ms-fontobject" },
    .{ "mp4", "video/mp4" },
    .{ "webm", "video/webm" },
    .{ "ogv", "video/ogg" },
    .{ "mp3", "audio/mpeg" },
    .{ "m4a", "audio/mp4" },
    .{ "aac", "audio/aac" },
    .{ "flac", "audio/flac" },
    .{ "ogg", "audio/ogg" },
    .{ "wav", "audio/wav" },
};

/// The content type of the file at `path` by its extension, in any case:
/// "reports/2026-10.PDF" is `application/pdf`. A name without an
/// extension, or one that only begins with a dot (".env"), is `unknown`.
pub fn of(path: []const u8) []const u8 {
    const name = path[if (std.mem.findLastAny(u8, path, "/\\")) |slash| slash + 1 else 0..];
    const dot = std.mem.findScalarLast(u8, name, '.') orelse return unknown;
    if (dot == 0) return unknown;
    const extension = name[dot + 1 ..];
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(extension, entry[0])) return entry[1];
    }
    return unknown;
}

const testing = std.testing;

test "of: the type by the extension, in any case; unknown otherwise" {
    try testing.expectEqualStrings("application/pdf", of("reports/2026-10.pdf"));
    try testing.expectEqualStrings("application/pdf", of("REPORT.PDF"));
    try testing.expectEqualStrings("text/csv; charset=utf-8", of("todos.csv"));
    try testing.expectEqualStrings("text/html; charset=utf-8", of("public/index.html"));
    try testing.expectEqualStrings("text/javascript; charset=utf-8", of("app.min.js"));
    try testing.expectEqualStrings("application/gzip", of("logs.tar.gz"));
    try testing.expectEqualStrings("image/svg+xml", of("C:\\site\\logo.svg"));
    try testing.expectEqualStrings("text/javascript; charset=utf-8", of("chunk-4f2a.cjs"));
    try testing.expectEqualStrings("application/vnd.ms-fontobject", of("fonts/icons.eot"));
    try testing.expectEqualStrings("text/calendar; charset=utf-8", of("events.ics"));
    // No extension, a dot file, a dot in a directory, an extension unknown.
    for ([_][]const u8{ "README", ".env", "a.d/notes", "photo.heic", "trailing.", "" }) |path| {
        try testing.expectEqualStrings(unknown, of(path));
    }
}
