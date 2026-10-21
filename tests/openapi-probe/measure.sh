#!/usr/bin/env bash
# The measurement of design 1.2 of zefir-openapi, section 16, for one size
# of the synthetic application:
#
#   measure.sh <routes> <out-dir> <variant>...   measure these variants (baseline b a afill acount naive)
#   measure.sh --check <out-dir>                 check the documents, print the table
#
# Each variant is one process of `zig build-exe`, Debug, with LLVM (the
# backend of a Debug build on a Mac; on x86_64 Linux Zig would take its
# own), the modules wired by hand as `zig build` wires them:
# - cold: fresh local and global caches, as after removing .zig-cache and
#   the global cache;
# - warm: the same caches, after the description of one DTO changed;
# each with its wall time and the compiler's CPU time and peak RSS
# (/usr/bin/time -v). Then the program of the cold build runs: its size,
# its document, and for B how long writing the document takes.
#
# A watchdog kills a compiler above LIMIT_KB of RSS, a build longer than
# BUILD_TIMEOUT seconds is killed, and no warm build follows a cold one of
# more than SKIP_WARM_AFTER seconds: all are results, not errors. The rows
# go to <out-dir>/results.tsv, one call after another; with STRICT=1 a
# build that fails is an error.
set -u -o pipefail

here=$(cd "$(dirname "$0")" && pwd)
zefir=$(cd "$here/../.." && pwd)

if [ "${1:-}" = --check ]; then
  out=$(cd "$2" && pwd)
  {
    for doc in "$out"/doc-*.json; do
      [ -f "$doc" ] || continue
      if python3 -I -c 'import json, sys; json.load(open(sys.argv[1]))' "$doc"; then
        echo "$(basename "$doc"): valid JSON"
      else
        echo "$(basename "$doc"): NOT valid JSON"
      fi
    done
    for other in b afill naive; do
      if [ -f "$out/doc-a.json" ] && [ -f "$out/doc-$other.json" ]; then
        if cmp -s "$out/doc-a.json" "$out/doc-$other.json"; then
          echo "doc-a.json and doc-$other.json: the same bytes"
        else
          echo "doc-a.json and doc-$other.json: DIFFER"
        fi
      fi
    done
  } | tee "$out/documents.txt"
  python3 -I "$here/summarize.py" "$out/results.tsv" | tee "$out/summary.md"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      cat "$out/summary.md"
      echo
      sed 's/^/- /' "$out/documents.txt"
    } >>"$GITHUB_STEP_SUMMARY"
  fi
  ! grep -q 'DIFFER\|NOT valid' "$out/documents.txt"
  exit
fi

# The smallest eval branch quota of the document that builds: a root module
# that sets `openapi_quota`, Sema only (-fno-emit-bin), the quota doubled
# from 1M until the build passes, then halved to within 2%.
if [ "${1:-}" = --quota ]; then
  routes=$2
  mkdir -p "$3"
  out=$(cd "$3" && pwd)
  variant=$4
  case "$variant" in
    a) decl=A ;;
    b) decl=B ;;
    afill) decl=AFill ;;
    *) echo "measure.sh --quota: the variant is a, b or afill" >&2; exit 2 ;;
  esac
  work=${WORK:-$out/work-quota-$variant}
  mkdir -p "$work"
  python3 -I "$here/gen_app.py" "$routes" "$work/app.zig" || exit 1
  root="$here/main_quota_$variant.zig"
  builds=0
  # passes <quota>: 0 when the build passes, 1 when the quota stops it.
  passes() {
    local start end status log="$out/quota-n$routes-$variant-$1.log"
    printf '%s\n' \
      'const std = @import("std");' \
      "pub const openapi_quota: u32 = $1;" \
      'pub const panic = std.debug.FullPanic(exitOnPanic);' \
      'fn exitOnPanic(message: []const u8, _: ?usize) noreturn {' \
      '    std.debug.print("panic: {s}\n", .{message});' \
      '    std.process.exit(3);' \
      '}' \
      'pub fn main(init: std.process.Init) !void {' \
      "    return @import(\"run.zig\").run(init, @import(\"openapi\").$decl);" \
      '}' >"$root"
    builds=$((builds + 1))
    start=$(date +%s.%N)
    timeout --signal=KILL 900 zig build-exe -fllvm -fno-emit-bin --name "quota-$variant" \
      --dep app --dep openapi --dep http "-Mroot=$root" \
      --dep http --dep validator --dep openapi "-Mapp=$work/app.zig" \
      --dep http --dep validator "-Mopenapi=$here/openapi.zig" \
      --dep core --dep validator "-Mhttp=$zefir/src/http/root.zig" \
      "-Mvalidator=$zefir/src/validator/root.zig" \
      "-Mcore=$zefir/src/core/root.zig" \
      --cache-dir "$work/cache/local" --global-cache-dir "$work/cache/global" >"$log" 2>&1
    status=$?
    end=$(date +%s.%N)
    echo "quota $1: status $status in $(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.1f", b - a }') s"
    [ "$status" -eq 0 ] && return 0
    grep -q 'evaluation exceeded' "$log" && return 1
    echo "measure.sh --quota: the build failed for another reason:" >&2
    tail -n 60 "$log" >&2
    exit 1
  }
  low=0
  high=1048576
  until passes "$high"; do
    [ "$high" -lt 4294967295 ] || { echo "measure.sh --quota: over the largest quota" >&2; exit 1; }
    low=$high
    high=$((high * 2))
    [ "$high" -le 4294967295 ] || high=4294967295
  done
  while [ $((high - low)) -gt $((high / 50)) ]; do
    middle=$(((low + high) / 2))
    if passes "$middle"; then high=$middle; else low=$middle; fi
  done
  rm -f "$root"
  [ -f "$out/quota.tsv" ] || printf 'routes\tvariant\tquota_fails\tquota_passes\tbuilds\n' >"$out/quota.tsv"
  printf '%s\t%s\t%s\t%s\t%s\n' "$routes" "$variant" "$low" "$high" "$builds" >>"$out/quota.tsv"
  echo "- $routes routes, $variant: the document builds with an eval branch quota of $high, not with $low ($builds Sema-only builds)" |
    tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
fi

if [ $# -lt 3 ]; then
  echo "usage: measure.sh <routes> <out-dir> <variant>... | measure.sh --check <out-dir> | measure.sh --quota <routes> <out-dir> <variant>" >&2
  exit 2
fi
routes=$1
mkdir -p "$2"
out=$(cd "$2" && pwd)
shift 2
work=${WORK:-$out/work}
limit_kb=${LIMIT_KB:-14000000}
build_timeout=${BUILD_TIMEOUT:-1500}
skip_warm_after=${SKIP_WARM_AFTER:-900}
mkdir -p "$work"

{
  echo "routes: $routes, variants: $*"
  echo "cpus: $(nproc)"
  grep -m1 'model name' /proc/cpuinfo || true
  free -m || true
  zig version
} | tee -a "$out/runner.txt"

marker='A new item of resource 0_0.'
if [ ! -f "$work/app.orig.zig" ]; then
  python3 -I "$here/gen_app.py" "$routes" "$work/app.orig.zig" || exit 1
fi
grep -q "$marker" "$work/app.orig.zig" || { echo "measure.sh: no '$marker' in the app" >&2; exit 1; }

# The wall time of the last build, and its result.
elapsed=0
result=

# The peak RSS of every zig process while $1 runs, in kB, into $2.sampled;
# kills a compiler above limit_kb and notes it in $2.killed.
watch_memory() {
  local pid=$1 tag=$2 peak=0 p rss
  while kill -0 "$pid" 2>/dev/null; do
    for p in $(pgrep -x zig); do
      rss=$(awk '/^VmRSS:/ {print $2}' "/proc/$p/status" 2>/dev/null)
      [ -n "$rss" ] || continue
      [ "$rss" -gt "$peak" ] && peak=$rss
      if [ "$rss" -gt "$limit_kb" ]; then
        kill -9 "$p" 2>/dev/null
        echo "$rss" >"$out/$tag.killed"
      fi
    done
    sleep 1
  done
  echo "$peak" >"$out/$tag.sampled"
}

# The peak RSS of a build, in kB: the larger of GNU time's and the
# watchdog's; GNU time misses the compiler that timeout killed.
rss_of() {
  local kb sampled
  kb=$(awk -F': ' '/Maximum resident set size/ {print $2}' "$out/$1.time" 2>/dev/null)
  sampled=$(cat "$out/$1.sampled" 2>/dev/null)
  [ "${sampled:-0}" -gt "${kb:-0}" ] && kb=$sampled
  echo "${kb:-0}"
}

cpu_of() {
  awk -F': ' '/User time/ {u = $2} /System time/ {s = $2} END { printf "%.1f", u + s }' "$out/$1.time" 2>/dev/null
}

# build <variant> <cache-dir> <tag>: one compile of the variant's program.
build() {
  local variant=$1 cache=$2 tag=$3 start end status pid watcher
  start=$(date +%s.%N)
  /usr/bin/time -v -o "$out/$tag.time" \
    timeout --signal=KILL "$build_timeout" \
    zig build-exe -fllvm --name "probe-$variant" \
    --dep app --dep openapi --dep http "-Mroot=$here/main_$variant.zig" \
    --dep http --dep validator --dep openapi "-Mapp=$work/app.zig" \
    --dep http --dep validator "-Mopenapi=$here/openapi.zig" \
    --dep core --dep validator "-Mhttp=$zefir/src/http/root.zig" \
    "-Mvalidator=$zefir/src/validator/root.zig" \
    "-Mcore=$zefir/src/core/root.zig" \
    --cache-dir "$cache/local" --global-cache-dir "$cache/global" \
    "-femit-bin=$work/probe-$variant" >"$out/$tag.log" 2>&1 &
  pid=$!
  watch_memory "$pid" "$tag" &
  watcher=$!
  wait "$pid"
  status=$?
  # Before the watchdog's last second of sleep.
  end=$(date +%s.%N)
  wait "$watcher"
  elapsed=$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.1f", b - a }')
  if [ "$status" -eq 0 ]; then
    result=ok
  elif [ -f "$out/$tag.killed" ]; then
    result="killed above $(awk '{ printf "%.1f", $1 / 1048576 }' "$out/$tag.killed") GB"
  elif awk -v e="$elapsed" -v t="$build_timeout" 'BEGIN { exit !(e >= t - 1) }'; then
    result="timeout after ${build_timeout} s"
  else
    result="error $status"
  fi
  echo "== $tag: $result in $elapsed s, CPU $(cpu_of "$tag") s, peak RSS $(rss_of "$tag") kB"
  if [ "$result" != ok ]; then
    echo "-- the end of $tag.log:"
    tail -n 100 "$out/$tag.log"
  fi
}

if [ ! -f "$out/results.tsv" ]; then
  printf 'routes\tvariant\tcold_s\tcold_cpu_s\tcold_rss_kb\tcold_result\twarm_s\twarm_cpu_s\twarm_rss_kb\twarm_result\tbin_bytes\tdoc_bytes\twrite_us_first\twrite_us_min\n' >"$out/results.tsv"
fi

failed=0
for variant in "$@"; do
  cache="$work/cache-$variant"
  rm -rf "$cache" "$work/probe-$variant" "$work/probe-$variant.cold"
  mkdir -p "$cache"
  cp "$work/app.orig.zig" "$work/app.zig"

  build "$variant" "$cache" "n$routes-$variant-cold"
  cold_s=$elapsed
  cold_result=$result
  cold_cpu=$(cpu_of "n$routes-$variant-cold")
  cold_kb=$(rss_of "n$routes-$variant-cold")
  [ "$cold_result" = ok ] && cp "$work/probe-$variant" "$work/probe-$variant.cold"

  warm_s=- warm_cpu=- warm_kb=- warm_result="not run"
  if [ "$cold_result" = ok ] && awk -v e="$cold_s" -v t="$skip_warm_after" 'BEGIN { exit !(e <= t) }'; then
    sed "s/$marker/A new item of resource 0_0, changed./" "$work/app.orig.zig" >"$work/app.zig"
    build "$variant" "$cache" "n$routes-$variant-warm"
    warm_s=$elapsed
    warm_result=$result
    warm_cpu=$(cpu_of "n$routes-$variant-warm")
    warm_kb=$(rss_of "n$routes-$variant-warm")
  elif [ "$cold_result" = ok ]; then
    warm_result="skipped: cold over ${skip_warm_after} s"
  fi
  cp "$work/app.orig.zig" "$work/app.zig"

  bin_bytes=- doc_bytes=- write_first=- write_min=-
  if [ "$cold_result" = ok ]; then
    bin_bytes=$(stat -c %s "$work/probe-$variant.cold")
    if timeout 300 "$work/probe-$variant.cold" "$out/doc-$variant.json" >"$out/run-$variant.txt" 2>&1; then
      doc_bytes=$(grep -o 'doc_bytes=[0-9]*' "$out/run-$variant.txt" | cut -d= -f2)
      write_first=$(grep -o 'write_us_first=[0-9]*' "$out/run-$variant.txt" | cut -d= -f2)
      write_min=$(grep -o 'write_us_min=[0-9]*' "$out/run-$variant.txt" | cut -d= -f2)
    else
      doc_bytes="run failed"
      failed=1
    fi
    echo "-- probe-$variant:"
    cat "$out/run-$variant.txt"
  fi
  [ "$cold_result" = ok ] || failed=1
  case "$warm_result" in ok | skipped*) ;; *) failed=1 ;; esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$routes" "$variant" \
    "$cold_s" "$cold_cpu" "$cold_kb" "$cold_result" "$warm_s" "$warm_cpu" "$warm_kb" "$warm_result" \
    "$bin_bytes" "${doc_bytes:--}" "${write_first:--}" "${write_min:--}" >>"$out/results.tsv"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "- $routes routes, $variant: cold $cold_result, $cold_s s, $cold_kb kB; warm $warm_result, $warm_s s, $warm_kb kB; binary $bin_bytes B; document $doc_bytes B; write $write_min us" >>"$GITHUB_STEP_SUMMARY"
  fi
  rm -rf "$cache"
done

if [ -n "${STRICT:-}" ] && [ "$failed" -ne 0 ]; then
  echo "measure.sh: a build or a run failed" >&2
  exit 1
fi
exit 0
