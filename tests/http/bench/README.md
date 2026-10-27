# The benchmark of zefir-http

The guide of zefir-http,
[src/http/examples/README.md](../../../src/http/examples/README.md), says
what the server does, and the tests hold it to the code:
`zig build test-http` builds and runs "http in a minute", the service
under zefir.App and the tests of the example app, and checks them against
the guide. The service runs on the network: in `tests/http`,
`zig build examples` starts it, sends it every curl command of the guide,
and checks each response, and the log of the service, against what the
guide shows. This page tells how fast a server of zefir-http was on one
machine, and no test checks its numbers.

How many requests does a server of zefir-http answer in a second, and how
long does one take? The benchmark `tests/http/bench/main.zig` measures
both. Run it on Linux:

```sh
cd tests/http
zig build bench
```

It is built with ReleaseFast, and so are zefir and zio under it; the run
takes about a minute. On GitHub it runs only when asked, as the job
`bench-http` of the workflow `.github/workflows/bench.yml`:
`gh workflow run bench.yml --ref <branch>`. It is not a part of CI, and no
check waits for it.

**What it measures.** One process holds the server, on `http.native`, and
the clients that load it, all on one zio runtime, and they talk over
loopback, `127.0.0.1`. No network card and no other machine is on the way,
so the time is that of zefir-http and zio; the clients share the CPUs with
the server, so the server gets less than the whole machine. Each client
opens one connection and keeps it alive, as a browser or a proxy in front
of a service does, so that opening connections is not what is timed: it
sends a request, reads the whole response, and only then sends the next.
One connection has one request at work at a time, then, and 64 connections
have 64. Each scenario asks for a path of its own:

| Scenario | Request | What the server does |
| --- | --- | --- |
| plain text | `GET /text` | `ctx.response.text("hello, world")`: the least a request costs, from its head parsed to its response written |
| JSON out | `GET /todos/42` | reads the path into `struct { id: u64 }`, returns an `http.Json(Todo)` |
| JSON in and out | `POST /todos`, 33 bytes of JSON | reads the body with `ctx.json(NewTodo)`, returns 201 with an `http.Json(Todo)` |
| static file, 1.8 KiB | `GET /index.html` | sends `public/index.html` of the guide, 1 845 bytes, through `http.static` |
| chain of 5 middleware | `GET /chained` | runs five middleware before its text: three functions that return `.next`, a type whose `run` reads the clock and whose `onFinish` takes the duration, as an access log does, and `http.onResponse`, which sets a header |

Each scenario runs with one connection, 20 000 requests, and with 64
connections at once, 3 000 requests each, after a warm-up of a tenth as
many that is not timed. All of it runs twice: on zio with one executor, a
single thread for the server and its clients, and with four. A line gives
the requests per second that the server answered, and the time of a
request, from when its client sends it to when its whole response is read:
p50, the median, p90 and p99, and max, the slowest, in microseconds.

A run of commit 14b9c1d on a shared runner of GitHub Actions,
ubuntu-latest: Ubuntu 24.04, 4 vCPUs of an AMD EPYC 7763, 16 GB of memory,
[run 39110564012](https://github.com/vkiryakov/zefir/actions/runs/39110564012):

```text
zefir-http benchmark: fast build, linux x86_64; the server and its clients in one process, over loopback

zio, 1 executor
  scenario                 conns  requests  requests/s  p50 µs  p90 µs  p99 µs  max µs
  plain text                   1     20000       41819     23.2     23.5     40.4     79.4
  plain text                  64    192000       50796   1248.6   1287.6   1520.5  11410.2
  JSON out                     1     20000       40795     23.7     24.1     41.6     74.8
  JSON out                    64    192000       50381   1262.3   1296.2   1482.0  11569.0
  JSON in and out              1     20000       39470     24.5     25.0     43.1     77.1
  JSON in and out             64    192000       52101   1214.8   1361.7   1565.8  12096.4
  static file, 1.8 KiB         1     20000       12876     76.2     91.7    102.6    228.5
  static file, 1.8 KiB        64    192000       36103   1743.1   1871.3   1924.8  10863.6
  chain of 5 middleware        1     20000       39985     24.3     24.7     42.0     73.8
  chain of 5 middleware       64    192000       49732   1279.1   1311.1   1499.4  10375.6

zio, 4 executors
  scenario                 conns  requests  requests/s  p50 µs  p90 µs  p99 µs  max µs
  plain text                   1     20000       12076     82.2     90.1    100.3    266.3
  plain text                  64    192000      122440    498.5    729.5    914.8   4672.9
  JSON out                     1     20000       11674     84.9     95.6    103.7    293.4
  JSON out                    64    192000      120265    514.9    735.0    876.4   5562.1
  JSON in and out              1     20000       11715     83.9     99.0    108.2    736.9
  JSON in and out             64    192000      115812    551.3    659.4    751.8   4978.7
  static file, 1.8 KiB         1     20000        7745    129.7    139.9    163.2   2267.2
  static file, 1.8 KiB        64    192000       67869    894.2   1457.0   2536.6   4985.4
  chain of 5 middleware        1     20000       12237     81.8     93.4    111.0    459.1
  chain of 5 middleware       64    192000      116444    547.6    666.8    765.5   4531.3
```

Three runs of the commit on that CPU, this one,
[39110560573](https://github.com/vkiryakov/zefir/actions/runs/39110560573)
and [39110562340](https://github.com/vkiryakov/zefir/actions/runs/39110562340),
gave these requests per second, from the lowest to the highest:

| Scenario | 1 executor, 1 connection | 1 executor, 64 connections | 4 executors, 1 connection | 4 executors, 64 connections |
| --- | ---: | ---: | ---: | ---: |
| plain text | 41 454–42 579 | 49 896–51 028 | 11 754–12 076 | 122 440–124 104 |
| JSON out | 40 632–41 660 | 49 447–50 381 | 11 601–11 846 | 119 795–121 567 |
| JSON in and out | 39 178–40 231 | 51 582–52 346 | 11 715–12 105 | 115 771–116 842 |
| static file, 1.8 KiB | 11 932–12 876 | 35 248–36 311 | 7 710–7 745 | 66 042–67 869 |
| chain of 5 middleware | 39 537–40 740 | 48 541–49 732 | 11 971–12 245 | 114 986–117 427 |

A shared runner is not the same machine every time, though: another run of
the commit got an AMD EPYC 9V45, and answered 1.3 to 1.9 times as many
requests per second on one executor, 1.7 to 2.4 times as many on four
([run 39110943686](https://github.com/vkiryakov/zefir/actions/runs/39110943686)).

How to read it:

- **Requests per second** is how much the server does: the requests of a
  line, divided by the time they all took. **p50, p90, p99 and max** are
  what a client waits: half of the requests took p50 or less, one in a
  hundred took longer than p99, and max is the slowest of all. The users of
  a service feel its p99 more than its median.
- **One connection** has one request at a time, so it shows how long a
  request takes when nothing else waits; its requests per second are one
  second divided by that time. On one executor, about 24 µs, the client's
  part included.
- **64 connections** always have a request waiting, so they show how many
  requests a busy server answers. On one executor the 64 take turns on one
  thread: about 51 000 requests per second, and each request waits for the
  others, its p50 of about 1.25 ms: 64 requests at 51 000 per second.
- **On one connection, one executor beats four:** about 42 000 requests
  per second against 12 000. A request of a connection kept alive passes
  between three tasks: the connection's task reads and parses it, then
  starts the request's task, which runs the middleware and the handler,
  and its watcher, which notices a client that leaves; the connection's
  task waits for the first of the two to end, cancels the other, and writes
  the response. On one executor each hand-off is a switch between
  coroutines of one thread. On four, zio starts each new task on the next
  executor in turn, so a request wakes other threads and waits for them to
  wake its own, a few times over; with one connection nothing else runs in
  the meantime, and those wake-ups take most of its 83 µs.
- **On 64 connections, four executors beat one:** about 122 000 requests
  per second against 51 000. There is always a request ready, so the four
  threads work at once, and while one request waits for a hand-off, others
  run. Not four times as many: the 64 clients run on the same four vCPUs,
  and the hand-offs still cost. The service of the guide asks zio for
  `.executors = .auto`, an executor per core: four, on this runner.
- **JSON costs little.** Reading a small JSON body, or writing one, moves
  the count by a few percent from plain text, either way.
- **A static file costs calls to the system.** For each request the server
  opens the file, one open for each component of its path (`/index.html`
  has one), asks the system for its kind, size and time (`fstat`), which
  `ETag` and `Last-Modified` come from, reads it through a buffer of
  16 KiB, writes it, and closes it; the file goes through that buffer, with
  no `sendfile`. zio makes each call without holding up its thread: the
  request's task waits for it, as it waits for the network. With one
  connection nothing fills those waits, and a request takes about 76 µs
  instead of 23. With 64 connections other requests fill them: on one
  executor a file then costs its thread about 8 µs more than plain text,
  and the server answers about 30 percent fewer requests; on four, about
  45 percent fewer.
- **Five middleware cost about a microsecond** of a request on one
  executor and one connection, and 2 percent of the requests per second on
  64. That includes their `onFinish`, which runs on a task of its own once
  the request has ended, as every `onFinish` does. On four executors and
  one connection the chain is as fast as plain text: there the wake-ups
  take the time.

These numbers are what one runner measured with these small handlers: no
promise for your machine, your handlers or your clients. Measure where the
service runs, under the load it will have, and with the limits that matter
there raised first: the mappings of memory, `vm.max_map_count`, and the
open files, `ulimit -n`, in
[Limits and timeouts](../../../src/http/examples/README.md#limits-and-timeouts)
of the guide.
