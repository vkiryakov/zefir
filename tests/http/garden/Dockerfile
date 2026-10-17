# The target of zefir-http in the HTTP Garden: the echo server of
# tests/http/garden/echo.zig, on http.native and zio, built with Zig 0.17.0
# on the Garden's base image. Its build context is a directory of the
# Garden's images/ with this Dockerfile and a copy of zefir in zefir/:
# the files of its package (build.zig, build.zig.zon, src/, README.md,
# LICENSE) and tests/http/ (see README.md).
FROM http-garden-soil:latest

RUN apt -y update \
 && apt -y install --no-install-recommends curl xz-utils

# Zig 0.17.0 for x86_64 Linux, the machines the Garden runs on in CI.
ARG ZIG_TARBALL=https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz
ARG ZIG_SHA256=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
RUN curl -sSfL "$ZIG_TARBALL" -o zig.tar.xz \
 && echo "$ZIG_SHA256  zig.tar.xz" | sha256sum -c - \
 && mkdir /opt/zig \
 && tar -xJf zig.tar.xz -C /opt/zig --strip-components=1 \
 && rm zig.tar.xz

# The echo server, in ReleaseSafe: a broken safety check still panics.
COPY zefir /app/zefir
RUN cd /app/zefir/tests/http \
 && /opt/zig/zig build garden-echo -Doptimize=ReleaseSafe \
 && cp zig-out/bin/zefir-garden-echo /app/zefir-garden-echo

CMD ["/app/zefir-garden-echo"]
