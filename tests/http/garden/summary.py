"""How zefir-http reads the payloads of payloads.zig next to the other
origin servers of the HTTP Garden. Run it from the Garden's root once its
servers are up, with the lines of `zig build garden-payloads` on stdin:

    uv run python3 <zefir>/tests/http/garden/summary.py < payloads.txt

It sends each payload to every origin server that runs, as the REPL's
`fanout` does, and compares zefir with each of them as `grid` does. It
prints, in Markdown, every payload where they differ: what zefir did, and
which servers refused what zefir accepted (look at these first), accepted
what zefir refused, read the request otherwise, or read another number of
requests from the same bytes.
"""

import shlex
import sys

sys.path.insert(0, "tools")

from diff import ErrorType, categorize_discrepancy  # noqa: E402
from fanout import fanout  # noqa: E402
from http1 import HTTPRequest  # noqa: E402
from targets import ORIGIN_DICT  # noqa: E402

KINDS = (
    "refuse what zefir accepts",
    "accept what zefir refuses",
    "read the request otherwise",
    "read another number of requests",
    "parse a request that breaks the RFCs",
)


def payloads():
    """The bytes of each `payload '...'` line, decoded as the REPL does."""
    for line in sys.stdin:
        tokens = [t[1:-1] if t[0] == t[-1] and t[0] in "\"'" else t for t in shlex.shlex(line)]
        if len(tokens) >= 2 and tokens[0] == "payload":
            yield tokens[1].encode("latin1").decode("unicode-escape").encode("latin1")


def verdict(results) -> str:
    if not results:
        return "no response"
    if isinstance(results[0], HTTPRequest):
        return f"accepted, {len(results)} request(s)"
    return f"refused, {results[0].code.decode('latin1')}"


def kind_of(error: ErrorType, mine) -> str:
    if error == ErrorType.TYPE_DISCREPANCY:
        return KINDS[0] if mine and isinstance(mine[0], HTTPRequest) else KINDS[1]
    if error == ErrorType.REQUEST_DISCREPANCY:
        return KINDS[2]
    if error == ErrorType.STREAM_DISCREPANCY:
        return KINDS[3]
    return KINDS[4]


def main() -> None:
    zefir = ORIGIN_DICT["zefir"]
    others = [server for name, server in ORIGIN_DICT.items() if name != "zefir"]
    counts = dict.fromkeys(KINDS, 0)
    total = differing = 0
    print(f"# zefir-http in the HTTP Garden\n\nOrigin servers: zefir, {', '.join(s.name for s in others)}.\n")
    for payload in payloads():
        total += 1
        results = fanout([payload], [zefir, *others])
        mine = results[0]
        found: dict[str, list[str]] = {}
        for server, theirs in zip(others, results[1:]):
            error = categorize_discrepancy(mine, theirs, zefir, server)
            if error in (ErrorType.OK, ErrorType.RESPONSE_DISCREPANCY):
                continue
            found.setdefault(kind_of(error, mine), []).append(f"{server.name} ({verdict(theirs)})")
        if not found:
            continue
        differing += 1
        print(f"- `` {payload!r} ``: zefir {verdict(mine)}")
        for kind in KINDS:
            if kind in found:
                counts[kind] += 1
                print(f"  - {kind}: {', '.join(found[kind])}")
    print(f"\n{total} payloads, {differing} where zefir and a server differ:")
    for kind in KINDS:
        print(f"- servers {kind}: {counts[kind]} payloads")


if __name__ == "__main__":
    main()
