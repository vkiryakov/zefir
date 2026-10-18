//! The file of a static request under the root of its mount. The path
//! comes normalized (path.zig): split into segments,
//! each percent-decoded, dot segments resolved, never above the root. Every
//! segment is checked here before any I/O; then the file is opened one
//! component at a time from the root, a directory, then the next, and no
//! component is followed through a symbolic link: a link inside the root
//! is not served at all, wherever it points.
//!
//! Opening the path whole with `follow_symlinks = false` is not enough: it
//! guards the last component only, and `resolve_beneath` is not kept on
//! every system. Here each component is the last of its own open.
const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;

/// Whether a segment of a request's path may name a file or a directory
/// under a root. Refused, on every system: an empty segment, `.` and `..`;
/// a hidden name, one that begins with a dot (`.env`, `.git`); NUL, `/`,
/// `\` (the decoded `%2F` and `%5C`), and `:` (a drive, or an alternate
/// stream of NTFS); a name that ends with a dot or a space, which Windows
/// drops; the names of Windows devices (`CON`, `PRN`, `AUX`, `NUL`,
/// `CONIN$`, `CONOUT$`, `COM0`–`COM9`, `LPT0`–`LPT9` and their forms with
/// `¹`, `²` and `³`) in any case, with any extension (`nul.txt`); and `~`
/// before a digit, the mark of a Windows short name (`GIT~1` would name
/// `.git`).
pub fn allowed(segment: []const u8) bool {
    if (segment.len == 0 or segment[0] == '.') return false;
    const last = segment[segment.len - 1];
    if (last == '.' or last == ' ') return false;
    for (segment, 0..) |c, i| switch (c) {
        0, '/', '\\', ':' => return false,
        '~' => if (i + 1 < segment.len and std.ascii.isDigit(segment[i + 1])) return false,
        else => {},
    };
    return !isDeviceName(segment);
}

/// A name that Windows takes for a device: the part before the first dot,
/// its trailing spaces dropped, in any case.
fn isDeviceName(segment: []const u8) bool {
    const base = std.mem.trimEnd(u8, segment[0 .. std.mem.findScalar(u8, segment, '.') orelse segment.len], " ");
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" }) |name| {
        if (std.ascii.eqlIgnoreCase(base, name)) return true;
    }
    if (base.len < 4) return false;
    const port = base[0..3];
    if (!std.ascii.eqlIgnoreCase(port, "COM") and !std.ascii.eqlIgnoreCase(port, "LPT")) return false;
    const number = base[3..];
    if (number.len == 1) return std.ascii.isDigit(number[0]);
    // ¹, ² and ³ in UTF-8.
    for ([_][]const u8{ "\u{b9}", "\u{b2}", "\u{b3}" }) |superscript| {
        if (std.mem.eql(u8, number, superscript)) return true;
    }
    return false;
}

/// A regular file, open, and what `stat` said of it.
pub const Opened = struct {
    file: Io.File,
    stat: Io.File.Stat,
    /// The name it was opened by, for its type: the last segment, or the
    /// index file's name.
    name: []const u8,
};

pub const Resolved = union(enum) {
    /// A regular file: the caller closes it.
    file: Opened,
    /// Nothing there: no such file, a part of the path that is not a
    /// directory, a directory without an index file, a name the system
    /// cannot take.
    missing,
    /// A segment `allowed` refuses, a symbolic link on the way, or
    /// something that is neither a file nor a directory.
    refused,
    /// The system failed otherwise, such as `AccessDenied` or out of file
    /// descriptors: the server logs it and answers 500.
    failed: anyerror,
};

/// Opens the file of `segments` under `root`: a directory gives its
/// `index` file, if it has one. `root` stays open.
pub fn open(io: Io, root: Io.Dir, segments: []const []const u8, index: ?[]const u8) Io.Cancelable!Resolved {
    for (segments) |s| if (!allowed(s)) return .refused;
    var dir = root;
    var owned = false;
    defer if (owned) dir.close(io);
    for (segments, 0..) |s, i| {
        if (i + 1 == segments.len) {
            switch (try openFile(io, dir, s)) {
                .file => |file| return .{ .file = .{ .file = file.file, .stat = file.stat, .name = s } },
                // A directory without an index file has nothing to serve.
                .directory => if (index == null) return .missing,
                .missing => return .missing,
                .refused => return .refused,
                .failed => |err| return .{ .failed = err },
            }
        }
        const next = switch (try enter(io, dir, s)) {
            .dir => |d| d,
            .missing => return .missing,
            .refused => return .refused,
            .failed => |err| return .{ .failed = err },
        };
        if (owned) dir.close(io);
        dir = next;
        owned = true;
    }
    // The root, or a directory: its index file, a file again.
    const name = index orelse return .missing;
    return switch (try openFile(io, dir, name)) {
        .file => |file| .{ .file = .{ .file = file.file, .stat = file.stat, .name = name } },
        .directory, .missing => .missing,
        .refused => .refused,
        .failed => |err| .{ .failed = err },
    };
}

const FileStep = union(enum) {
    file: struct { file: Io.File, stat: Io.File.Stat },
    directory,
    missing,
    refused,
    failed: anyerror,
};

/// Opens `name` in `dir`, not through a link: a regular file stays open, a
/// directory is only named.
fn openFile(io: Io, dir: Io.Dir, name: []const u8) Io.Cancelable!FileStep {
    const file = dir.openFile(io, name, .{ .follow_symlinks = false }) catch |err| return failure(FileStep, err);
    const stat = file.stat(io) catch |err| {
        file.close(io);
        return failure(FileStep, err);
    };
    switch (stat.kind) {
        .file => return .{ .file = .{ .file = file, .stat = stat } },
        .directory => {
            file.close(io);
            return .directory;
        },
        else => {
            file.close(io);
            return .refused;
        },
    }
}

const DirStep = union(enum) {
    dir: Io.Dir,
    missing,
    refused,
    failed: anyerror,
};

/// Opens the directory `name` in `parent`, not through a link. On POSIX
/// systems a link fails to open; on Windows the open takes the link
/// itself, which must then be the very directory the name resolves to: a
/// link to a directory, or a junction, is an object of its own.
fn enter(io: Io, parent: Io.Dir, name: []const u8) Io.Cancelable!DirStep {
    const dir = parent.openDir(io, name, .{ .follow_symlinks = false }) catch |err| return failure(DirStep, err);
    const stat = dir.stat(io) catch |err| {
        dir.close(io);
        return failure(DirStep, err);
    };
    if (stat.kind != .directory) {
        dir.close(io);
        return .refused;
    }
    if (builtin.os.tag == .windows) {
        const target = parent.statFile(io, name, .{}) catch |err| {
            dir.close(io);
            return failure(DirStep, err);
        };
        if (target.inode != stat.inode) {
            dir.close(io);
            return .refused;
        }
    }
    return .{ .dir = dir };
}

/// What an error of the system means for the request.
fn failure(comptime Step: type, err: anyerror) Io.Cancelable!Step {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.FileNotFound, error.NotDir, error.IsDir, error.BadPathName, error.NameTooLong, error.NoDevice, error.NetworkNotFound => .missing,
        error.SymLinkLoop => .refused,
        else => .{ .failed = err },
    };
}

const testing = std.testing;

test "allowed: names of files, and what is refused on every system" {
    for ([_][]const u8{ "index.html", "app.min.js", "a", "café.txt", "a b.txt", "file~", "x~y", "con-tact.html", "nullable.js", "COM10", "lpt", "console.log", "auxiliary", "a.b.c" }) |segment| {
        testing.expect(allowed(segment)) catch |err| {
            std.debug.print("segment {s}\n", .{segment});
            return err;
        };
    }
    for ([_][]const u8{
        "",           ".",           "..",         ".env",   ".git",         ".hidden.txt",
        "a\x00b",     "a/b",         "..\\secret", "a\\b",   "C:",           "file.txt::$DATA",
        "trailing.",  "trailing ",   "CON",        "con",    "Con.txt",      "nul.txt",
        "NUL.tar.gz", "PRN",         "aux.html",   "COM1",   "com9.log",     "COM0",
        "LPT1",       "lpt9.txt",    "LPT0",       "CONIN$", "conout$.txt",  "CON .txt",
        "COM\u{b9}",  "lpt\u{b3}.x", "GIT~1",      "ENV~1",  "PROGRA~1.TXT",
    }) |segment| {
        testing.expect(!allowed(segment)) catch |err| {
            std.debug.print("segment {s}\n", .{segment});
            return err;
        };
    }
}
