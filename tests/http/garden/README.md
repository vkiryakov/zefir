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
`dev` that changes the parser, `http.native` or this directory, and by
hand. The Garden is pinned to a commit there. The run uploads the output
of the REPL and of `summary.py` as an artifact, and shows the summary on
the page of the run.

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
