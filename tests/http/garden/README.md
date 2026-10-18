# zefir-http in the HTTP Garden

The [HTTP Garden](https://github.com/narfindustries/http-garden) runs HTTP
servers side by side in Docker, sends each the same bytes, and shows where
they understand them differently. Where one server accepts a request that
another refuses, or reads it otherwise, a request can be smuggled past a
proxy: this is how the Garden checks a parser. Here zefir-http is one of
its origin servers, next to nginx, Apache httpd, h2o, hyper and gunicorn,
and the bytes are the corpus of its parser, `src/http/h1/testdata/`.

| File | What it is |
|---|---|
| `echo.zig` | The target: a server on `http.native` that answers each request it parses with what it understood, in the JSON of the Garden's echo servers |
| `Dockerfile` | Builds the target with Zig 0.17.0 on the Garden's base image |
| `compose.yml` | Its service in the Garden's `docker-compose.yml` |
| `payloads.zig` | `zig build garden-payloads` prints the corpus as lines of the Garden's REPL |
| `summary.py` | Lists the payloads where zefir and another server differ |

CI runs it in `.github/workflows/http-garden.yml`: on a pull request into
`dev` that changes the parser, `http.native`, the exchange the echo answers
through, the build of the echo or this directory, and by hand. The Garden
is pinned to a commit there. The run uploads the output of the REPL and of
`summary.py` as an artifact, and shows the summary on the page of the run.

## What the echo covers

The echo serves the connections of `http.native` as they are, so the Garden
sees the parser and the framing of the real server: the request line and
the fields, bodies by `Content-Length` and chunked, the limits, and
`Expect: 100-continue`. But it reads every body whole, and no `http.Server`
stands in front of it, so the Garden does not see:

- an early response, sent before its body was read: the up to 64 KiB of
  body that the connection drops after it, and `Connection: close` for
  more;
- an early answer to `Expect: 100-continue`, which closes the connection
  without the body, since no `100 Continue` asked for it;
- the read ahead of a request's watcher, once its body has been read;
- the path as the router reads it: its fragment cut, its segments decoded
  and its dot segments resolved (`src/http/path.zig`). The echo shows the
  target as it came.

The end-to-end tests cover these, in `tests/http/e2e/bodies.zig`: "an
early response skips the unread body and the pipelined request after it
stays whole" (review focus 1) and the tests of early responses around it;
"a client that leaves after its body was read cancels the request", for
the watcher; and the module's tests of `path.zig`, for the path.

## Where zefir-http reads a request otherwise

The summary of a run lists every payload where zefir-http and another
server differ. These differences are known, and stay:

- **`Host`.** In HTTP/1.1 an empty `Host` is 400, as in nginx and Apache
  httpd: an http URI has a host (RFC 9110 §4.2.1). Beside an absolute
  target, `GET http://a.example/x`, `Host` must be the target's authority,
  in any case, else 400: the target names the host (RFC 9112 §3.2.2), and
  an application reads `Host`. A host such as `0.0.0.0=5000`, with
  sub-delims, is a valid name, and passes: the server routes by the path,
  never by `Host`.
- **A fragment in the target**, `/a#b`, is cut before the route is found;
  the echo shows the target whole.
- **`"` and `\` in the target** pass, as in nginx, Apache httpd, h2o and
  gunicorn; static files refuse a `\` in a segment.
- **Empty lines before the request line** are skipped, as RFC 9112 §2.2
  says.
- **`Expect: 100-continue` on a GET without a body** gets no `100
  Continue`: there is no body to wait for. **An `Expect` of HTTP/1.0** is
  ignored, as RFC 9110 §10.1.1 says of `100-continue`; for another
  expectation, 417 is a may, not a must.

## Running it by hand

On x86_64 Linux with Docker, Python 3.13 and [uv](https://docs.astral.sh/uv/),
from the root of a zefir checkout:

```sh
git clone https://github.com/narfindustries/http-garden
git -C http-garden checkout b417e806c1b15e8ea0b9312f81a91fbdcbc7a83e

# The build context of the target: the Dockerfile and a copy of zefir.
mkdir -p http-garden/images/zefir/zefir/tests
cp tests/http/garden/Dockerfile http-garden/images/zefir/
cp -r build.zig build.zig.zon src README.md LICENSE http-garden/images/zefir/zefir/
rsync -a --exclude .zig-cache --exclude zig-out --exclude zig-pkg tests/http http-garden/images/zefir/zefir/tests/

# Its service, after the Garden's own in its docker-compose.yml.
sed '1,/^services:$/d' tests/http/garden/compose.yml >> http-garden/docker-compose.yml

(cd tests/http && zig build garden-payloads) > payloads.txt
cd http-garden
./garden.sh start --build --detach zefir nginx apache_httpd h2o hyper gunicorn
./garden.sh repl < ../payloads.txt
uv run python3 ../tests/http/garden/summary.py < ../payloads.txt
./garden.sh stop
```

One payload by hand, in the REPL (`./garden.sh repl`):

```
garden> payload 'GET / HTTP/1.1\r\nHost: a\r\n\r\n' | fanout | grid
```
