//! The parser on streams of requests, as a connection reads them: heads
//! by `parseHead`, bodies by their framing, one request after another.
//! Three checks run on it:
//!
//! - llhttp's request vectors (testdata/llhttp.zig) give the requests and
//!   the end their rows expect;
//! - the fuzz test: any input gives the same requests and the same end
//!   whether it comes at once or in pieces of 1 to 64 bytes, nothing
//!   panics, and a head never waits for more bytes with a full buffer.
//!   `zig build test` runs it on its corpus, every input of testdata/,
//!   with the pieces one byte each; `zig build fuzz-http --fuzz` runs the
//!   fuzzer (Linux, CI's fuzz.yml);
//! - 20 000 mutations of the corpus from a fixed seed keep the same
//!   properties on every run.

const std = @import("std");
const head = @import("head.zig");
const chunked = @import("chunked.zig");
const cases = @import("testdata/cases.zig");
const llhttp = @import("testdata/llhttp.zig");

const testing = std.testing;
const End = cases.End;

/// A request of a stream as the runner read it; its slices live in the
/// runner's arena.
const Message = struct {
    method: std.http.Method,
    target: []const u8,
    version: head.Version,
    keep_alive: bool,
    expect_continue: bool,
    framing: head.Framing,
    fields: []const head.Field,
    body: []const u8,
};

const Outcome = struct {
    messages: []const Message,
    end: End,
};

const Options = struct {
    limits: head.Limits = .{},
    max_meta_bytes: u32 = 4 << 10,
};

/// Where the sizes of the pieces come from.
const Pieces = union(enum) {
    smith: *testing.Smith,
    random: std.Random,

    fn next(pieces: Pieces) usize {
        return switch (pieces) {
            .smith => |smith| smith.valueRangeAtMost(u8, 1, 64),
            .random => |random| random.intRangeAtMost(u8, 1, 64),
        };
    }
};

/// Reads the requests of `input` as a connection would, through a buffer
/// of `max_head_bytes`: all of the input at once when `pieces` is null,
/// otherwise in pieces of the sizes it gives. Fails with
/// `error.NullWithFullBuffer` if a head waits for more bytes while the
/// buffer is full.
fn run(arena: std.mem.Allocator, input: []const u8, options: Options, pieces: ?Pieces) !Outcome {
    var messages: std.ArrayList(Message) = .empty;
    const buffer = try arena.alloc(u8, if (pieces == null) input.len else options.limits.max_head_bytes);
    const storage = try arena.alloc(head.Field, options.limits.max_header_fields);
    var reader: Reader = .{ .input = input, .buffer = buffer, .pieces = pieces };
    while (true) {
        const h = while (true) {
            if (head.parseHead(reader.bytes(), options.limits, storage)) |result| {
                if (result) |h| break h;
            } else |err| return .{ .messages = messages.items, .end = .{ .head = err } };
            if (reader.atEnd()) {
                return .{ .messages = messages.items, .end = if (reader.len == 0) .complete else .incomplete };
            }
            if (reader.len == buffer.len) return error.NullWithFullBuffer;
            reader.read();
        };
        if (h.len > reader.len) return error.HeadLongerThanInput;
        var message: Message = .{
            .method = h.method,
            .target = try arena.dupe(u8, h.target),
            .version = h.version,
            .keep_alive = h.keep_alive,
            .expect_continue = h.expect_continue,
            .framing = h.framing,
            .fields = try dupeFields(arena, h.fields),
            .body = "",
        };
        reader.consume(h.len);

        var body: std.ArrayList(u8) = .empty;
        const end: ?End = switch (h.framing) {
            .none => null,
            .length => |length| length: {
                var left = length;
                while (true) {
                    const n: usize = @intCast(@min(left, reader.len));
                    try body.appendSlice(arena, reader.bytes()[0..n]);
                    reader.consume(n);
                    left -= n;
                    if (left == 0) break :length null;
                    if (reader.atEnd()) break :length .incomplete;
                    reader.read();
                }
            },
            .chunked => chunks: {
                var decoder: chunked.Decoder = .init(options.max_meta_bytes);
                while (true) {
                    const step = decoder.feed(reader.bytes()) catch |err| break :chunks .{ .body = err };
                    if (step.consumed > reader.len) return error.ConsumedMoreThanInput;
                    try body.appendSlice(arena, step.data);
                    reader.consume(step.consumed);
                    if (step.done) break :chunks null;
                    if (step.consumed == 0) {
                        if (reader.atEnd()) break :chunks .incomplete;
                        reader.read();
                    }
                }
            },
        };
        message.body = body.items;
        try messages.append(arena, message);
        if (end) |e| return .{ .messages = messages.items, .end = e };
        if (!h.keep_alive) return .{ .messages = messages.items, .end = .closed };
    }
}

/// The connection's buffer: `len` bytes read and not yet used.
const Reader = struct {
    input: []const u8,
    buffer: []u8,
    pieces: ?Pieces,
    len: usize = 0,
    fed: usize = 0,

    fn bytes(r: *const Reader) []const u8 {
        return r.buffer[0..r.len];
    }

    fn atEnd(r: *const Reader) bool {
        return r.fed == r.input.len;
    }

    /// Reads the next piece of the input, as much as the buffer takes.
    fn read(r: *Reader) void {
        const piece = if (r.pieces) |pieces| pieces.next() else r.input.len;
        const n = @min(piece, r.input.len - r.fed, r.buffer.len - r.len);
        @memcpy(r.buffer[r.len..][0..n], r.input[r.fed..][0..n]);
        r.len += n;
        r.fed += n;
    }

    fn consume(r: *Reader, n: usize) void {
        std.mem.copyForwards(u8, r.buffer[0 .. r.len - n], r.buffer[n..r.len]);
        r.len -= n;
    }
};

fn dupeFields(arena: std.mem.Allocator, fields: []const head.Field) ![]const head.Field {
    const copy = try arena.alloc(head.Field, fields.len);
    for (fields, copy) |field, *to| to.* = .{ .name = try arena.dupe(u8, field.name), .value = try arena.dupe(u8, field.value) };
    return copy;
}

fn expectSameOutcome(want: Outcome, got: Outcome) !void {
    try testing.expectEqual(want.messages.len, got.messages.len);
    for (want.messages, got.messages) |a, b| {
        try testing.expectEqual(a.method, b.method);
        try testing.expectEqualStrings(a.target, b.target);
        try testing.expectEqual(a.version, b.version);
        try testing.expectEqual(a.keep_alive, b.keep_alive);
        try testing.expectEqual(a.expect_continue, b.expect_continue);
        try testing.expectEqual(a.framing, b.framing);
        try testing.expectEqual(a.fields.len, b.fields.len);
        for (a.fields, b.fields) |x, y| {
            try testing.expectEqualStrings(x.name, y.name);
            try testing.expectEqualStrings(x.value, y.value);
        }
        try testing.expectEqualStrings(a.body, b.body);
    }
    try testing.expectEqual(want.end, got.end);
}

// llhttp's vectors.

/// The field the test adds to rows of HTTP/1.1 without `Host`.
const added_host = "Host: llhttp.test\r\n";

/// `raw` with `added_host` inserted at each offset of `at`.
fn withHost(comptime raw: []const u8, comptime at: []const usize) []const u8 {
    comptime var out: []const u8 = "";
    comptime var from: usize = 0;
    inline for (at) |offset| {
        out = out ++ raw[from..offset] ++ added_host;
        from = offset;
    }
    return out ++ raw[from..];
}

fn expectRow(arena: std.mem.Allocator, row: llhttp.Row, raw: []const u8, skip_host: bool) !void {
    const got = try run(arena, raw, .{}, null);
    const want = row.expect;
    errdefer printOutcome(row.name, raw, got);
    try testing.expectEqual(want.messages.len, got.messages.len);
    for (want.messages, got.messages) |a, b| {
        try testing.expectEqual(a.method, b.method);
        try testing.expectEqualStrings(a.target, b.target);
        try testing.expectEqual(a.version, b.version);
        try testing.expectEqual(a.keep_alive, b.keep_alive);
        try testing.expectEqual(a.expect_continue, b.expect_continue);
        try testing.expectEqual(a.framing, b.framing);
        const fields = if (skip_host) b.fields[1..] else b.fields;
        if (skip_host) {
            try testing.expectEqualStrings("Host", b.fields[0].name);
            try testing.expectEqualStrings("llhttp.test", b.fields[0].value);
        }
        try testing.expectEqual(a.fields.len, fields.len);
        for (a.fields, fields) |x, y| {
            try testing.expectEqualStrings(x[0], y.name);
            try testing.expectEqualStrings(x[1], y.value);
        }
        try testing.expectEqualStrings(a.body, b.body);
    }
    try testing.expectEqual(want.end, got.end);
}

/// What the runner got for a row, written as the row's `expect` would be.
fn printOutcome(name: []const u8, raw: []const u8, got: Outcome) void {
    std.debug.print("row \"{s}\"\ninput: \"{f}\"\ngot: .{{ .messages = &.{{", .{ name, std.zig.fmtString(raw) });
    for (got.messages) |m| {
        std.debug.print(" .{{ .method = .{t}, .target = \"{f}\", .version = .{t}, .keep_alive = {}, .expect_continue = {}, .framing = ", .{
            m.method, std.zig.fmtString(m.target), m.version, m.keep_alive, m.expect_continue,
        });
        switch (m.framing) {
            .none => std.debug.print(".none", .{}),
            .length => |n| std.debug.print(".{{ .length = {d} }}", .{n}),
            .chunked => std.debug.print(".chunked", .{}),
        }
        std.debug.print(", .fields = &.{{", .{});
        for (m.fields) |f| std.debug.print(" .{{ \"{f}\", \"{f}\" }},", .{ std.zig.fmtString(f.name), std.zig.fmtString(f.value) });
        std.debug.print(" }}, .body = \"{f}\" }},", .{std.zig.fmtString(m.body)});
    }
    switch (got.end) {
        .head => |err| std.debug.print(" }}, .end = .{{ .head = error.{t} }} }}\n", .{err}),
        .body => |err| std.debug.print(" }}, .end = .{{ .body = error.{t} }} }}\n", .{err}),
        else => |end| std.debug.print(" }}, .end = .{t} }}\n", .{end}),
    }
}

test "llhttp request vectors" {
    var failed: usize = 0;
    inline for (llhttp.rows) |row| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        if (row.host_at.len == 0) {
            expectRow(arena, row, row.raw, false) catch {
                failed += 1;
            };
        } else {
            // llhttp's own input lacks the Host that HTTP/1.1 requires:
            // 400 at the first head. With Host added, the rest of the row.
            const verbatim = try run(arena, row.raw, .{}, null);
            if (verbatim.messages.len != 0 or !std.meta.eql(verbatim.end, End{ .head = error.BadRequest })) {
                printOutcome(row.name ++ " (as llhttp sends it)", row.raw, verbatim);
                failed += 1;
            }
            expectRow(arena, row, comptime withHost(row.raw, row.host_at), true) catch {
                failed += 1;
            };
        }
    }
    try testing.expectEqual(0, failed);
}

// The fuzz test and the mutations.

/// Small limits, so that the fuzzer also reaches every limit.
const fuzz_options: Options = .{
    .limits = .{ .max_head_bytes = 1024, .max_header_fields = 16, .max_target_bytes = 128 },
    .max_meta_bytes = 64,
};

const max_input = 4096;

/// What one check of an input of `max_input` bytes may take, many times
/// over.
var check_memory: [1 << 20]u8 = undefined;

fn checkProperties(input: []const u8, pieces: Pieces) !void {
    var memory: std.heap.FixedBufferAllocator = .init(&check_memory);
    const arena = memory.allocator();
    const whole = try run(arena, input, fuzz_options, null);
    const split = try run(arena, input, fuzz_options, pieces);
    try expectSameOutcome(whole, split);
}

fn fuzzOne(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [max_input]u8 = undefined;
    const input = buffer[0..smith.slice(&buffer)];
    try checkProperties(input, .{ .smith = smith });
}

/// A head for the chunked bodies of testdata/cases.zig.
const chunked_head = "POST /upload HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n";

/// Every input of testdata/, whole requests: heads, chunked bodies after
/// a head, llhttp's rows as llhttp sends them and with Host added. Also
/// the payloads of the HTTP Garden (tests/http/garden/payloads.zig).
pub const inputs = collect: {
    @setEvalBranchQuota(100_000);
    var list: []const []const u8 = &.{};
    for (cases.field_rules ++ cases.length_rules) |case| list = list ++ .{case.raw};
    for (cases.chunked_rules) |case| list = list ++ .{chunked_head ++ case.raw};
    for (llhttp.rows) |row| {
        list = list ++ .{row.raw};
        if (row.host_at.len > 0) list = list ++ .{withHost(row.raw, row.host_at)};
    }
    break :collect list;
};

/// A corpus entry: `Smith.slice` reads a little-endian u32 length first,
/// and gives nothing for an entry longer than its buffer.
fn sample(comptime raw: []const u8) []const u8 {
    const cut = raw[0..@min(raw.len, max_input)];
    return comptime std.mem.toBytes(std.mem.nativeToLittle(u32, cut.len)) ++ cut;
}

const corpus = make: {
    @setEvalBranchQuota(100_000);
    var entries: [inputs.len][]const u8 = undefined;
    for (inputs, &entries) |input, *entry| entry.* = sample(input);
    break :make entries;
};

test "fuzz parseHead and the chunked decoder" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = &corpus });
}

/// Bytes the mutations put in: the ones the rules are about.
const interesting = "\r\n \t:;,=\"\\0129aAfF-_/?*\x00\x01\x7f\x80\xff";

/// One mutation of `buffer[0..len]` in place; the new length.
fn mutate(random: std.Random, buffer: []u8, len: usize) usize {
    if (len == 0) {
        buffer[0] = interesting[random.uintLessThan(usize, interesting.len)];
        return 1;
    }
    const at = random.uintLessThan(usize, len);
    switch (random.uintLessThan(u8, 6)) {
        // Flip a bit.
        0 => buffer[at] ^= @as(u8, 1) << random.int(u3),
        // Put an interesting byte in place of one.
        1 => buffer[at] = interesting[random.uintLessThan(usize, interesting.len)],
        // Insert an interesting byte.
        2 => if (len < buffer.len) {
            std.mem.copyBackwards(u8, buffer[at + 1 .. len + 1], buffer[at..len]);
            buffer[at] = interesting[random.uintLessThan(usize, interesting.len)];
            return len + 1;
        },
        // Delete a byte.
        3 => {
            std.mem.copyForwards(u8, buffer[at .. len - 1], buffer[at + 1 .. len]);
            return len - 1;
        },
        // Duplicate the line that starts after the first LF from `at`:
        // a second Content-Length, Host or Transfer-Encoding.
        4 => {
            const start = (std.mem.findScalarPos(u8, buffer[0..len], at, '\n') orelse return len) + 1;
            const end = (std.mem.findScalarPos(u8, buffer[0..len], start, '\n') orelse return len) + 1;
            const n = end - start;
            if (len + n > buffer.len) return len;
            std.mem.copyBackwards(u8, buffer[end + n .. len + n], buffer[end..len]);
            @memcpy(buffer[end..][0..n], buffer[start..end]);
            return len + n;
        },
        // Turn the first CRLF from `at` into a bare LF.
        5 => {
            const lf = std.mem.findPos(u8, buffer[0..len], at, "\r\n") orelse return len;
            std.mem.copyForwards(u8, buffer[lf .. len - 1], buffer[lf + 1 .. len]);
            return len - 1;
        },
        else => unreachable,
    }
    return len;
}

test "seeded mutations keep every property" {
    var prng: std.Random.DefaultPrng = .init(0x7a65_6669_7268_7474);
    const random = prng.random();
    var buffer: [max_input]u8 = undefined;
    for (0..20_000) |i| {
        const entry = inputs[random.uintLessThan(usize, inputs.len)];
        var len: usize = @min(entry.len, max_input);
        @memcpy(buffer[0..len], entry[0..len]);
        for (0..random.intRangeAtMost(u8, 1, 4)) |_| len = mutate(random, &buffer, len);
        checkProperties(buffer[0..len], .{ .random = random }) catch |err| {
            std.debug.print("mutation {d}: \"{f}\"\n", .{ i, std.zig.fmtString(buffer[0..len]) });
            return err;
        };
    }
}
