//! The parsing rules of the design's section 14 as data: request heads
//! with the head or the error `parseHead` must give for them (head.zig's
//! tests), and chunked bodies with the data or the error the decoder must
//! give (chunked.zig's tests). Every input is also an entry of the fuzz
//! corpus (fuzz.zig).

const std = @import("std");
const head = @import("../head.zig");
const chunked = @import("../chunked.zig");

/// How a stream of requests ends, as a connection reads it (fuzz.zig).
pub const End = union(enum) {
    /// The input ends right after a request, the connection still open.
    complete,
    /// The input ends inside a head or a body.
    incomplete,
    /// A request without keep-alive: the connection closes after its
    /// response, and the bytes after it are never read.
    closed,
    head: head.Error,
    body: chunked.Decoder.Error,
};

pub const Case = struct {
    name: []const u8,
    raw: []const u8,
    expect: Expect,
};

pub const Expect = union(enum) {
    head: Want,
    err: head.Error,
};

/// What a head that parses must hold; `len` is the whole input.
pub const Want = struct {
    method: std.http.Method = .GET,
    target: []const u8 = "/",
    version: head.Version = .http11,
    /// Name and value of every field, in order; null: not compared.
    fields: ?[]const [2][]const u8 = null,
    framing: head.Framing = .none,
    keep_alive: bool = true,
    expect_continue: bool = false,
};

/// A head of HTTP/1.1 with `Host` and the fields given.
fn get(comptime fields: []const u8) []const u8 {
    return "GET / HTTP/1.1\r\nHost: example.com\r\n" ++ fields ++ "\r\n";
}

/// A head of HTTP/1.0 with the fields given.
fn get10(comptime fields: []const u8) []const u8 {
    return "GET / HTTP/1.0\r\n" ++ fields ++ "\r\n";
}

/// A head of a POST with `Host` and the fields given.
fn post(comptime fields: []const u8) []const u8 {
    return "POST / HTTP/1.1\r\nHost: example.com\r\n" ++ fields ++ "\r\n";
}

fn ok(comptime name: []const u8, comptime raw: []const u8, comptime want: Want) Case {
    return .{ .name = name, .raw = raw, .expect = .{ .head = want } };
}

fn fails(comptime name: []const u8, comptime raw: []const u8, comptime err: head.Error) Case {
    return .{ .name = name, .raw = raw, .expect = .{ .err = err } };
}

/// Task 10: the lines of fields, `Host`, `Connection` and `Expect`.
pub const field_rules = [_]Case{
    // Field lines.
    ok("a value loses the whitespace around it", get("X-A:  \t one two \t \r\n"), .{
        .fields = &.{ .{ "Host", "example.com" }, .{ "X-A", "one two" } },
    }),
    ok("a value may be empty", get("X-A:\r\nX-B: \t \r\n"), .{
        .fields = &.{ .{ "Host", "example.com" }, .{ "X-A", "" }, .{ "X-B", "" } },
    }),
    ok("HTAB inside a value", get("X-A: a\tb\r\n"), .{
        .fields = &.{ .{ "Host", "example.com" }, .{ "X-A", "a\tb" } },
    }),
    ok("bytes 0x80 to 0xFF in a value", get("X-A: D\xc3\xbcsseldorf \x80\xff\r\n"), .{
        .fields = &.{ .{ "Host", "example.com" }, .{ "X-A", "D\xc3\xbcsseldorf \x80\xff" } },
    }),
    ok("a name may use every token character", get("!#$%&'*+-.^_`|~09AZaz: x\r\n"), .{
        .fields = &.{ .{ "Host", "example.com" }, .{ "!#$%&'*+-.^_`|~09AZaz", "x" } },
    }),
    ok("the case of a name is kept", get("x-lower: 1\r\nX-UPPER: 2\r\n"), .{
        .fields = &.{ .{ "Host", "example.com" }, .{ "x-lower", "1" }, .{ "X-UPPER", "2" } },
    }),
    fails("a space between the name and ':'", get("X-A : 1\r\n"), error.BadRequest),
    fails("an HTAB between the name and ':'", get("X-A\t: 1\r\n"), error.BadRequest),
    fails("a space inside a name", get("X A: 1\r\n"), error.BadRequest),
    fails("an empty name", get(": 1\r\n"), error.BadRequest),
    fails("a line without ':'", get("X-A 1\r\n"), error.BadRequest),
    fails("a line of a name only", get("X-A\r\n"), error.BadRequest),
    fails("'@' is not a token character", get("X@A: 1\r\n"), error.BadRequest),
    fails("'\"' is not a token character", get("X\"A: 1\r\n"), error.BadRequest),
    fails("'(' is not a token character", get("X(A): 1\r\n"), error.BadRequest),
    fails("a byte over 0x7F in a name", get("X-\xc3\xbc: 1\r\n"), error.BadRequest),
    fails("obs-fold with a space", get("X-A: 1\r\n 2\r\n"), error.BadRequest),
    fails("obs-fold with an HTAB", get("X-A: 1\r\n\t2\r\n"), error.BadRequest),
    fails("whitespace before the first field", "GET / HTTP/1.1\r\n Host: example.com\r\n\r\n", error.BadRequest),
    fails("a bare CR in a value", get("X-A: 1\r2\r\n"), error.BadRequest),
    fails("a bare CR at the end of a value", get("X-A: 1\r\r\n"), error.BadRequest),
    fails("a bare LF in a value", get("X-A: 1\n2\r\n"), error.BadRequest),
    fails("a field line that ends with LF", get("X-A: 1\n"), error.BadRequest),
    fails("a head that ends with LF", "GET / HTTP/1.1\r\nHost: example.com\r\n\n", error.BadRequest),
    fails("a head that ends with a bare CR", "GET / HTTP/1.1\r\nHost: example.com\r\n\rX", error.BadRequest),
    fails("NUL in a value", get("X-A: 1\x002\r\n"), error.BadRequest),
    fails("NUL in a name", get("X-\x00: 1\r\n"), error.BadRequest),
    fails("0x01 in a value", get("X-A: \x01\r\n"), error.BadRequest),
    fails("VT in a value", get("X-A: 1\x0b2\r\n"), error.BadRequest),
    fails("FF in a value", get("X-A: 1\x0c2\r\n"), error.BadRequest),
    fails("ESC in a value", get("X-A: \x1b[0m\r\n"), error.BadRequest),
    fails("0x1F in a value", get("X-A: \x1f\r\n"), error.BadRequest),
    fails("DEL in a value", get("X-A: 1\x7f\r\n"), error.BadRequest),

    // Host.
    fails("HTTP/1.1 without Host", "GET / HTTP/1.1\r\nX-A: 1\r\n\r\n", error.BadRequest),
    fails("HTTP/1.1 with two Host fields", "GET / HTTP/1.1\r\nHost: a\r\nHost: a\r\n\r\n", error.BadRequest),
    fails("HTTP/1.1 with two Host fields that differ", "GET / HTTP/1.1\r\nHost: a\r\nhost: b\r\n\r\n", error.BadRequest),
    ok("an empty Host", "GET / HTTP/1.1\r\nHost:\r\n\r\n", .{ .fields = &.{.{ "Host", "" }} }),
    ok("Host in any case", "GET / HTTP/1.1\r\nhOST: example.com\r\n\r\n", .{ .fields = &.{.{ "hOST", "example.com" }} }),
    ok("Host with a port", "GET / HTTP/1.1\r\nHost: example.com:8080\r\n\r\n", .{}),
    ok("Host as an IPv6 literal", "GET / HTTP/1.1\r\nHost: [::1]:8080\r\n\r\n", .{}),
    ok("Host with sub-delims and percent-encoding", "GET / HTTP/1.1\r\nHost: a-b_c~d!$&'()*+,;=%41\r\n\r\n", .{}),
    fails("Host with a space inside", "GET / HTTP/1.1\r\nHost: exa mple.com\r\n\r\n", error.BadRequest),
    fails("Host with a path", "GET / HTTP/1.1\r\nHost: example.com/a\r\n\r\n", error.BadRequest),
    fails("Host with user info", "GET / HTTP/1.1\r\nHost: user@example.com\r\n\r\n", error.BadRequest),
    // Found by the HTTP Garden: nginx and Apache httpd refuse it too.
    fails("an absolute target with user info", "GET http://user:pass@example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n", error.BadRequest),
    ok("an absolute target with '@' in its path", "GET http://example.com/a@b HTTP/1.1\r\nHost: example.com\r\n\r\n", .{
        .target = "http://example.com/a@b",
    }),
    fails("Host with a byte over 0x7F", "GET / HTTP/1.1\r\nHost: \xc3\xbc.example\r\n\r\n", error.BadRequest),
    ok("HTTP/1.0 without Host", "GET / HTTP/1.0\r\n\r\n", .{ .version = .http10, .keep_alive = false, .fields = &.{} }),
    fails("HTTP/1.0 with two Host fields", "GET / HTTP/1.0\r\nHost: a\r\nHost: a\r\n\r\n", error.BadRequest),
    ok("HTTP/1.1 with an absolute target still needs Host", "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n", .{
        .target = "http://example.com/",
    }),
    fails("HTTP/1.1 with an absolute target and no Host", "GET http://example.com/ HTTP/1.1\r\n\r\n", error.BadRequest),

    // Connection.
    ok("HTTP/1.1 keeps alive by default", get(""), .{}),
    ok("Connection: close", get("Connection: close\r\n"), .{ .keep_alive = false }),
    ok("Connection: close in any case", get("Connection: CLOSE\r\n"), .{ .keep_alive = false }),
    ok("close in a list of tokens", get("Connection: keep-alive, Upgrade ,close\r\n"), .{ .keep_alive = false }),
    ok("close in a second Connection field", get("Connection: keep-alive\r\nConnection: close\r\n"), .{ .keep_alive = false }),
    ok("empty elements of the list are skipped", get("Connection: ,, close,\r\n"), .{ .keep_alive = false }),
    ok("Connection: keep-alive in HTTP/1.1", get("Connection: keep-alive\r\n"), .{}),
    ok("Connection: Upgrade does not close", get("Connection: Upgrade\r\nUpgrade: websocket\r\n"), .{}),
    ok("a token that only starts with close", get("Connection: closed\r\n"), .{}),
    fails("an element that is not a token", get("Connection: keep alive\r\n"), error.BadRequest),
    fails("a quoted element", get("Connection: \"close\"\r\n"), error.BadRequest),
    ok("HTTP/1.0 closes by default", get10(""), .{ .version = .http10, .keep_alive = false }),
    ok("HTTP/1.0 keeps alive when asked", get10("Connection: keep-alive\r\n"), .{ .version = .http10 }),
    ok("HTTP/1.0 keep-alive in any case", get10("Connection: Keep-Alive\r\n"), .{ .version = .http10 }),
    ok("HTTP/1.0 with keep-alive and close closes", get10("Connection: keep-alive, close\r\n"), .{ .version = .http10, .keep_alive = false }),

    // Expect.
    ok("Expect: 100-continue", post("Content-Length: 5\r\nExpect: 100-continue\r\n"), .{
        .method = .POST,
        .framing = .{ .length = 5 },
        .expect_continue = true,
    }),
    ok("Expect: 100-continue in any case", post("Content-Length: 5\r\nExpect: 100-Continue\r\n"), .{
        .method = .POST,
        .framing = .{ .length = 5 },
        .expect_continue = true,
    }),
    ok("Expect without a body", get("Expect: 100-continue\r\n"), .{ .expect_continue = true }),
    fails("another expectation", post("Content-Length: 5\r\nExpect: 200-ok\r\n"), error.ExpectationFailed),
    fails("100-continue with a parameter", post("Content-Length: 5\r\nExpect: 100-continue;a=b\r\n"), error.ExpectationFailed),
    fails("100-continue and another expectation", post("Content-Length: 5\r\nExpect: 100-continue, x\r\n"), error.ExpectationFailed),
    fails("two Expect fields", post("Content-Length: 5\r\nExpect: 100-continue\r\nExpect: 100-continue\r\n"), error.ExpectationFailed),
    fails("an empty Expect", post("Content-Length: 5\r\nExpect:\r\n"), error.ExpectationFailed),
    ok("HTTP/1.0 ignores Expect", "POST / HTTP/1.0\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n", .{
        .method = .POST,
        .version = .http10,
        .framing = .{ .length = 5 },
        .keep_alive = false,
    }),
    ok("HTTP/1.0 ignores any expectation", get10("Expect: whatever\r\n"), .{ .version = .http10, .keep_alive = false }),

    // A field error comes before what the fields mean.
    fails("a broken line before a missing Host", "GET / HTTP/1.1\r\nX-A : 1\r\n\r\n", error.BadRequest),
    fails("a missing Host before an unknown coding", "POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n", error.BadRequest),
    fails("a broken Connection before an unknown coding", post("Connection: a b\r\nTransfer-Encoding: gzip\r\n"), error.BadRequest),
    fails("an unknown coding before a failed expectation", post("Transfer-Encoding: gzip\r\nExpect: x\r\n"), error.NotImplemented),
};

/// Task 11: the length of the body, from `Content-Length` and
/// `Transfer-Encoding`.
pub const length_rules = [_]Case{
    ok("no Content-Length and no Transfer-Encoding: no body", post(""), .{ .method = .POST }),
    ok("Content-Length: 5", post("Content-Length: 5\r\n"), .{ .method = .POST, .framing = .{ .length = 5 } }),
    ok("Content-Length: 0", post("Content-Length: 0\r\n"), .{ .method = .POST, .framing = .{ .length = 0 } }),
    ok("Content-Length with leading zeros", post("Content-Length: 0005\r\n"), .{ .method = .POST, .framing = .{ .length = 5 } }),
    ok("Content-Length with whitespace around", post("Content-Length: \t 7 \t\r\n"), .{ .method = .POST, .framing = .{ .length = 7 } }),
    ok("Content-Length in any case", post("content-LENGTH: 3\r\n"), .{ .method = .POST, .framing = .{ .length = 3 } }),
    ok("the largest Content-Length", post("Content-Length: 18446744073709551615\r\n"), .{
        .method = .POST,
        .framing = .{ .length = std.math.maxInt(u64) },
    }),
    ok("Content-Length on a GET", get("Content-Length: 4\r\n"), .{ .framing = .{ .length = 4 } }),
    fails("Content-Length over u64", post("Content-Length: 18446744073709551616\r\n"), error.BadRequest),
    fails("Content-Length +5", post("Content-Length: +5\r\n"), error.BadRequest),
    fails("Content-Length -0", post("Content-Length: -0\r\n"), error.BadRequest),
    fails("Content-Length 1_0", post("Content-Length: 1_0\r\n"), error.BadRequest),
    fails("Content-Length 5 5", post("Content-Length: 5 5\r\n"), error.BadRequest),
    fails("Content-Length 0x5", post("Content-Length: 0x5\r\n"), error.BadRequest),
    fails("Content-Length 5.0", post("Content-Length: 5.0\r\n"), error.BadRequest),
    fails("an empty Content-Length", post("Content-Length:\r\n"), error.BadRequest),
    fails("Content-Length as a list", post("Content-Length: 5, 5\r\n"), error.BadRequest),
    fails("Content-Length with a trailing comma", post("Content-Length: 5,\r\n"), error.BadRequest),
    fails("two Content-Length fields that agree", post("Content-Length: 5\r\nContent-Length: 5\r\n"), error.BadRequest),
    fails("two Content-Length fields that differ", post("Content-Length: 5\r\nContent-Length: 6\r\n"), error.BadRequest),
    ok("Transfer-Encoding: chunked", post("Transfer-Encoding: chunked\r\n"), .{ .method = .POST, .framing = .chunked }),
    ok("chunked in any case", post("Transfer-Encoding: ChUnKeD\r\n"), .{ .method = .POST, .framing = .chunked }),
    ok("chunked with whitespace around", post("Transfer-Encoding:  chunked \t\r\n"), .{ .method = .POST, .framing = .chunked }),
    fails("Content-Length with Transfer-Encoding", post("Content-Length: 5\r\nTransfer-Encoding: chunked\r\n"), error.BadRequest),
    fails("Transfer-Encoding with Content-Length", post("Transfer-Encoding: chunked\r\nContent-Length: 5\r\n"), error.BadRequest),
    fails("Content-Length with an unknown Transfer-Encoding", post("Content-Length: 5\r\nTransfer-Encoding: gzip\r\n"), error.BadRequest),
    fails("Transfer-Encoding in HTTP/1.0", "POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n", error.BadRequest),
    fails("an unknown Transfer-Encoding in HTTP/1.0", "POST / HTTP/1.0\r\nTransfer-Encoding: gzip\r\n\r\n", error.BadRequest),
    fails("gzip, chunked", post("Transfer-Encoding: gzip, chunked\r\n"), error.NotImplemented),
    fails("chunked, gzip", post("Transfer-Encoding: chunked, gzip\r\n"), error.NotImplemented),
    fails("chunked, chunked", post("Transfer-Encoding: chunked, chunked\r\n"), error.NotImplemented),
    fails("chunked in two fields", post("Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n"), error.NotImplemented),
    fails("gzip and chunked in two fields", post("Transfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n"), error.NotImplemented),
    fails("identity", post("Transfer-Encoding: identity\r\n"), error.NotImplemented),
    fails("gzip", post("Transfer-Encoding: gzip\r\n"), error.NotImplemented),
    fails("chunked with a parameter", post("Transfer-Encoding: chunked;q=1\r\n"), error.NotImplemented),
    fails("chunked with an empty element", post("Transfer-Encoding: chunked,\r\n"), error.NotImplemented),
    fails("chunkedchunked", post("Transfer-Encoding: chunkedchunked\r\n"), error.NotImplemented),
    fails("an empty Transfer-Encoding", post("Transfer-Encoding:\r\n"), error.NotImplemented),
};

pub const BodyCase = struct {
    name: []const u8,
    raw: []const u8,
    expect: BodyExpect,
};

pub const BodyExpect = union(enum) {
    /// The decoder ends with `done` after `len` bytes and gives `data`.
    done: struct { data: []const u8, len: ?usize = null },
    /// The input ends before the body does.
    incomplete: []const u8,
    err: chunked.Decoder.Error,
};

fn body(comptime name: []const u8, comptime raw: []const u8, comptime data: []const u8) BodyCase {
    return .{ .name = name, .raw = raw, .expect = .{ .done = .{ .data = data } } };
}

fn badBody(comptime name: []const u8, comptime raw: []const u8, comptime err: chunked.Decoder.Error) BodyCase {
    return .{ .name = name, .raw = raw, .expect = .{ .err = err } };
}

/// Task 12: chunked bodies, under the default limit of 4 KiB of
/// extensions and trailers.
pub const chunked_rules = [_]BodyCase{
    body("one chunk", "5\r\nhello\r\n0\r\n\r\n", "hello"),
    body("two chunks", "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n", "hello world"),
    body("an empty body", "0\r\n\r\n", ""),
    body("hex sizes in both cases", "a\r\n0123456789\r\nA\r\nabcdefghij\r\n0\r\n\r\n", "0123456789abcdefghij"),
    body("a size with leading zeros", "0005\r\nhello\r\n000\r\n\r\n", "hello"),
    body("sixteen hex digits", "0000000000000003\r\nabc\r\n0000000000000000\r\n\r\n", "abc"),
    body("data that holds CRLF and the end of a body", "7\r\n\r\n0\r\n\r\n\r\n0\r\n\r\n", "\r\n0\r\n\r\n"),
    body("extensions", "5;a\r\nhello\r\n6;b=1;c=\"x y\"\r\n world\r\n0;end\r\n\r\n", "hello world"),
    body("a quoted extension with escapes", "1;a=\"\\\"q\\\\;\"\r\nx\r\n0\r\n\r\n", "x"),
    body("an extension value with token characters", "1;a=!#$%&'*+-.^_`|~09\r\nx\r\n0\r\n\r\n", "x"),
    body("trailers are dropped", "5\r\nhello\r\n0\r\nVary: *\r\nX-Sum: 42\r\n\r\n", "hello"),
    body("an empty trailer value", "0\r\nX-A:\r\n\r\n", ""),
    .{ .name = "bytes after the body stay", .raw = "1\r\nx\r\n0\r\n\r\nGET / HTTP/1.1\r\n", .expect = .{ .done = .{ .data = "x", .len = 11 } } },
    .{ .name = "a body cut in its data", .raw = "5\r\nhel", .expect = .{ .incomplete = "hel" } },
    .{ .name = "a body without its last chunk", .raw = "3\r\nfoo\r\n", .expect = .{ .incomplete = "foo" } },
    .{ .name = "a body without the end of its trailers", .raw = "3\r\nfoo\r\n0\r\n", .expect = .{ .incomplete = "foo" } },
    badBody("an empty size", "\r\nx\r\n0\r\n\r\n", error.BadChunk),
    badBody("a size that is not hex", "g\r\nx\r\n0\r\n\r\n", error.BadChunk),
    badBody("a size with a sign", "+1\r\nx\r\n0\r\n\r\n", error.BadChunk),
    badBody("a size of 0x", "0x1\r\nx\r\n0\r\n\r\n", error.BadChunk),
    badBody("a space after the size", "1 \r\nx\r\n0\r\n\r\n", error.BadChunk),
    badBody("a space before the size", " 1\r\nx\r\n0\r\n\r\n", error.BadChunk),
    badBody("an HTAB after the size", "1\t;a\r\nx\r\n0\r\n\r\n", error.BadChunk),
    badBody("a space before an extension", "1 ;a\r\nx\r\n0\r\n\r\n", error.BadChunk),
    badBody("seventeen hex digits", "00000000000000001\r\nx\r\n0\r\n\r\n", error.BadChunk),
    badBody("a size line that ends with LF", "1\nx\r\n0\r\n\r\n", error.BadChunk),
    badBody("a size line with a bare CR", "1\rx\r\n0\r\n\r\n", error.BadChunk),
    badBody("data without CRLF after it", "1\r\nxy\r\n0\r\n\r\n", error.BadChunk),
    badBody("data followed by LF only", "1\r\nx\n0\r\n\r\n", error.BadChunk),
    badBody("data followed by CR only", "1\r\nx\r0\r\n\r\n", error.BadChunk),
    badBody("';' without an extension", "1;\r\nx\r\n0\r\n\r\n", error.BadChunk),
    badBody("an extension with an empty value", "1;a=\r\nx\r\n0\r\n\r\n", error.BadChunk),
    badBody("a space inside an extension", "1;a b\r\nx\r\n0\r\n\r\n", error.BadChunk),
    badBody("a space around '='", "1;a = b\r\nx\r\n0\r\n\r\n", error.BadChunk),
    badBody("an unclosed quoted value", "1;a=\"x\r\nx\r\n0\r\n\r\n", error.BadChunk),
    badBody("a bare LF in an extension", "1;a\nb\r\nx\r\n0\r\n\r\n", error.BadChunk),
    badBody("a bare LF in a quoted value", "1;a=\"x\ny\"\r\nx\r\n0\r\n\r\n", error.BadChunk),
    badBody("NUL in an extension", "1;a\x00\r\nx\r\n0\r\n\r\n", error.BadChunk),
    badBody("text after a quoted value", "1;a=\"x\"y\r\nx\r\n0\r\n\r\n", error.BadChunk),
    badBody("a trailer without ':'", "0\r\nVary\r\n\r\n", error.BadChunk),
    badBody("a trailer with a space before ':'", "0\r\nVary : *\r\n\r\n", error.BadChunk),
    badBody("a folded trailer", "0\r\nX-A: 1\r\n 2\r\n\r\n", error.BadChunk),
    badBody("a trailer that ends with LF", "0\r\nX-A: 1\n\r\n", error.BadChunk),
    badBody("NUL in a trailer", "0\r\nX-A: \x00\r\n\r\n", error.BadChunk),
    badBody("a body that ends with LF", "0\r\n\n", error.BadChunk),
    badBody("a body that ends with a bare CR", "0\r\n\rX", error.BadChunk),
};
