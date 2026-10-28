# Contributing to Zefir

This page is for those who change Zefir itself: how to run its tests and checks, what CI runs for a pull request, the end-to-end tests against real servers, and the branches a change goes through.

```sh
zig build test --summary all                                                     # run all tests
zig build test-log --summary all                                                 # run one module's tests: test-core, test-log, …
zig build bench                                                                  # run the benchmarks of core and log, built with ReleaseFast
# check formatting, as CI does
zig fmt --check build.zig build.zig.zon src tests examples \
  --exclude tests/nats/zig-pkg --exclude tests/rpc-nats/zig-pkg \
  --exclude tests/http/zig-pkg --exclude tests/mongo/zig-pkg --exclude tests/odm/zig-pkg \
  --exclude tests/redis/zig-pkg --exclude tests/app/zig-pkg \
  --exclude examples/rpc-custom-transport/zig-pkg --exclude examples/rpc-custom-transport/consumer/zig-pkg
```

CI tests a pull request only on the modules it affects. A change under `src/<module>/` runs the tests of that module, of every module that depends on it and of `zefir`; a change to `build.zig`, `build.zig.zon`, `src/zefir.zig` or `.github/` runs them all, and documentation outside `src/`, `tests/` and `examples/` runs none, except README.md at the root: its "confy in a minute", "core in a minute", "log in a minute", "nats in a minute", "rpc in a minute" and "http in a minute" are programs that the tests of confy, core, log, nats, rpc and http check, and since core is among them, an edit of README.md runs every module but mongo-bson. Every push to `dev` and `main` tests all modules. The module graph for this is in `.github/scripts/affected-modules.sh`: a new module goes there as well as into `build.zig`, and the folder of its guide into `folders` of `context7.json`, with its name in the rule that lists the modules, so that Context7 indexes the guide.

Each guide in `src/<module>/examples` is checked by the tests of its module, and the App guide in `src/core/examples/app` by those of `zefir`: a file it shows whole must be as it is, any other Zig block a part of a file that the build compiles (but for `// build.zig` blocks and, in the guides of log and the validator, code marked `// compile error:`), and the run of a program that needs neither a server nor zio as the program prints it, apart from what changes from run to run, such as timestamps and ids. A file and its copy in a guide therefore change in the same commit.

The end-to-end tests of nats run against real NATS servers in Docker, described by `docker-compose.yml` at the repository root. The tests are a package of their own in `tests/nats`, so zio, the runtime they use, never reaches zefir's users:

```sh
docker compose up -d --wait   # start the servers, from the repository root
cd tests/nats
zig build e2e                 # start the servers if needed, run the tests, then the examples, checking what they print against the guide and README.md
zig build example-pub_sub     # run one example of src/nats/examples and show what it prints
zig build stress              # the stress tests, in Debug and in ReleaseSafe
zig build bench               # the benchmark, built with ReleaseFast
zig build check               # build all of the above without running it; no servers needed
zig build down                # stop the servers
```

`zig build down` also resets the servers when a run dies half way, say while a test holds one of them paused. [tests/nats/bench/README.md](tests/nats/bench/README.md) says what the benchmark measures and shows a run of it. Whenever CI tests nats, it builds this package on Linux, macOS and Windows and runs the end-to-end tests on Linux; a change to `tests/nats/` counts as a change to nats.

The end-to-end tests of rpc-nats, with the examples of its guide, are a package of the same kind in `tests/rpc-nats`, against servers of the same `docker-compose.yml`:

```sh
cd tests/rpc-nats
zig build e2e      # start the servers if needed, run the tests, then the examples, checking what they print against the guide
zig build check    # build the tests and the examples without running them; no servers needed
zig build down     # stop the servers
```

CI treats it as nats: whenever it tests rpc-nats, it builds the package on the three systems and runs it on Linux; a change to `tests/rpc-nats/` counts as a change to rpc-nats, and one to `docker-compose.yml` as a change to both.

The end-to-end tests of http, with the service of its guide, are a package of the same kind in `tests/http`, on zio, and need no servers:

```sh
cd tests/http
zig build e2e        # the end-to-end tests, then the service of the guide with its curl commands, checked against the guide
zig build examples   # only the service of the guide and its check (Linux and macOS)
zig build check      # build all of it without running it
```

Whenever CI tests http, it builds the package and runs its end-to-end tests on the three systems; a change to `tests/http/` counts as a change to http.

On a shared GitHub runner, 4 vCPUs of an AMD EPYC 7763, a server on zio with four executors, loaded by clients in the same process, answers plain text at about 11 800 requests per second over one connection kept alive and 122 000 over 64, JSON out at 11 700 and 120 000, a JSON body in and JSON out at 11 800 and 116 000; the [benchmark of http](tests/http/bench/README.md) shows the whole run, the spread across runs, and why one connection is faster on one executor.

The end-to-end tests of mongo, with the programs of its guide, are a package of the same kind in `tests/mongo`, against the mongod servers of the profile `mongo` of the same `docker-compose.yml`:

```sh
cd tests/mongo
zig build e2e        # start the servers, run the tests, then the programs of the guide, checking their runs against the guide
zig build stress     # the stress tests, in Debug and in ReleaseSafe
zig build check      # build all of it without running it; no servers needed
zig build down       # stop the servers
```

`MONGO_VERSION` picks the image, 9.0.4 by default: `MONGO_VERSION=7.0.45 zig build e2e`. Whenever CI tests mongo, it builds the package on the three systems and runs its end-to-end tests on Linux against 7.0, 8.0 and 9.0; a change to `tests/mongo/` or to `docker-compose.yml` counts as a change to mongo.

The end-to-end tests of odm, with the programs of its guide, are a package of the same kind in `tests/odm`, against mongo-plain and mongo-auth of the same profile:

```sh
cd tests/odm
zig build e2e        # start the servers, run the tests, then the programs of the guide, checking their runs against the guide
zig build examples   # only the programs of the guide and their check
zig build stress     # the stress tests, in Debug and in ReleaseSafe
zig build check      # build all of it without running it; no servers needed
zig build down       # stop the servers
```

The package stands on odm and on mongo, whose `OdmDriver` it runs: whenever CI tests either of them, it builds the package on the three systems and runs its end-to-end tests on Linux against mongod 9.0; a change to `tests/odm/` or to `docker-compose.yml` counts as a change to odm.

The end-to-end tests of redis, with the programs of its guide, are a package of the same kind in `tests/redis`, against the Redis and Valkey servers of the profile `redis` of the same `docker-compose.yml`:

```sh
cd tests/redis
zig build e2e        # start the servers, run the tests, then the programs of the guide, checking their runs against the guide
zig build stress     # the stress tests, in Debug and in ReleaseSafe
zig build check      # build all of it without running it; no servers needed
zig build down       # stop the servers
```

`REDIS_IMAGE` picks the image, redis:8.10.2 by default: `REDIS_IMAGE=valkey/valkey:9.1.2 zig build e2e`. Whenever CI tests redis, it builds the package on the three systems and runs its end-to-end tests on Linux against Redis 7.2, Redis 8.10 and Valkey 9.1; a change to `tests/redis/` or to `docker-compose.yml` counts as a change to redis.

The end-to-end tests of zefir.App, with the shop of its guide, are a package of the same kind in `tests/app`, on zio:

```sh
cd tests/app
zig build e2e        # the end-to-end tests, programs stopped by SIGTERM, then the shop of the guide with its curl commands, checked against the guide
zig build examples   # only the shop of the guide and its check (Linux and macOS)
zig build shop       # the shop with NATS and MongoDB, shop/, against the servers it starts in Docker
zig build check      # build all of it without running it; no servers needed
```

Whenever CI tests zefir, it builds the package on the three systems and runs its end-to-end tests there; `zig build shop` runs on a developer's machine only. A change to `tests/app/` counts as a change to zefir.

`examples/rpc-custom-transport` is a transport of rpc in a package of its own, the proof that one can be written outside zefir. Its `consumer/` builds it as an application does, against the zefir of this checkout, and CI runs it whenever it tests rpc; a change to the package counts as a change to rpc:

```sh
cd examples/rpc-custom-transport/consumer
zig build test     # the conformance suite of rpc on the transport, its own tests, rpc.Server and rpc.Client over it, and the check of the package's README.md
```

Branches:

- `dev` — the default branch and the next version in progress: its `.version` in `build.zig.zon` is that version with `-dev`, such as `0.2.0-dev`. Every change lands here first, through a squash-merged pull request.
- `feature/<name>` — new functionality; `chore/<name>` — docs, CI, tooling and other maintenance. Both are created from `dev` and merged back into it; a big feature goes in as several smaller pull requests.
- `main` — releases only. A release is a pull request from `dev`, merged with a merge commit and tagged `vX.Y.Z`.
- `hotfix/<name>` — an urgent fix for the latest release: created from `main`, merged into it as a patch release such as `v0.1.1`, and then brought to `dev` as well.
