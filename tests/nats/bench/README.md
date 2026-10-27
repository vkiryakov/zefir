# The benchmark of zefir-nats

The guide of zefir-nats, src/nats/examples/README.md, says what the client
does; this page tells how fast it was on one machine. In tests/nats,

```sh
zig build bench
```

starts the servers of `docker-compose.yml` and runs, against the plain one,
`tests/nats/bench/main.zig`, built with ReleaseFast: publishing messages
of 16 bytes to 16 KiB, publishing to a subscriber of another client, and
request/reply with 1, 16 and 256 requests at a time, on zio with one
executor and with four. For each it prints the messages per second and the
megabytes per second, and for requests the median, 99th percentile and
slowest round trip, after 100 requests that are not timed: the first one
also subscribes the inbox.

A run of it follows. Its numbers describe one shared machine and are no
promise for yours: run the benchmark where your service runs, against
your server.

**GitHub Actions ubuntu-latest (shared runner), ReleaseFast.** The workflow
`.github/workflows/bench.yml` runs `zig build bench` on a GitHub-hosted
runner: Ubuntu 24.04, 4 vCPUs of an AMD EPYC 7763, 16 GB, Docker 28.0.4; the
server runs on the same 4 vCPUs.
[Run 38567461016](https://github.com/vkiryakov/zefir/actions/runs/38567461016),
with commas added to the numbers for reading:

```text
zefir-nats benchmark: fast build, linux x86_64, server nats://127.0.0.1:14222

zio, 1 executor
  scenario                           messages  messages/s        MB/s
  publish, 16 B                     1,000,000   3,737,354        59.8
  publish, 128 B                    1,000,000   2,472,614       316.5
  publish, 1024 B                     300,000     827,963       847.8
  publish, 16384 B                     30,000      49,086       804.2
  publish to a subscriber, 16 B       300,000   1,453,245        23.3
  publish to a subscriber, 128 B      300,000   1,188,980       152.2
  publish to a subscriber, 1024 B     100,000     436,045       446.5
  request/reply, 16 B                requests  requests/s      p50 µs      p99 µs      max µs
  1 at a time                          10,000       2,852         339         611       2,551
  16 at a time                         50,000      37,841         406         758       3,163
  256 at a time                        49,920     209,165       1,151       2,174       3,024

zio, 4 executors
  scenario                           messages  messages/s        MB/s
  publish, 16 B                     1,000,000   3,425,807        54.8
  publish, 128 B                    1,000,000   2,765,288       354.0
  publish, 1024 B                     300,000     798,326       817.5
  publish, 16384 B                     30,000      44,849       734.8
  publish to a subscriber, 16 B       300,000   1,570,656        25.1
  publish to a subscriber, 128 B      300,000   1,051,854       134.6
  publish to a subscriber, 1024 B     100,000     392,203       401.6
  request/reply, 16 B                requests  requests/s      p50 µs      p99 µs      max µs
  1 at a time                          10,000       2,825         342         657       2,371
  16 at a time                         50,000      34,436         434         889       2,586
  256 at a time                        49,920     156,147       1,487       3,273       5,469
```

A shared runner is not the same machine twice. Two more runs of the same
commit, [38569109348](https://github.com/vkiryakov/zefir/actions/runs/38569109348)
and [38569121532](https://github.com/vkiryakov/zefir/actions/runs/38569121532),
gave from 2,771 to 5,350 requests per second one at a time.

One connection is one stream of bytes, written by one task, so a client
publishes about as fast on one executor as on four. With 256 requests at
a time, the three runs were 20 to 40 percent slower on four executors.
More executors pay off when your own work, not the client, needs the
cores.
