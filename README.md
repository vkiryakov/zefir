<h1 align="center">
  <img src="logo.png" alt="zefir" width="400">
</h1>

[![CI](https://github.com/vkiryakov/zefir/actions/workflows/ci.yml/badge.svg?branch=dev)](https://github.com/vkiryakov/zefir/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A modular application framework for [Zig](https://ziglang.org).

> **Status: early development.** confy is ready to use; logger, rpc and orm are placeholders without an API yet.
> Until 1.0, breaking changes may happen in any minor release.

## Modules

| Module         | Import name (for `dep.module(...)`) | Purpose                                                    | Status                                        |
| -------------- | ----------------------------------- | ---------------------------------------------------------- | --------------------------------------------- |
| confy          | `zefir-confy`                       | Configuration from JSON, INI, `.env` files and environment | usable — [docs](src/confy/examples/README.md) |
| logger         | `zefir-logger`                      | Logging                                                    | placeholder                                   |
| rpc            | `zefir-rpc`                         | RPC                                                        | placeholder                                   |
| orm            | `zefir-orm`                         | ORM                                                        | placeholder                                   |
| _all of above_ | `zefir`                             | Umbrella module                                            |                                               |

Each module can be used on its own, or all of them through the umbrella module `zefir`.

## Requirements

Zig **0.17.0**.

## Installation

Add the dependency to your `build.zig.zon`. The latest release is **v0.1.0**:

```sh
zig fetch --save git+https://github.com/vkiryakov/zefir#v0.1.0
```

Other versions are on the [releases page](https://github.com/vkiryakov/zefir/releases); a commit hash works too.

Then import the modules you need in your `build.zig`:

```zig
const zefir = b.dependency("zefir", .{
    .target = target,
    .optimize = optimize,
});

const exe = b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            // a single module...
            .{ .name = "confy", .module = zefir.module("zefir-confy") },
            // ...or everything at once
            .{ .name = "zefir", .module = zefir.module("zefir") },
        },
    }),
});
```

And use them in code:

```zig
const confy = @import("confy");
const zefir = @import("zefir"); // zefir.confy, zefir.logger, ...
```

## Development

```sh
zig build test --summary all                  # run all tests
zig fmt --check build.zig build.zig.zon src   # check formatting
```

Branches:

- `dev` — default branch, all work lands here via pull requests.
- `feature/<name>` — feature branches, created from `dev`.
- `main` — releases only; each release is tagged `vX.Y.Z`.

## License

[MIT](LICENSE)
