//! Request vectors of llhttp, the HTTP parser of Node.js, as data rows: the
//! tests of method.md, uri.md, connection.md, content-length.md,
//! transfer-encoding.md, invalid.md, pipelining.md and sample.md in its
//! test/request/, at commit 69936dbc22922e596a05dfa912fc11d9a7af2136
//! (https://github.com/nodejs/llhttp/tree/69936dbc22922e596a05dfa912fc11d9a7af2136/test/request).
//!
//! `raw` is the input of a test as llhttp's harness builds it from the
//! markdown (newlines as CRLF, `\r` `\n` `\t` `\f` `\xHH` unescaped, text
//! in UTF-8). `expect` is what our parser must give: llhttp's own verdict
//! where we agree with it, with values trimmed of the whitespace around
//! them as RFC 9112 §5 reads them. A row where we differ says why in its
//! comment: `stricter than llhttp: …` where llhttp takes what we refuse
//! (every row of llhttp's lenient modes is one), `llhttp refuses it too;
//! …` where only the status differs, and the rows of upgrades, which we
//! don't do.
//!
//! Most of llhttp's inputs are HTTP/1.1 without `Host`, which we refuse
//! (400, RFC 9112 §3.2). For such a row `host_at` lists where its request
//! lines end: the test checks that the input as llhttp sends it fails with
//! 400, then inserts `Host: llhttp.test` at those offsets and expects the
//! rest of the row (the inserted field is not in `fields`).
//!
//! llhttp's license:
//!
//! MIT License
//!
//! Copyright © 2018 Fedor Indutny
//!
//! Permission is hereby granted, free of charge, to any person obtaining a
//! copy of this software and associated documentation files (the
//! "Software"), to deal in the Software without restriction, including
//! without limitation the rights to use, copy, modify, merge, publish,
//! distribute, sublicense, and/or sell copies of the Software, and to permit
//! persons to whom the Software is furnished to do so, subject to the
//! following conditions:
//!
//! The above copyright notice and this permission notice shall be included
//! in all copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
//! OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//! MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
//! NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
//! DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
//! OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
//! USE OR OTHER DEALINGS IN THE SOFTWARE.

const std = @import("std");
const head = @import("../head.zig");
const cases = @import("cases.zig");

pub const Row = struct {
    /// "<file>.md:<line> <the test's heading>".
    name: []const u8,
    raw: []const u8,
    /// Offsets of `raw` where the test inserts `Host: llhttp.test` + CRLF.
    host_at: []const usize = &.{},
    expect: Expect,
};

pub const Expect = struct {
    messages: []const Message = &.{},
    end: cases.End,
};

pub const Message = struct {
    method: std.http.Method,
    target: []const u8,
    version: head.Version = .http11,
    keep_alive: bool = true,
    expect_continue: bool = false,
    framing: head.Framing = .none,
    fields: []const [2][]const u8 = &.{},
    body: []const u8 = "",
};

pub const rows = [_]Row{
    // stricter than llhttp: REPORT is not a method of std.http.Method: 501.
    .{
        .name = "method.md:4 REPORT request",
        .raw = "REPORT /test HTTP/1.1\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.NotImplemented } },
    },
    // stricter than llhttp: the authority form of CONNECT is refused: 400 (no
    // tunnels).
    .{
        .name = "method.md:27 REPORT request / CONNECT request",
        .raw = "CONNECT 0-home0.netscape.com:443 HTTP/1.0\r\n" ++
            "User-agent: Mozilla/1.1N\r\n" ++
            "Proxy-authorization: basic aGVsbG86d29ybGQ=\r\n" ++
            "\r\n" ++
            "some data\r\n" ++
            "and yet even more data",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // stricter than llhttp: the authority form of CONNECT is refused: 400 (no
    // tunnels).
    .{
        .name = "method.md:62 REPORT request / CONNECT request with CAPS",
        .raw = "CONNECT HOME0.NETSCAPE.COM:443 HTTP/1.0\r\n" ++
            "User-agent: Mozilla/1.1N\r\n" ++
            "Proxy-authorization: basic aGVsbG86d29ybGQ=\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // stricter than llhttp: the authority form of CONNECT is refused: 400 (no
    // tunnels).
    .{
        .name = "method.md:96 REPORT request / CONNECT with body",
        .raw = "CONNECT foo.bar.com:443 HTTP/1.0\r\n" ++
            "User-agent: Mozilla/1.1N\r\n" ++
            "Proxy-authorization: basic aGVsbG86d29ybGQ=\r\n" ++
            "Content-Length: 10\r\n" ++
            "\r\n" ++
            "blarfcicle\"",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // stricter than llhttp: M-SEARCH is not a method of std.http.Method: 501.
    .{
        .name = "method.md:135 REPORT request / M-SEARCH request",
        .raw = "M-SEARCH * HTTP/1.1\r\n" ++
            "HOST: 239.255.255.250:1900\r\n" ++
            "MAN: \"ssdp:discover\"\r\n" ++
            "ST: \"ssdp:all\"\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.NotImplemented } },
    },
    .{
        .name = "method.md:173 REPORT request / PATCH request",
        .raw = "PATCH /file.txt HTTP/1.1\r\n" ++
            "Host: www.example.com\r\n" ++
            "Content-Type: application/example\r\n" ++
            "If-Match: \"e0023aa4e\"\r\n" ++
            "Content-Length: 10\r\n" ++
            "\r\n" ++
            "cccccccccc",
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .PATCH, .target = "/file.txt", .framing = .{ .length = 10 }, .fields = &.{ .{ "Host", "www.example.com" }, .{ "Content-Type", "application/example" }, .{ "If-Match", "\"e0023aa4e\"" }, .{ "Content-Length", "10" } }, .body = "cccccccccc" },
        } },
    },
    // stricter than llhttp: PURGE is not a method of std.http.Method: 501.
    .{
        .name = "method.md:217 REPORT request / PURGE request",
        .raw = "PURGE /file.txt HTTP/1.1\r\n" ++
            "Host: www.example.com\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.NotImplemented } },
    },
    // stricter than llhttp: SEARCH is not a method of std.http.Method: 501.
    .{
        .name = "method.md:245 REPORT request / SEARCH request",
        .raw = "SEARCH / HTTP/1.1\r\n" ++
            "Host: www.example.com\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.NotImplemented } },
    },
    // stricter than llhttp: LINK is not a method of std.http.Method: 501.
    .{
        .name = "method.md:273 REPORT request / LINK request",
        .raw = "LINK /images/my_dog.jpg HTTP/1.1\r\n" ++
            "Host: example.com\r\n" ++
            "Link: <http://example.com/profiles/joe>; rel=\"tag\"\r\n" ++
            "Link: <http://example.com/profiles/sally>; rel=\"tag\"\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.NotImplemented } },
    },
    // stricter than llhttp: UNLINK is not a method of std.http.Method: 501.
    .{
        .name = "method.md:311 REPORT request / LINK request",
        .raw = "UNLINK /images/my_dog.jpg HTTP/1.1\r\n" ++
            "Host: example.com\r\n" ++
            "Link: <http://example.com/profiles/sally>; rel=\"tag\"\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.NotImplemented } },
    },
    // stricter than llhttp: SOURCE is not a method of std.http.Method: 501.
    .{
        .name = "method.md:344 REPORT request / SOURCE request",
        .raw = "SOURCE /music/sweet/music HTTP/1.1\r\n" ++
            "Host: example.com\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.NotImplemented } },
    },
    // stricter than llhttp: SOURCE is not a method of std.http.Method: 501
    // (and ICE/1.0 is no HTTP version).
    .{
        .name = "method.md:372 REPORT request / SOURCE request with ICE",
        .raw = "SOURCE /music/sweet/music ICE/1.0\r\n" ++
            "Host: example.com\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.NotImplemented } },
    },
    // stricter than llhttp: RTSP/1.0 is not an HTTP version: 400.
    .{
        .name = "method.md:400 REPORT request / OPTIONS request with RTSP",
        .raw = "OPTIONS /music/sweet/music RTSP/1.0\r\n" ++
            "Host: example.com\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // stricter than llhttp: ANNOUNCE is not a method of std.http.Method: 501.
    .{
        .name = "method.md:430 REPORT request / ANNOUNCE request with RTSP",
        .raw = "ANNOUNCE /music/sweet/music RTSP/1.0\r\n" ++
            "Host: example.com\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.NotImplemented } },
    },
    // stricter than llhttp: PRI is not a method of std.http.Method: 501
    // (llhttp pauses there for the HTTP/2 preface).
    .{
        .name = "method.md:458 REPORT request / PRI request HTTP2",
        .raw = "PRI * HTTP/1.1\r\n" ++
            "\r\n" ++
            "SM\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.NotImplemented } },
    },
    .{
        .name = "method.md:482 REPORT request / QUERY request",
        .raw = "QUERY /contacts HTTP/1.1\r\n" ++
            "Host: example.org\r\n" ++
            "Content-Type: example/query\r\n" ++
            "Accept: text/csv\r\n" ++
            "Content-Length: 41\r\n" ++
            "\r\n" ++
            "select surname, givenname, email limit 10",
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .QUERY, .target = "/contacts", .framing = .{ .length = 41 }, .fields = &.{ .{ "Host", "example.org" }, .{ "Content-Type", "example/query" }, .{ "Accept", "text/csv" }, .{ "Content-Length", "41" } }, .body = "select surname, givenname, email limit 10" },
        } },
    },
    .{
        .name = "uri.md:4 Quotes in URI",
        .raw = "GET /with_\"lovely\"_quotes?foo=\\\"bar\\\" HTTP/1.1\r\n" ++
            "\r\n",
        .host_at = &.{48},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .GET, .target = "/with_\"lovely\"_quotes?foo=\\\"bar\\\"" },
        } },
    },
    .{
        .name = "uri.md:27 Query URL with question mark",
        .raw = "GET /test.cgi?foo=bar?baz HTTP/1.1\r\n" ++
            "\r\n",
        .host_at = &.{36},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .GET, .target = "/test.cgi?foo=bar?baz" },
        } },
    },
    .{
        .name = "uri.md:52 Host terminated by a query string",
        .raw = "GET http://hypnotoad.org?hail=all HTTP/1.1\r\n" ++
            "\r\n" ++
            "\r\n",
        .host_at = &.{44},
        .expect = .{ .end = .incomplete, .messages = &.{
            .{ .method = .GET, .target = "http://hypnotoad.org?hail=all" },
        } },
    },
    .{
        .name = "uri.md:75 `host:port` terminated by a query string",
        .raw = "GET http://hypnotoad.org:1234?hail=all HTTP/1.1\r\n" ++
            "\r\n",
        .host_at = &.{49},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .GET, .target = "http://hypnotoad.org:1234?hail=all" },
        } },
    },
    .{
        .name = "uri.md:98 Query URL with vertical bar character",
        .raw = "GET /test.cgi?query=| HTTP/1.1\r\n" ++
            "\r\n",
        .host_at = &.{32},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .GET, .target = "/test.cgi?query=|" },
        } },
    },
    .{
        .name = "uri.md:125 `host:port` terminated by a space",
        .raw = "GET http://hypnotoad.org:1234 HTTP/1.1\r\n" ++
            "\r\n",
        .host_at = &.{40},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .GET, .target = "http://hypnotoad.org:1234" },
        } },
    },
    .{
        .name = "uri.md:148 Disallow UTF-8 in URI path in strict mode",
        .raw = "GET /\xce\xb4\xc2\xb6/\xce\xb4t/pope?q=1#narf HTTP/1.1\r\n" ++
            "Host: github.com\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "uri.md:165 Fragment in URI",
        .raw = "GET /forums/1/topics/2375?page=1#posts-17408 HTTP/1.1\r\n" ++
            "\r\n",
        .host_at = &.{55},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .GET, .target = "/forums/1/topics/2375?page=1#posts-17408" },
        } },
    },
    // stricter than llhttp: the authority form of CONNECT is refused: 400 (no
    // tunnels).
    .{
        .name = "uri.md:188 Underscore in hostname",
        .raw = "CONNECT home_0.netscape.com:443 HTTP/1.0\r\n" ++
            "User-agent: Mozilla/1.1N\r\n" ++
            "Proxy-authorization: basic aGVsbG86d29ybGQ=\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // stricter than llhttp: user info in an absolute target is refused, as
    // in Host (RFC 9110 §4.2.4): 400.
    .{
        .name = "uri.md:222 `host:port` and basic auth",
        .raw = "GET http://a%12:b!&*$@hypnotoad.org:1234/toto HTTP/1.1\r\n" ++
            "\r\n",
        .host_at = &.{56},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "uri.md:245 Space in URI",
        .raw = "GET /foo bar/ HTTP/1.1\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "connection.md:6 `keep-alive` / Setting flag",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n",
        .host_at = &.{19},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .PUT, .target = "/url", .fields = &.{.{ "Connection", "keep-alive" }} },
        } },
    },
    .{
        .name = "connection.md:34 `keep-alive` / Restarting when keep-alive is explicitly",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n" ++
            "PUT /url HTTP/1.1\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n",
        .host_at = &.{ 19, 64 },
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .PUT, .target = "/url", .fields = &.{.{ "Connection", "keep-alive" }} },
            .{ .method = .PUT, .target = "/url", .fields = &.{.{ "Connection", "keep-alive" }} },
        } },
    },
    .{
        .name = "connection.md:81 `keep-alive` / No restart when keep-alive is off (1.0)",
        .raw = "PUT /url HTTP/1.0\r\n" ++
            "\r\n" ++
            "PUT /url HTTP/1.1\r\n" ++
            "\r\n",
        .expect = .{ .end = .closed, .messages = &.{
            .{ .method = .PUT, .target = "/url", .version = .http10, .keep_alive = false },
        } },
    },
    // stricter than llhttp (lenient keep-alive): HTTP/1.0 without keep-alive
    // closes the connection after its response, so the second request is never
    // read.
    .{
        .name = "connection.md:107 `keep-alive` / Resetting flags when keep-alive is off (1.0, lenient)",
        .raw = "PUT /url HTTP/1.0\r\n" ++
            "Content-Length: 0\r\n" ++
            "\r\n" ++
            "PUT /url HTTP/1.1\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n",
        .expect = .{ .end = .closed, .messages = &.{
            .{ .method = .PUT, .target = "/url", .version = .http10, .keep_alive = false, .framing = .{ .length = 0 }, .fields = &.{.{ "Content-Length", "0" }} },
        } },
    },
    .{
        .name = "connection.md:156 `keep-alive` / CRLF between requests, implicit `keep-alive`",
        .raw = "POST / HTTP/1.1\r\n" ++
            "Host: www.example.com\r\n" ++
            "Content-Type: application/x-www-form-urlencoded\r\n" ++
            "Content-Length: 4\r\n" ++
            "\r\n" ++
            "q=42\r\n" ++
            "\r\n" ++
            "GET / HTTP/1.1",
        .expect = .{ .end = .incomplete, .messages = &.{
            .{ .method = .POST, .target = "/", .framing = .{ .length = 4 }, .fields = &.{ .{ "Host", "www.example.com" }, .{ "Content-Type", "application/x-www-form-urlencoded" }, .{ "Content-Length", "4" } }, .body = "q=42" },
        } },
    },
    .{
        .name = "connection.md:208 `keep-alive` / Not treating `\\r` as `-`",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Connection: keep\ralive\r\n" ++
            "\r\n",
        .host_at = &.{19},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "connection.md:236 `close` / Setting flag on `close`",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
        .host_at = &.{19},
        .expect = .{ .end = .closed, .messages = &.{
            .{ .method = .PUT, .target = "/url", .keep_alive = false, .fields = &.{.{ "Connection", "close" }} },
        } },
    },
    .{
        .name = "connection.md:264 `close` / Setting flag on `close` followed by tab",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Connection: close\t\r\n" ++
            "\r\n",
        .host_at = &.{19},
        .expect = .{ .end = .closed, .messages = &.{
            .{ .method = .PUT, .target = "/url", .keep_alive = false, .fields = &.{.{ "Connection", "close" }} },
        } },
    },
    .{
        .name = "connection.md:292 `close` / CRLF between requests, explicit `close`",
        .raw = "POST / HTTP/1.1\r\n" ++
            "Host: www.example.com\r\n" ++
            "Content-Type: application/x-www-form-urlencoded\r\n" ++
            "Content-Length: 4\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "q=42\r\n" ++
            "\r\n" ++
            "GET / HTTP/1.1",
        .expect = .{ .end = .closed, .messages = &.{
            .{ .method = .POST, .target = "/", .keep_alive = false, .framing = .{ .length = 4 }, .fields = &.{ .{ "Host", "www.example.com" }, .{ "Content-Type", "application/x-www-form-urlencoded" }, .{ "Content-Length", "4" }, .{ "Connection", "close" } }, .body = "q=42" },
        } },
    },
    .{
        .name = "connection.md:342 `close` / CRLF between requests, explicit `close` followed by tab",
        .raw = "POST / HTTP/1.1\r\n" ++
            "Host: www.example.com\r\n" ++
            "Content-Type: application/x-www-form-urlencoded\r\n" ++
            "Content-Length: 4\r\n" ++
            "Connection: close\t\r\n" ++
            "\r\n" ++
            "q=42\r\n" ++
            "\r\n" ++
            "GET / HTTP/1.1",
        .expect = .{ .end = .closed, .messages = &.{
            .{ .method = .POST, .target = "/", .keep_alive = false, .framing = .{ .length = 4 }, .fields = &.{ .{ "Host", "www.example.com" }, .{ "Content-Type", "application/x-www-form-urlencoded" }, .{ "Content-Length", "4" }, .{ "Connection", "close" } }, .body = "q=42" },
        } },
    },
    // stricter than llhttp (lenient keep-alive), which reads the GET after
    // `Connection: close`: we never read past it.
    .{
        .name = "connection.md:392 `close` / CRLF between requests, explicit `close` (lenient)",
        .raw = "POST / HTTP/1.1\r\n" ++
            "Host: www.example.com\r\n" ++
            "Content-Type: application/x-www-form-urlencoded\r\n" ++
            "Content-Length: 4\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "q=42\r\n" ++
            "\r\n" ++
            "GET / HTTP/1.1",
        .expect = .{ .end = .closed, .messages = &.{
            .{ .method = .POST, .target = "/", .keep_alive = false, .framing = .{ .length = 4 }, .fields = &.{ .{ "Host", "www.example.com" }, .{ "Content-Type", "application/x-www-form-urlencoded" }, .{ "Content-Length", "4" }, .{ "Connection", "close" } }, .body = "q=42" },
        } },
    },
    .{
        .name = "connection.md:453 Parsing multiple tokens / Sample",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Connection: close, token, upgrade, token, keep-alive\r\n" ++
            "\r\n",
        .host_at = &.{19},
        .expect = .{ .end = .closed, .messages = &.{
            .{ .method = .PUT, .target = "/url", .keep_alive = false, .fields = &.{.{ "Connection", "close, token, upgrade, token, keep-alive" }} },
        } },
    },
    // stricter than llhttp (lenient headers): obs-fold is refused: 400.
    .{
        .name = "connection.md:481 Parsing multiple tokens / Multiple tokens with folding",
        .raw = "GET /demo HTTP/1.1\r\n" ++
            "Host: example.com\r\n" ++
            "Connection: Something,\r\n" ++
            " Upgrade, ,Keep-Alive\r\n" ++
            "Sec-WebSocket-Key2: 12998 5 Y3 1  .P00\r\n" ++
            "Sec-WebSocket-Protocol: sample\r\n" ++
            "Upgrade: WebSocket\r\n" ++
            "Sec-WebSocket-Key1: 4 @1  46546xW%0l 1 5\r\n" ++
            "Origin: http://example.com\r\n" ++
            "\r\n" ++
            "Hot diggity dogg",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // we don't switch protocols (no upgrades in v1): the request is served as
    // it is, and the bytes after it start the next request, where `Hot` is no
    // method: 501. llhttp pauses at the upgrade.
    .{
        .name = "connection.md:542 Parsing multiple tokens / Multiple tokens with folding and LWS",
        .raw = "GET /demo HTTP/1.1\r\n" ++
            "Connection: keep-alive, upgrade\r\n" ++
            "Upgrade: WebSocket\r\n" ++
            "\r\n" ++
            "Hot diggity dogg",
        .host_at = &.{20},
        .expect = .{ .end = .{ .head = error.NotImplemented }, .messages = &.{
            .{ .method = .GET, .target = "/demo", .fields = &.{ .{ "Connection", "keep-alive, upgrade" }, .{ "Upgrade", "WebSocket" } } },
        } },
    },
    // stricter than llhttp (lenient headers): obs-fold is refused: 400.
    .{
        .name = "connection.md:576 Parsing multiple tokens / Multiple tokens with folding, LWS, and CRLF",
        .raw = "GET /demo HTTP/1.1\r\n" ++
            "Connection: keep-alive, \r\n" ++
            " upgrade\r\n" ++
            "Upgrade: WebSocket\r\n" ++
            "\r\n" ++
            "Hot diggity dogg",
        .host_at = &.{20},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "connection.md:611 Parsing multiple tokens / Invalid whitespace token with `Connection` header field",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Connection : upgrade\r\n" ++
            "Content-Length: 4\r\n" ++
            "Upgrade: ws\r\n" ++
            "\r\n" ++
            "abcdefgh",
        .host_at = &.{19},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // stricter than llhttp (lenient headers): whitespace before `:` is
    // refused: 400.
    .{
        .name = "connection.md:637 Parsing multiple tokens / Invalid whitespace token with `Connection` header field (lenient)",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Connection : upgrade\r\n" ++
            "Content-Length: 4\r\n" ++
            "Upgrade: ws\r\n" ++
            "\r\n" ++
            "abcdefgh",
        .host_at = &.{19},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // we don't switch protocols (no upgrades in v1): the request is served as
    // it is. llhttp pauses at the upgrade.
    .{
        .name = "connection.md:679 `upgrade` / Setting a flag and pausing",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Connection: upgrade\r\n" ++
            "Upgrade: ws\r\n" ++
            "\r\n",
        .host_at = &.{19},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .PUT, .target = "/url", .fields = &.{ .{ "Connection", "upgrade" }, .{ "Upgrade", "ws" } } },
        } },
    },
    // we don't switch protocols (no upgrades in v1): the request is served as
    // it is, and the bytes after it start the next request, still incomplete.
    // llhttp pauses at the upgrade.
    .{
        .name = "connection.md:713 `upgrade` / Emitting part of body and pausing",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Connection: upgrade\r\n" ++
            "Content-Length: 4\r\n" ++
            "Upgrade: ws\r\n" ++
            "\r\n" ++
            "abcdefgh",
        .host_at = &.{19},
        .expect = .{ .end = .incomplete, .messages = &.{
            .{ .method = .PUT, .target = "/url", .framing = .{ .length = 4 }, .fields = &.{ .{ "Connection", "upgrade" }, .{ "Content-Length", "4" }, .{ "Upgrade", "ws" } }, .body = "abcd" },
        } },
    },
    // we don't switch protocols (no upgrades in v1): the request is served as
    // it is, and the bytes after it start the next request, where `Hot` is no
    // method: 501. llhttp pauses at the upgrade.
    .{
        .name = "connection.md:753 `upgrade` / Upgrade GET request",
        .raw = "GET /demo HTTP/1.1\r\n" ++
            "Host: example.com\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key2: 12998 5 Y3 1  .P00\r\n" ++
            "Sec-WebSocket-Protocol: sample\r\n" ++
            "Upgrade: WebSocket\r\n" ++
            "Sec-WebSocket-Key1: 4 @1  46546xW%0l 1 5\r\n" ++
            "Origin: http://example.com\r\n" ++
            "\r\n" ++
            "Hot diggity dogg",
        .expect = .{ .end = .{ .head = error.NotImplemented }, .messages = &.{
            .{ .method = .GET, .target = "/demo", .fields = &.{ .{ "Host", "example.com" }, .{ "Connection", "Upgrade" }, .{ "Sec-WebSocket-Key2", "12998 5 Y3 1  .P00" }, .{ "Sec-WebSocket-Protocol", "sample" }, .{ "Upgrade", "WebSocket" }, .{ "Sec-WebSocket-Key1", "4 @1  46546xW%0l 1 5" }, .{ "Origin", "http://example.com" } } },
        } },
    },
    // we don't switch protocols (no upgrades in v1): the request is served as
    // it is, and the bytes after it start the next request, where `Hot` is no
    // method: 501. llhttp pauses at the upgrade.
    .{
        .name = "connection.md:812 `upgrade` / Upgrade POST request",
        .raw = "POST /demo HTTP/1.1\r\n" ++
            "Host: example.com\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Upgrade: HTTP/2.0\r\n" ++
            "Content-Length: 15\r\n" ++
            "\r\n" ++
            "sweet post bodyHot diggity dogg",
        .expect = .{ .end = .{ .head = error.NotImplemented }, .messages = &.{
            .{ .method = .POST, .target = "/demo", .framing = .{ .length = 15 }, .fields = &.{ .{ "Host", "example.com" }, .{ "Connection", "Upgrade" }, .{ "Upgrade", "HTTP/2.0" }, .{ "Content-Length", "15" } }, .body = "sweet post body" },
        } },
    },
    .{
        .name = "content-length.md:4 `Content-Length` with zeroes",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Content-Length: 003\r\n" ++
            "\r\n" ++
            "abc",
        .host_at = &.{19},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .PUT, .target = "/url", .framing = .{ .length = 3 }, .fields = &.{.{ "Content-Length", "003" }}, .body = "abc" },
        } },
    },
    .{
        .name = "content-length.md:33 `Content-Length` with follow-up headers",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Content-Length: 003\r\n" ++
            "Ohai: world\r\n" ++
            "\r\n" ++
            "abc",
        .host_at = &.{19},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .PUT, .target = "/url", .framing = .{ .length = 3 }, .fields = &.{ .{ "Content-Length", "003" }, .{ "Ohai", "world" } }, .body = "abc" },
        } },
    },
    // llhttp refuses the length as it reads it. We check it once the head is
    // complete (cases.zig: "Content-Length over u64"), and this head is cut
    // before its end: still waiting.
    .{
        .name = "content-length.md:75 Error on `Content-Length` overflow",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Content-Length: 1000000000000000000000\r\n",
        .expect = .{ .end = .incomplete },
    },
    // llhttp refuses the second length as it reads it. We check the lengths
    // once the head is complete (cases.zig: "two Content-Length fields that
    // differ"), and this head is cut before its end: still waiting.
    .{
        .name = "content-length.md:100 Error on duplicate `Content-Length`",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Content-Length: 1\r\n" ++
            "Content-Length: 2\r\n",
        .expect = .{ .end = .incomplete },
    },
    .{
        .name = "content-length.md:129 Error on simultaneous `Content-Length` and `Transfer-Encoding: identity`",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Content-Length: 1\r\n" ++
            "Transfer-Encoding: identity\r\n" ++
            "\r\n",
        .host_at = &.{19},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "content-length.md:159 Invalid whitespace token with `Content-Length` header field",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Connection: upgrade\r\n" ++
            "Content-Length : 4\r\n" ++
            "Upgrade: ws\r\n" ++
            "\r\n" ++
            "abcdefgh",
        .host_at = &.{19},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // stricter than llhttp (lenient headers): whitespace before `:` is
    // refused: 400.
    .{
        .name = "content-length.md:189 Invalid whitespace token with `Content-Length` header field (lenient)",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Connection: upgrade\r\n" ++
            "Content-Length : 4\r\n" ++
            "Upgrade: ws\r\n" ++
            "\r\n" ++
            "abcdefgh",
        .host_at = &.{19},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // stricter than llhttp (lenient chunked length): Content-Length with
    // Transfer-Encoding is refused: 400.
    .{
        .name = "content-length.md:229 No error on simultaneous `Content-Length` and `Transfer-Encoding: identity` (lenient)",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Content-Length: 1\r\n" ++
            "Transfer-Encoding: identity\r\n" ++
            "\r\n",
        .host_at = &.{19},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "content-length.md:261 Funky `Content-Length` with body",
        .raw = "GET /get_funky_content_length_body_hello HTTP/1.0\r\n" ++
            "conTENT-Length: 5\r\n" ++
            "\r\n" ++
            "HELLO",
        .expect = .{ .end = .closed, .messages = &.{
            .{ .method = .GET, .target = "/get_funky_content_length_body_hello", .version = .http10, .keep_alive = false, .framing = .{ .length = 5 }, .fields = &.{.{ "conTENT-Length", "5" }}, .body = "HELLO" },
        } },
    },
    .{
        .name = "content-length.md:290 Spaces in `Content-Length` (surrounding)",
        .raw = "POST / HTTP/1.1\r\n" ++
            "Content-Length:  42 \r\n" ++
            "\r\n",
        .host_at = &.{17},
        .expect = .{ .end = .incomplete, .messages = &.{
            .{ .method = .POST, .target = "/", .framing = .{ .length = 42 }, .fields = &.{.{ "Content-Length", "42" }} },
        } },
    },
    .{
        .name = "content-length.md:317 Spaces in `Content-Length` (surrounding) / Tabs in `Content-Length` (surrounding)",
        .raw = "POST / HTTP/1.1\r\n" ++
            "Content-Length:\t42\t  \r\n" ++
            "\r\n",
        .host_at = &.{17},
        .expect = .{ .end = .incomplete, .messages = &.{
            .{ .method = .POST, .target = "/", .framing = .{ .length = 42 }, .fields = &.{.{ "Content-Length", "42" }} },
        } },
    },
    .{
        .name = "content-length.md:344 Spaces in `Content-Length` (surrounding) / Spaces in `Content-Length` #2",
        .raw = "POST / HTTP/1.1\r\n" ++
            "Content-Length: 4 2\r\n" ++
            "\r\n",
        .host_at = &.{17},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "content-length.md:370 Spaces in `Content-Length` (surrounding) / Spaces in `Content-Length` #3",
        .raw = "POST / HTTP/1.1\r\n" ++
            "Content-Length: 13 37\r\n" ++
            "\r\n",
        .host_at = &.{17},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "content-length.md:396 Spaces in `Content-Length` (surrounding) / Empty `Content-Length`",
        .raw = "POST / HTTP/1.1\r\n" ++
            "Content-Length:\r\n" ++
            "\r\n",
        .host_at = &.{17},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "content-length.md:421 `Content-Length` with CR instead of dash",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Content\rLength: 003\r\n" ++
            "\r\n" ++
            "abc",
        .host_at = &.{19},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // llhttp's harness skips the body here (skipBody, meant for the response
    // to a HEAD). The Content-Length of a request always counts: the second
    // request is the body of the first one.
    .{
        .name = "content-length.md:444 Content-Length reset when no body is received",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Content-Length: 123\r\n" ++
            "\r\n" ++
            "POST /url HTTP/1.1\r\n" ++
            "Content-Length: 456\r\n" ++
            "\r\n",
        .host_at = &.{ 19, 62 },
        .expect = .{ .end = .incomplete, .messages = &.{
            .{ .method = .PUT, .target = "/url", .framing = .{ .length = 123 }, .fields = &.{.{ "Content-Length", "123" }}, .body = "POST /url HTTP/1.1\r\nHost: llhttp.test\r\nContent-Length: 456\r\n\r\n" },
        } },
    },
    .{
        .name = "content-length.md:493 Missing CRLF-CRLF before body",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Content-Length: 3\r\n" ++
            "\rabc",
        .host_at = &.{19},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // stricter than llhttp (lenient optional LF after CR): a bare CR is
    // refused: 400.
    .{
        .name = "content-length.md:519 Missing CRLF-CRLF before body (lenient)",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Content-Length: 3\r\n" ++
            "\rabc",
        .host_at = &.{19},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "transfer-encoding.md:4 Empty `Transfer-Encoding` with `Content-Length`",
        .raw = "POST /first HTTP/1.1\r\n" ++
            "Transfer-Encoding:\r\n" ++
            "Content-Length: 5\r\n" ++
            "\r\n" ++
            "hello",
        .host_at = &.{22},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "transfer-encoding.md:32 `chunked` / Parsing and setting flag",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n",
        .host_at = &.{19},
        .expect = .{ .end = .incomplete, .messages = &.{
            .{ .method = .PUT, .target = "/url", .framing = .chunked, .fields = &.{.{ "Transfer-Encoding", "chunked" }} },
        } },
    },
    .{
        .name = "transfer-encoding.md:59 `chunked` / Parse chunks with lowercase size",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "a\r\n" ++
            "0123456789\r\n" ++
            "0\r\n" ++
            "\r\n",
        .host_at = &.{19},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .PUT, .target = "/url", .framing = .chunked, .fields = &.{.{ "Transfer-Encoding", "chunked" }}, .body = "0123456789" },
        } },
    },
    .{
        .name = "transfer-encoding.md:96 `chunked` / Parse chunks with uppercase size",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "A\r\n" ++
            "0123456789\r\n" ++
            "0\r\n" ++
            "\r\n",
        .host_at = &.{19},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .PUT, .target = "/url", .framing = .chunked, .fields = &.{.{ "Transfer-Encoding", "chunked" }}, .body = "0123456789" },
        } },
    },
    .{
        .name = "transfer-encoding.md:133 `chunked` / POST with `Transfer-Encoding: chunked`",
        .raw = "POST /post_chunked_all_your_base HTTP/1.1\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "1e\r\n" ++
            "all your base are belong to us\r\n" ++
            "0\r\n" ++
            "\r\n",
        .host_at = &.{43},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .POST, .target = "/post_chunked_all_your_base", .framing = .chunked, .fields = &.{.{ "Transfer-Encoding", "chunked" }}, .body = "all your base are belong to us" },
        } },
    },
    .{
        .name = "transfer-encoding.md:170 `chunked` / Two chunks and triple zero prefixed end chunk",
        .raw = "POST /two_chunks_mult_zero_end HTTP/1.1\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "5\r\n" ++
            "hello\r\n" ++
            "6\r\n" ++
            " world\r\n" ++
            "000\r\n" ++
            "\r\n",
        .host_at = &.{41},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .POST, .target = "/two_chunks_mult_zero_end", .framing = .chunked, .fields = &.{.{ "Transfer-Encoding", "chunked" }}, .body = "hello world" },
        } },
    },
    .{
        .name = "transfer-encoding.md:212 `chunked` / Trailing headers",
        .raw = "POST /chunked_w_trailing_headers HTTP/1.1\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "5\r\n" ++
            "hello\r\n" ++
            "6\r\n" ++
            " world\r\n" ++
            "0\r\n" ++
            "Vary: *\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "\r\n",
        .host_at = &.{43},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .POST, .target = "/chunked_w_trailing_headers", .framing = .chunked, .fields = &.{.{ "Transfer-Encoding", "chunked" }}, .body = "hello world" },
        } },
    },
    .{
        .name = "transfer-encoding.md:264 `chunked` / Chunk extensions",
        .raw = "POST /chunked_w_unicorns_after_length HTTP/1.1\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "5;ilovew3;somuchlove=aretheseparametersfor;another=withvalue\r\n" ++
            "hello\r\n" ++
            "6;blahblah;blah\r\n" ++
            " world\r\n" ++
            "0\r\n",
        .host_at = &.{48},
        .expect = .{ .end = .incomplete, .messages = &.{
            .{ .method = .POST, .target = "/chunked_w_unicorns_after_length", .framing = .chunked, .fields = &.{.{ "Transfer-Encoding", "chunked" }}, .body = "hello world" },
        } },
    },
    .{
        .name = "transfer-encoding.md:317 `chunked` / No semicolon before chunk extensions",
        .raw = "POST /chunked_w_unicorns_after_length HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "Transfer-encoding: chunked\r\n" ++
            "\r\n" ++
            "2 erfrferferf\r\n" ++
            "aa\r\n" ++
            "0 rrrr\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .body = error.BadChunk }, .messages = &.{
            .{ .method = .POST, .target = "/chunked_w_unicorns_after_length", .framing = .chunked, .fields = &.{ .{ "Host", "localhost" }, .{ "Transfer-encoding", "chunked" } } },
        } },
    },
    .{
        .name = "transfer-encoding.md:354 `chunked` / No extension after semicolon",
        .raw = "POST /chunked_w_unicorns_after_length HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "Transfer-encoding: chunked\r\n" ++
            "\r\n" ++
            "2;\r\n" ++
            "aa\r\n" ++
            "0\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .body = error.BadChunk }, .messages = &.{
            .{ .method = .POST, .target = "/chunked_w_unicorns_after_length", .framing = .chunked, .fields = &.{ .{ "Host", "localhost" }, .{ "Transfer-encoding", "chunked" } } },
        } },
    },
    .{
        .name = "transfer-encoding.md:392 `chunked` / Chunk extensions quoting",
        .raw = "POST /chunked_w_unicorns_after_length HTTP/1.1\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "5;ilovew3=\"I \\\"love\\\"; \\\\extensions\\\\\";somuchlove=\"aretheseparametersfor\";blah;foo=bar\r\n" ++
            "hello\r\n" ++
            "6;blahblah;blah\r\n" ++
            " world\r\n" ++
            "0\r\n",
        .host_at = &.{48},
        .expect = .{ .end = .incomplete, .messages = &.{
            .{ .method = .POST, .target = "/chunked_w_unicorns_after_length", .framing = .chunked, .fields = &.{.{ "Transfer-Encoding", "chunked" }}, .body = "hello world" },
        } },
    },
    .{
        .name = "transfer-encoding.md:450 `chunked` / Unbalanced chunk extensions quoting",
        .raw = "POST /chunked_w_unicorns_after_length HTTP/1.1\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "5;ilovew3=\"abc\";somuchlove=\"def; ghi\r\n" ++
            "hello\r\n" ++
            "6;blahblah;blah\r\n" ++
            " world\r\n" ++
            "0\r\n",
        .host_at = &.{48},
        .expect = .{ .end = .{ .body = error.BadChunk }, .messages = &.{
            .{ .method = .POST, .target = "/chunked_w_unicorns_after_length", .framing = .chunked, .fields = &.{.{ "Transfer-Encoding", "chunked" }} },
        } },
    },
    // llhttp refuses it too, after the head; for us a coding other than
    // chunked is 501 at the head.
    .{
        .name = "transfer-encoding.md:490 Ignoring `pigeons`",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Transfer-Encoding: pigeons\r\n" ++
            "\r\n",
        .host_at = &.{19},
        .expect = .{ .end = .{ .head = error.NotImplemented } },
    },
    .{
        .name = "transfer-encoding.md:521 POST with `Transfer-Encoding` and `Content-Length`",
        .raw = "POST /post_identity_body_world?q=search#hey HTTP/1.1\r\n" ++
            "Accept: */*\r\n" ++
            "Transfer-Encoding: identity\r\n" ++
            "Content-Length: 5\r\n" ++
            "\r\n" ++
            "World",
        .host_at = &.{54},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // stricter than llhttp (lenient chunked length): Content-Length with
    // Transfer-Encoding is refused: 400.
    .{
        .name = "transfer-encoding.md:556 POST with `Transfer-Encoding` and `Content-Length` (lenient)",
        .raw = "POST /post_identity_body_world?q=search#hey HTTP/1.1\r\n" ++
            "Accept: */*\r\n" ++
            "Transfer-Encoding: identity\r\n" ++
            "Content-Length: 1\r\n" ++
            "\r\n" ++
            "World",
        .host_at = &.{54},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "transfer-encoding.md:600 POST with empty `Transfer-Encoding` and `Content-Length` (lenient)",
        .raw = "POST / HTTP/1.1\r\n" ++
            "Host: foo\r\n" ++
            "Content-Length: 10\r\n" ++
            "Transfer-Encoding:\r\n" ++
            "Transfer-Encoding:\r\n" ++
            "Transfer-Encoding:\r\n" ++
            "\r\n" ++
            "2\r\n" ++
            "AA\r\n" ++
            "0",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // llhttp refuses it too (400); for us anything but chunked alone is 501.
    .{
        .name = "transfer-encoding.md:639 POST with `chunked` before other transfer coding names",
        .raw = "POST /post_identity_body_world?q=search#hey HTTP/1.1\r\n" ++
            "Accept: */*\r\n" ++
            "Transfer-Encoding: chunked, deflate\r\n" ++
            "\r\n" ++
            "World",
        .host_at = &.{54},
        .expect = .{ .end = .{ .head = error.NotImplemented } },
    },
    // llhttp refuses it too (400); for us anything but chunked alone is 501.
    .{
        .name = "transfer-encoding.md:670 POST with `chunked` and duplicate transfer-encoding",
        .raw = "POST /post_identity_body_world?q=search#hey HTTP/1.1\r\n" ++
            "Accept: */*\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "Transfer-Encoding: deflate\r\n" ++
            "\r\n" ++
            "World",
        .host_at = &.{54},
        .expect = .{ .end = .{ .head = error.NotImplemented } },
    },
    // stricter than llhttp (lenient transfer-encoding): anything but chunked
    // alone is 501.
    .{
        .name = "transfer-encoding.md:706 POST with `chunked` before other transfer-coding (lenient)",
        .raw = "POST /post_identity_body_world?q=search#hey HTTP/1.1\r\n" ++
            "Accept: */*\r\n" ++
            "Transfer-Encoding: chunked, deflate\r\n" ++
            "\r\n" ++
            "World",
        .host_at = &.{54},
        .expect = .{ .end = .{ .head = error.NotImplemented } },
    },
    // stricter than llhttp (lenient transfer-encoding): anything but chunked
    // alone is 501.
    .{
        .name = "transfer-encoding.md:739 POST with `chunked` and duplicate transfer-encoding (lenient)",
        .raw = "POST /post_identity_body_world?q=search#hey HTTP/1.1\r\n" ++
            "Accept: */*\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "Transfer-Encoding: deflate\r\n" ++
            "\r\n" ++
            "World",
        .host_at = &.{54},
        .expect = .{ .end = .{ .head = error.NotImplemented } },
    },
    // stricter than llhttp: deflate before chunked is a coding we don't
    // decode: 501.
    .{
        .name = "transfer-encoding.md:777 POST with `chunked` as last transfer-encoding",
        .raw = "POST /post_identity_body_world?q=search#hey HTTP/1.1\r\n" ++
            "Accept: */*\r\n" ++
            "Transfer-Encoding: deflate, chunked\r\n" ++
            "\r\n" ++
            "5\r\n" ++
            "World\r\n" ++
            "0\r\n" ++
            "\r\n",
        .host_at = &.{54},
        .expect = .{ .end = .{ .head = error.NotImplemented } },
    },
    // stricter than llhttp: deflate before chunked is a coding we don't
    // decode: 501.
    .{
        .name = "transfer-encoding.md:819 POST with `chunked` as last transfer-encoding (multiple headers)",
        .raw = "POST /post_identity_body_world?q=search#hey HTTP/1.1\r\n" ++
            "Accept: */*\r\n" ++
            "Transfer-Encoding: deflate\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "5\r\n" ++
            "World\r\n" ++
            "0\r\n" ++
            "\r\n",
        .host_at = &.{54},
        .expect = .{ .end = .{ .head = error.NotImplemented } },
    },
    // llhttp refuses it too, after the head; for us a coding other than
    // chunked is 501 at the head.
    .{
        .name = "transfer-encoding.md:866 POST with `chunkedchunked` as transfer-encoding",
        .raw = "POST /post_identity_body_world?q=search#hey HTTP/1.1\r\n" ++
            "Accept: */*\r\n" ++
            "Transfer-Encoding: chunkedchunked\r\n" ++
            "\r\n" ++
            "5\r\n" ++
            "World\r\n" ++
            "0\r\n" ++
            "\r\n",
        .host_at = &.{54},
        .expect = .{ .end = .{ .head = error.NotImplemented } },
    },
    .{
        .name = "transfer-encoding.md:903 Missing last-chunk",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "3\r\n" ++
            "foo\r\n" ++
            "\r\n",
        .host_at = &.{19},
        .expect = .{ .end = .{ .body = error.BadChunk }, .messages = &.{
            .{ .method = .PUT, .target = "/url", .framing = .chunked, .fields = &.{.{ "Transfer-Encoding", "chunked" }}, .body = "foo" },
        } },
    },
    .{
        .name = "transfer-encoding.md:937 Validate chunk parameters",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "3 \n  \r\n" ++
            "foo\r\n" ++
            "\r\n",
        .host_at = &.{19},
        .expect = .{ .end = .{ .body = error.BadChunk }, .messages = &.{
            .{ .method = .PUT, .target = "/url", .framing = .chunked, .fields = &.{.{ "Transfer-Encoding", "chunked" }} },
        } },
    },
    // stricter than llhttp (lenient headers): obs-fold is refused: 400.
    .{
        .name = "transfer-encoding.md:968 Invalid OBS fold after chunked value",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "  abc\r\n" ++
            "\r\n" ++
            "5\r\n" ++
            "World\r\n" ++
            "0\r\n" ++
            "\r\n",
        .host_at = &.{19},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "transfer-encoding.md:1002 Invalid OBS fold after chunked value / Chunk header not terminated by CRLF",
        .raw = "GET / HTTP/1.1\r\n" ++
            "Host: a\r\n" ++
            "Connection: close \r\n" ++
            "Transfer-Encoding: chunked \r\n" ++
            "\r\n" ++
            "5\r\r;ABCD\r\n" ++
            "34\r\n" ++
            "E\r\n" ++
            "0\r\n" ++
            "\r\n" ++
            "GET / HTTP/1.1 \r\n" ++
            "Host: a\r\n" ++
            "Content-Length: 5\r\n" ++
            "\r\n" ++
            "0\r\n",
        .expect = .{ .end = .{ .body = error.BadChunk }, .messages = &.{
            .{ .method = .GET, .target = "/", .keep_alive = false, .framing = .chunked, .fields = &.{ .{ "Host", "a" }, .{ "Connection", "close" }, .{ "Transfer-Encoding", "chunked" } } },
        } },
    },
    // stricter than llhttp (lenient optional LF after CR): the size line
    // `6\r\r` has a bare CR.
    .{
        .name = "transfer-encoding.md:1051 Invalid OBS fold after chunked value / Chunk header not terminated by CRLF (lenient)",
        .raw = "GET / HTTP/1.1\r\n" ++
            "Host: a\r\n" ++
            "Connection: close \r\n" ++
            "Transfer-Encoding: chunked \r\n" ++
            "\r\n" ++
            "6\r\r;ABCD\r\n" ++
            "33\r\n" ++
            "E\r\n" ++
            "0\r\n" ++
            "\r\n" ++
            "GET / HTTP/1.1 \r\n" ++
            "Host: a\r\n" ++
            "Content-Length: 5\r\n" ++
            "0\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .body = error.BadChunk }, .messages = &.{
            .{ .method = .GET, .target = "/", .keep_alive = false, .framing = .chunked, .fields = &.{ .{ "Host", "a" }, .{ "Connection", "close" }, .{ "Transfer-Encoding", "chunked" } } },
        } },
    },
    .{
        .name = "transfer-encoding.md:1123 Invalid OBS fold after chunked value / Chunk data not terminated by CRLF",
        .raw = "GET / HTTP/1.1\r\n" ++
            "Host: a\r\n" ++
            "Connection: close \r\n" ++
            "Transfer-Encoding: chunked \r\n" ++
            "\r\n" ++
            "5\r\n" ++
            "ABCDE0\r\n",
        .expect = .{ .end = .{ .body = error.BadChunk }, .messages = &.{
            .{ .method = .GET, .target = "/", .keep_alive = false, .framing = .chunked, .fields = &.{ .{ "Host", "a" }, .{ "Connection", "close" }, .{ "Transfer-Encoding", "chunked" } }, .body = "ABCDE" },
        } },
    },
    // stricter than llhttp (lenient optional CRLF after chunk): the data of a
    // chunk must be followed by CRLF.
    .{
        .name = "transfer-encoding.md:1166 Invalid OBS fold after chunked value / Chunk data not terminated by CRLF (lenient)",
        .raw = "GET / HTTP/1.1\r\n" ++
            "Host: a\r\n" ++
            "Connection: close \r\n" ++
            "Transfer-Encoding: chunked \r\n" ++
            "\r\n" ++
            "5\r\n" ++
            "ABCDE0\r\n",
        .expect = .{ .end = .{ .body = error.BadChunk }, .messages = &.{
            .{ .method = .GET, .target = "/", .keep_alive = false, .framing = .chunked, .fields = &.{ .{ "Host", "a" }, .{ "Connection", "close" }, .{ "Transfer-Encoding", "chunked" } }, .body = "ABCDE" },
        } },
    },
    .{
        .name = "transfer-encoding.md:1210 Space after chunk header",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "a \r\n" ++
            "0123456789\r\n" ++
            "0\r\n" ++
            "\r\n",
        .host_at = &.{19},
        .expect = .{ .end = .{ .body = error.BadChunk }, .messages = &.{
            .{ .method = .PUT, .target = "/url", .framing = .chunked, .fields = &.{.{ "Transfer-Encoding", "chunked" }} },
        } },
    },
    // stricter than llhttp (lenient spaces after chunk size): nothing may
    // follow the size but `;` or CRLF.
    .{
        .name = "transfer-encoding.md:1241 Space after chunk header (lenient)",
        .raw = "PUT /url HTTP/1.1\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "a \r\n" ++
            "0123456789\r\n" ++
            "0\r\n" ++
            "\r\n",
        .host_at = &.{19},
        .expect = .{ .end = .{ .body = error.BadChunk }, .messages = &.{
            .{ .method = .PUT, .target = "/url", .framing = .chunked, .fields = &.{.{ "Transfer-Encoding", "chunked" }} },
        } },
    },
    .{
        .name = "invalid.md:4 ICE protocol and GET method",
        .raw = "GET /music/sweet/music ICE/1.0\r\n" ++
            "Host: example.com\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "invalid.md:25 ICE protocol and GET method / ICE protocol, but not really",
        .raw = "GET /music/sweet/music IHTTP/1.0\r\n" ++
            "Host: example.com\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "invalid.md:45 ICE protocol and GET method / RTSP protocol and PUT method",
        .raw = "PUT /music/sweet/music RTSP/1.0\r\n" ++
            "Host: example.com\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // llhttp refuses it too; for us ANNOUNCE is not a method of
    // std.http.Method: 501.
    .{
        .name = "invalid.md:66 ICE protocol and GET method / HTTP protocol and ANNOUNCE method",
        .raw = "ANNOUNCE /music/sweet/music HTTP/1.0\r\n" ++
            "Host: example.com\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.NotImplemented } },
    },
    .{
        .name = "invalid.md:87 ICE protocol and GET method / Headers separated by CR",
        .raw = "GET / HTTP/1.1\r\n" ++
            "Foo: 1\rBar: 2\r\n" ++
            "\r\n",
        .host_at = &.{16},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "invalid.md:113 ICE protocol and GET method / Headers separated by LF",
        .raw = "POST / HTTP/1.1\r\n" ++
            "Host: localhost:5000\r\n" ++
            "x:x\nTransfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "1\r\n" ++
            "A\r\n" ++
            "0\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "invalid.md:147 ICE protocol and GET method / Headers separated by dummy characters",
        .raw = "GET / HTTP/1.1\r\n" ++
            "Connection: close\r\n" ++
            "Host: a\r\n" ++
            "\rZGET /evil: HTTP/1.1\r\n" ++
            "Host: a\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // stricter than llhttp (lenient optional LF after CR): a bare CR is
    // refused: 400.
    .{
        .name = "invalid.md:181 ICE protocol and GET method / Headers separated by dummy characters (lenient)",
        .raw = "GET / HTTP/1.1\r\n" ++
            "Connection: close\r\n" ++
            "Host: a\r\n" ++
            "\rZGET /evil: HTTP/1.1\r\n" ++
            "Host: a\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "invalid.md:216 ICE protocol and GET method / Empty headers separated by CR",
        .raw = "POST / HTTP/1.1\r\n" ++
            "Connection: Close\r\n" ++
            "Host: localhost:5000\r\n" ++
            "x:\rTransfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "1\r\n" ++
            "A\r\n" ++
            "0\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "invalid.md:254 ICE protocol and GET method / Empty headers separated by LF",
        .raw = "POST / HTTP/1.1\r\n" ++
            "Host: localhost:5000\r\n" ++
            "x:\nTransfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "1\r\n" ++
            "A\r\n" ++
            "0\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "invalid.md:287 ICE protocol and GET method / Invalid header token #1",
        .raw = "GET / HTTP/1.1\r\n" ++
            "Fo@: Failure\r\n" ++
            "\r\n",
        .host_at = &.{16},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "invalid.md:310 ICE protocol and GET method / Invalid header token #2",
        .raw = "GET / HTTP/1.1\r\n" ++
            "Foo\x01\test: Bar\r\n" ++
            "\r\n",
        .host_at = &.{16},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "invalid.md:333 ICE protocol and GET method / Invalid header token #3",
        .raw = "GET / HTTP/1.1\r\n" ++
            ": Bar\r\n" ++
            "\r\n",
        .host_at = &.{16},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // llhttp refuses it too; for us a token that is not a method of
    // std.http.Method is 501.
    .{
        .name = "invalid.md:356 ICE protocol and GET method / Invalid method",
        .raw = "MKCOLA / HTTP/1.1\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.NotImplemented } },
    },
    .{
        .name = "invalid.md:372 ICE protocol and GET method / Illegal header field name line folding",
        .raw = "GET / HTTP/1.1\r\n" ++
            "name\r\n" ++
            " : value\r\n" ++
            "\r\n",
        .host_at = &.{16},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "invalid.md:396 ICE protocol and GET method / Corrupted Connection header",
        .raw = "GET / HTTP/1.1\r\n" ++
            "Host: www.example.com\r\n" ++
            "Connection\r\x1b5\xc3\x95eep-Alive\r\n" ++
            "Accept-Encoding: gzip\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "invalid.md:425 ICE protocol and GET method / Corrupted header name",
        .raw = "GET / HTTP/1.1\r\n" ++
            "Host: www.example.com\r\n" ++
            "X-Some-Header\r\x1b5\xc3\x95eep-Alive\r\n" ++
            "Accept-Encoding: gzip\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "invalid.md:454 ICE protocol and GET method / Missing CR between headers",
        .raw = "GET / HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "Dummy: x\nContent-Length: 23\r\n" ++
            "\r\n" ++
            "GET / HTTP/1.1\r\n" ++
            "Dummy: GET /admin HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // llhttp refuses it too; for us a major version other than 1 is 505.
    .{
        .name = "invalid.md:490 ICE protocol and GET method / Invalid HTTP version",
        .raw = "GET / HTTP/5.6",
        .expect = .{ .end = .{ .head = error.VersionNotSupported } },
    },
    .{
        .name = "invalid.md:509 Invalid space after start line",
        .raw = "GET / HTTP/1.1\r\n" ++
            " Host: foo",
        .host_at = &.{16},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "invalid.md:531 Invalid space after start line / Only LFs present",
        .raw = "POST / HTTP/1.1\nTransfer-Encoding: chunked\nTrailer: Baz\r\n" ++
            "Foo: abc\nBar: def\n\n1\nA\n1;abc\nB\n1;def=ghi\nC\n1;jkl=\"mno\"\nD\n0\n\nBaz: ghi\n\n\\",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // stricter than llhttp (lenient all): bare LFs are refused: 400.
    .{
        .name = "invalid.md:568 Invalid space after start line / Only LFs present (lenient)",
        .raw = "POST / HTTP/1.1\nTransfer-Encoding: chunked\nTrailer: Baz\r\n" ++
            "Foo: abc\nBar: def\n\n1\nA\n1;abc\nB\n1;def=ghi\nC\n1;jkl=\"mno\"\nD\n0\n\nBaz: ghi\n\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "invalid.md:650 Invalid space after start line / Spaces before headers",
        .raw = "POST /hello HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "Foo: bar\r\n" ++
            " Content-Length: 38\r\n" ++
            "\r\n" ++
            "GET /bye HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // stricter than llhttp (lenient headers): whitespace at the start of a
    // field line is refused: 400.
    .{
        .name = "invalid.md:686 Invalid space after start line / Spaces before headers (lenient)",
        .raw = "POST /hello HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "Foo: bar\r\n" ++
            " Content-Length: 38\r\n" ++
            "\r\n" ++
            "GET /bye HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "pipelining.md:4 Should parse multiple events",
        .raw = "POST /aaa HTTP/1.1\r\n" ++
            "Content-Length: 3\r\n" ++
            "\r\n" ++
            "AAA\r\n" ++
            "PUT /bbb HTTP/1.1\r\n" ++
            "Content-Length: 4\r\n" ++
            "\r\n" ++
            "BBBB\r\n" ++
            "PATCH /ccc HTTP/1.1\r\n" ++
            "Content-Length: 5\r\n" ++
            "\r\n" ++
            "CCCC",
        .host_at = &.{ 20, 65, 113 },
        .expect = .{ .end = .incomplete, .messages = &.{
            .{ .method = .POST, .target = "/aaa", .framing = .{ .length = 3 }, .fields = &.{.{ "Content-Length", "3" }}, .body = "AAA" },
            .{ .method = .PUT, .target = "/bbb", .framing = .{ .length = 4 }, .fields = &.{.{ "Content-Length", "4" }}, .body = "BBBB" },
            .{ .method = .PATCH, .target = "/ccc", .framing = .{ .length = 5 }, .fields = &.{.{ "Content-Length", "5" }}, .body = "CCCC" },
        } },
    },
    .{
        .name = "sample.md:6 Simple request",
        .raw = "OPTIONS /url HTTP/1.1\r\n" ++
            "Header1: Value1\r\n" ++
            "Header2:\t Value2\r\n" ++
            "\r\n",
        .host_at = &.{23},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .OPTIONS, .target = "/url", .fields = &.{ .{ "Header1", "Value1" }, .{ "Header2", "Value2" } } },
        } },
    },
    .{
        .name = "sample.md:39 Request with method starting with `H`",
        .raw = "HEAD /url HTTP/1.1\r\n" ++
            "\r\n",
        .host_at = &.{20},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .HEAD, .target = "/url" },
        } },
    },
    .{
        .name = "sample.md:67 curl GET",
        .raw = "GET /test HTTP/1.1\r\n" ++
            "User-Agent: curl/7.18.0 (i486-pc-linux-gnu) libcurl/7.18.0 OpenSSL/0.9.8g zlib/1.2.3.3 libidn/1.1\r\n" ++
            "Host: 0.0.0.0=5000\r\n" ++
            "Accept: */*\r\n" ++
            "\r\n",
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .GET, .target = "/test", .fields = &.{ .{ "User-Agent", "curl/7.18.0 (i486-pc-linux-gnu) libcurl/7.18.0 OpenSSL/0.9.8g zlib/1.2.3.3 libidn/1.1" }, .{ "Host", "0.0.0.0=5000" }, .{ "Accept", "*/*" } } },
        } },
    },
    .{
        .name = "sample.md:105 Firefox GET",
        .raw = "GET /favicon.ico HTTP/1.1\r\n" ++
            "Host: 0.0.0.0=5000\r\n" ++
            "User-Agent: Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9) Gecko/2008061015 Firefox/3.0\r\n" ++
            "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n" ++
            "Accept-Language: en-us,en;q=0.5\r\n" ++
            "Accept-Encoding: gzip,deflate\r\n" ++
            "Accept-Charset: ISO-8859-1,utf-8;q=0.7,*;q=0.7\r\n" ++
            "Keep-Alive: 300\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n",
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .GET, .target = "/favicon.ico", .fields = &.{ .{ "Host", "0.0.0.0=5000" }, .{ "User-Agent", "Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9) Gecko/2008061015 Firefox/3.0" }, .{ "Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" }, .{ "Accept-Language", "en-us,en;q=0.5" }, .{ "Accept-Encoding", "gzip,deflate" }, .{ "Accept-Charset", "ISO-8859-1,utf-8;q=0.7,*;q=0.7" }, .{ "Keep-Alive", "300" }, .{ "Connection", "keep-alive" } } },
        } },
    },
    .{
        .name = "sample.md:168 DUMBPACK",
        .raw = "GET /dumbpack HTTP/1.1\r\n" ++
            "aaaaaaaaaaaaa:++++++++++\r\n" ++
            "\r\n",
        .host_at = &.{24},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .GET, .target = "/dumbpack", .fields = &.{.{ "aaaaaaaaaaaaa", "++++++++++" }} },
        } },
    },
    .{
        .name = "sample.md:196 No headers and no body",
        .raw = "GET /get_no_headers_no_body/world HTTP/1.1\r\n" ++
            "\r\n",
        .host_at = &.{44},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .GET, .target = "/get_no_headers_no_body/world" },
        } },
    },
    .{
        .name = "sample.md:219 One header and no body",
        .raw = "GET /get_one_header_no_body HTTP/1.1\r\n" ++
            "Accept: */*\r\n" ++
            "\r\n",
        .host_at = &.{38},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .GET, .target = "/get_one_header_no_body", .fields = &.{.{ "Accept", "*/*" }} },
        } },
    },
    .{
        .name = "sample.md:247 Apache bench GET",
        .raw = "GET /test HTTP/1.0\r\n" ++
            "Host: 0.0.0.0:5000\r\n" ++
            "User-Agent: ApacheBench/2.3\r\n" ++
            "Accept: */*\r\n" ++
            "\r\n",
        .expect = .{ .end = .closed, .messages = &.{
            .{ .method = .GET, .target = "/test", .version = .http10, .keep_alive = false, .fields = &.{ .{ "Host", "0.0.0.0:5000" }, .{ "User-Agent", "ApacheBench/2.3" }, .{ "Accept", "*/*" } } },
        } },
    },
    .{
        .name = "sample.md:288 Prefix newline",
        .raw = "\r\n" ++
            "GET /test HTTP/1.1\r\n" ++
            "\r\n",
        .host_at = &.{22},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .GET, .target = "/test" },
        } },
    },
    // stricter than llhttp: HTTP/0.9, a request line without a version, is
    // refused: 400.
    .{
        .name = "sample.md:314 No HTTP version",
        .raw = "GET /\r\n" ++
            "\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // stricter than llhttp (lenient headers): obs-fold is refused: 400.
    .{
        .name = "sample.md:333 Line folding in header value with CRLF",
        .raw = "GET / HTTP/1.1\r\n" ++
            "Line1:   abc\r\n" ++
            "\tdef\r\n" ++
            " ghi\r\n" ++
            "\t\tjkl\r\n" ++
            "  mno \r\n" ++
            "\t \tqrs\r\n" ++
            "Line2: \t line2\t\r\n" ++
            "Line3:\r\n" ++
            " line3\r\n" ++
            "Line4: \r\n" ++
            " \r\n" ++
            "Connection:\r\n" ++
            " close\r\n" ++
            "\r\n",
        .host_at = &.{16},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "sample.md:394 Line folding in header value with LF",
        .raw = "GET / HTTP/1.1\r\n" ++
            "Line1:   abc\n\tdef\n ghi\n\t\tjkl\n  mno \n\t \tqrs\nLine2: \t line2\t\nLine3:\n line3\nLine4: \n \nConnection:\n close\n\n",
        .host_at = &.{16},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "sample.md:432 No LF after CR",
        .raw = "GET / HTTP/1.1\rLine: 1\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    // stricter than llhttp (lenient optional LF after CR): a bare CR is
    // refused: 400.
    .{
        .name = "sample.md:454 No LF after CR (lenient)",
        .raw = "GET / HTTP/1.1\rLine: 1\r\n",
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
    .{
        .name = "sample.md:478 Request starting with CRLF",
        .raw = "\r\n" ++
            "GET /url HTTP/1.1\r\n" ++
            "Header1: Value1\r\n" ++
            "\r\n",
        .host_at = &.{21},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .GET, .target = "/url", .fields = &.{.{ "Header1", "Value1" }} },
        } },
    },
    .{
        .name = "sample.md:506 Extended Characters",
        .raw = "GET / HTTP/1.1\r\n" ++
            "Test: D\xc3\xbcsseldorf\r\n" ++
            "\r\n",
        .host_at = &.{16},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .GET, .target = "/", .fields = &.{.{ "Test", "D\xc3\xbcsseldorf" }} },
        } },
    },
    .{
        .name = "sample.md:536 255 ASCII in header value",
        .raw = "OPTIONS /url HTTP/1.1\r\n" ++
            "Header1: Value1\r\n" ++
            "Header2: \xc3\xbfValue2\r\n" ++
            "\r\n",
        .host_at = &.{23},
        .expect = .{ .end = .complete, .messages = &.{
            .{ .method = .OPTIONS, .target = "/url", .fields = &.{ .{ "Header1", "Value1" }, .{ "Header2", "\xc3\xbfValue2" } } },
        } },
    },
    // stricter than llhttp (lenient headers): obs-fold is refused: 400.
    .{
        .name = "sample.md:571 X-SSL-Nonsense",
        .raw = "GET / HTTP/1.1\r\n" ++
            "X-SSL-Nonsense:   -----BEGIN CERTIFICATE-----\r\n" ++
            "\tMIIFbTCCBFWgAwIBAgICH4cwDQYJKoZIhvcNAQEFBQAwcDELMAkGA1UEBhMCVUsx\r\n" ++
            "\tETAPBgNVBAoTCGVTY2llbmNlMRIwEAYDVQQLEwlBdXRob3JpdHkxCzAJBgNVBAMT\r\n" ++
            "\tAkNBMS0wKwYJKoZIhvcNAQkBFh5jYS1vcGVyYXRvckBncmlkLXN1cHBvcnQuYWMu\r\n" ++
            "\tdWswHhcNMDYwNzI3MTQxMzI4WhcNMDcwNzI3MTQxMzI4WjBbMQswCQYDVQQGEwJV\r\n" ++
            "\tSzERMA8GA1UEChMIZVNjaWVuY2UxEzARBgNVBAsTCk1hbmNoZXN0ZXIxCzAJBgNV\r\n" ++
            "\tBAcTmrsogriqMWLAk1DMRcwFQYDVQQDEw5taWNoYWVsIHBhcmQYJKoZIhvcNAQEB\r\n" ++
            "\tBQADggEPADCCAQoCggEBANPEQBgl1IaKdSS1TbhF3hEXSl72G9J+WC/1R64fAcEF\r\n" ++
            "\tW51rEyFYiIeZGx/BVzwXbeBoNUK41OK65sxGuflMo5gLflbwJtHBRIEKAfVVp3YR\r\n" ++
            "\tgW7cMA/s/XKgL1GEC7rQw8lIZT8RApukCGqOVHSi/F1SiFlPDxuDfmdiNzL31+sL\r\n" ++
            "\t0iwHDdNkGjy5pyBSB8Y79dsSJtCW/iaLB0/n8Sj7HgvvZJ7x0fr+RQjYOUUfrePP\r\n" ++
            "\tu2MSpFyf+9BbC/aXgaZuiCvSR+8Snv3xApQY+fULK/xY8h8Ua51iXoQ5jrgu2SqR\r\n" ++
            "\twgA7BUi3G8LFzMBl8FRCDYGUDy7M6QaHXx1ZWIPWNKsCAwEAAaOCAiQwggIgMAwG\r\n" ++
            "\tA1UdEwEB/wQCMAAwEQYJYIZIAYb4QgHTTPAQDAgWgMA4GA1UdDwEB/wQEAwID6DAs\r\n" ++
            "\tBglghkgBhvhCAQ0EHxYdVUsgZS1TY2llbmNlIFVzZXIgQ2VydGlmaWNhdGUwHQYD\r\n" ++
            "\tVR0OBBYEFDTt/sf9PeMaZDHkUIldrDYMNTBZMIGaBgNVHSMEgZIwgY+AFAI4qxGj\r\n" ++
            "\tloCLDdMVKwiljjDastqooXSkcjBwMQswCQYDVQQGEwJVSzERMA8GA1UEChMIZVNj\r\n" ++
            "\taWVuY2UxEjAQBgNVBAsTCUF1dGhvcml0eTELMAkGA1UEAxMCQ0ExLTArBgkqhkiG\r\n" ++
            "\t9w0BCQEWHmNhLW9wZXJhdG9yQGdyaWQtc3VwcG9ydC5hYy51a4IBADApBgNVHRIE\r\n" ++
            "\tIjAggR5jYS1vcGVyYXRvckBncmlkLXN1cHBvcnQuYWMudWswGQYDVR0gBBIwEDAO\r\n" ++
            "\tBgwrBgEEAdkvAQEBAQYwPQYJYIZIAYb4QgEEBDAWLmh0dHA6Ly9jYS5ncmlkLXN1\r\n" ++
            "\tcHBvcnQuYWMudmT4sopwqlBWsvcHViL2NybC9jYWNybC5jcmwwPQYJYIZIAYb4QgEDBDAWLmh0\r\n" ++
            "\tdHA6Ly9jYS5ncmlkLXN1cHBvcnQuYWMudWsvcHViL2NybC9jYWNybC5jcmwwPwYD\r\n" ++
            "\tVR0fBDgwNjA0oDKgMIYuaHR0cDovL2NhLmdyaWQt5hYy51ay9wdWIv\r\n" ++
            "\tY3JsL2NhY3JsLmNybDANBgkqhkiG9w0BAQUFAAOCAQEAS/U4iiooBENGW/Hwmmd3\r\n" ++
            "\tXCy6Zrt08YjKCzGNjorT98g8uGsqYjSxv/hmi0qlnlHs+k/3Iobc3LjS5AMYr5L8\r\n" ++
            "\tUO7OSkgFFlLHQyC9JzPfmLCAugvzEbyv4Olnsr8hbxF1MbKZoQxUZtMVu29wjfXk\r\n" ++
            "\thTeApBv7eaKCWpSp7MCbvgzm74izKhu3vlDk9w6qVrxePfGgpKPqfHiOoGhFnbTK\r\n" ++
            "\twTC6o2xq5y0qZ03JonF7OJspEd3I5zKY3E+ov7/ZhW6DqT8UFvsAdjvQbXyhV8Eu\r\n" ++
            "\tYhixw1aKEPzNjNowuIseVogKOLXxWI5vAi5HgXdS0/ES5gDGsABo4fqovUKlgop3\r\n" ++
            "\tRA==\r\n" ++
            "\t-----END CERTIFICATE-----\r\n" ++
            "\r\n",
        .host_at = &.{16},
        .expect = .{ .end = .{ .head = error.BadRequest } },
    },
};
