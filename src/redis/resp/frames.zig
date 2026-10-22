//! Frames of RESP3 shared by the tests of `resp.Reader` and the corpus of
//! its fuzz target: well-formed replies, each with the shape the reader
//! tests print for it, and bytes that break RESP3.

/// A well-formed reply and its shape: each element as `kind(value)`, each
/// aggregate as `kind[n](elements)`.
pub const valid = [_][2][]const u8{
    .{ "+OK\r\n", "simple_string(OK)" },
    .{ "-ERR unknown command 'FOO'\r\n", "simple_error(ERR unknown command 'FOO')" },
    .{ ":-42\r\n", "integer(-42)" },
    .{ ":0\r\n", "integer(0)" },
    .{ ":9223372036854775807\r\n", "integer(9223372036854775807)" },
    .{ ":-9223372036854775808\r\n", "integer(-9223372036854775808)" },
    .{ "$3\r\nAnn\r\n", "bulk_string(Ann)" },
    .{ "$0\r\n\r\n", "bulk_string()" },
    .{ "_\r\n", "null" },
    .{ "$-1\r\n", "null" },
    .{ "*-1\r\n", "null" },
    .{ "#t\r\n", "boolean(true)" },
    .{ "#f\r\n", "boolean(false)" },
    .{ ",1.5\r\n", "double(1.5)" },
    .{ ",inf\r\n", "double(inf)" },
    .{ ",-inf\r\n", "double(-inf)" },
    .{ ",nan\r\n", "double(nan)" },
    .{ ",-0\r\n", "double(-0)" },
    .{ ",1e3\r\n", "double(1000)" },
    .{ ",3\r\n", "double(3)" },
    .{ "(3492890328409238509324850943850943825024385\r\n", "big_number(3492890328409238509324850943850943825024385)" },
    .{ "(-12\r\n", "big_number(-12)" },
    .{ "!21\r\nSYNTAX invalid syntax\r\n", "bulk_error(SYNTAX invalid syntax)" },
    .{ "=15\r\ntxt:Some string\r\n", "verbatim_string[txt](Some string)" },
    .{
        "*3\r\n:1\r\n*2\r\n+a\r\n$1\r\nb\r\n%1\r\n+k\r\n~2\r\n#t\r\n_\r\n",
        "array[3](integer(1) array[2](simple_string(a) bulk_string(b)) map[1](simple_string(k) set[2](boolean(true) null)))",
    },
    .{ "*0\r\n", "array[0]()" },
    .{ "%0\r\n", "map[0]()" },
    .{ "~0\r\n", "set[0]()" },
    .{ "*2\r\n*0\r\n:7\r\n", "array[2](array[0]() integer(7))" },
    .{
        ">3\r\n$7\r\nmessage\r\n$6\r\norders\r\n$3\r\nnew\r\n",
        "push[3](bulk_string(message) bulk_string(orders) bulk_string(new))",
    },
    // The attribute of the RESP3 specification, before the reply it
    // describes: skipped, and the array read.
    .{
        "|1\r\n+key-popularity\r\n%2\r\n$1\r\na\r\n,0.1923\r\n$1\r\nb\r\n,0.0012\r\n" ++
            "*2\r\n:2039123\r\n:9543892\r\n",
        "array[2](integer(2039123) integer(9543892))",
    },
    // Attributes inside a reply, and one on an attribute's own key.
    .{ "*2\r\n|1\r\n+ttl\r\n:3600\r\n:1\r\n:2\r\n", "array[2](integer(1) integer(2))" },
    .{ "|1\r\n|1\r\n+a\r\n+b\r\n+k\r\n+v\r\n:5\r\n", "integer(5)" },
    .{ "|0\r\n+OK\r\n", "simple_string(OK)" },
};

/// Bytes that break RESP3: each is a ProtocolViolation.
pub const broken = [_][]const u8{
    // Streamed strings and aggregates, which servers do not send.
    "$?\r\n;4\r\nHell\r\n;0\r\n",
    "*?\r\n:1\r\n.\r\n",
    ";4\r\nHell\r\n",
    ".\r\n",
    // An unknown type byte, bad lengths and bad scalars.
    "@\r\n",
    "$abc\r\n",
    "$-2\r\n",
    "$01\r\na\r\n",
    "$\r\n",
    "%-1\r\n",
    "#x\r\n",
    "#t\r\r",
    ":12a\r\n",
    ":-\r\n",
    ":9223372036854775808\r\n",
    ":-9223372036854775809\r\n",
    ",1.5x\r\n",
    ",.5\r\n",
    ",1e\r\n",
    ",0x10\r\n",
    ",1_000\r\n",
    "(12a\r\n",
    "(-\r\n",
    "(\r\n",
    "_x\r\n",
    // A missing or wrong CRLF.
    "$3\r\nAnnX\r\n",
    "+OK\n",
    "+O\nK\r\n",
    ":1\n",
    // A verbatim string shorter than its format, or without the colon.
    "=3\r\ntxt\r\n",
    "=5\r\ntxtx1\r\n",
    // A push inside a reply.
    "*1\r\n>1\r\n:1\r\n",
    "|1\r\n>1\r\n:1\r\n:1\r\n:1\r\n",
};
