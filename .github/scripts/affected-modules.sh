#!/bin/sh
# Prints the modules that a change affects, on one line and separated by
# spaces; CI runs `zig build test-<module>` for each of them.
#
#   affected-modules.sh BASE HEAD   the changes of `git diff BASE...HEAD`
#   affected-modules.sh --all       every module
#
# A file under src/<module>/ affects that module and every module whose
# tests import it, directly or through other modules; zefir imports them
# all. tests/nats/ and tests/rpc-nats/, the end-to-end tests of nats and
# of rpc-nats, count as their modules, and docker-compose.yml, their
# servers, as both. examples/rpc-custom-transport/, a transport outside
# zefir that CI runs against rpc, counts as rpc. build.zig, build.zig.zon,
# src/zefir.zig, .github/ and any other path the script does not know
# affect every module.
# Documentation outside src/ (*.md files and docs/) affects none.
set -eu

# The modules and what the tests of each one import. Keep this in sync with
# build.zig: the `.imports` of each module and of the programs that its
# test-<module> step builds. CI tests only the modules listed here.
modules="core log confy validator rpc rpc-nats rpc-log orm nats zefir"
imports() {
    case $1 in
    core) ;;
    log) echo core ;;
    confy) echo log ;;
    # The validator imports nothing, but the examples of its guide log the
    # violations they find.
    validator) echo log ;;
    rpc) echo core validator ;;
    # rpc-nats imports nats for its adapter of zefir-nats.
    rpc-nats) echo rpc core nats ;;
    rpc-log) echo rpc core log ;;
    # nats imports nothing, but the examples of its guide read their
    # settings with confy, log with log and take deadlines from core, and
    # its end-to-end tests build and run them. confy brings log.
    nats) echo core confy ;;
    orm) echo log ;;
    zefir) echo core log confy validator rpc rpc-nats rpc-log orm nats ;;
    esac
}

# Succeeds when module $1 imports module $2, directly or through others.
depends_on() {
    for dep in $(imports "$1"); do
        if [ "$dep" = "$2" ] || depends_on "$dep" "$2"; then
            return 0
        fi
    done
    return 1
}

usage() {
    echo "usage: $0 BASE HEAD | --all" >&2
    exit 2
}

all=false
changed=""
if [ $# -eq 1 ] && [ "$1" = --all ]; then
    all=true
elif [ $# -eq 2 ] && [ -n "$1" ] && [ -n "$2" ]; then
    # --no-renames lists both paths of a moved file, so the module the file
    # left counts too.
    paths=$(git -c core.quotePath=false diff --name-only --no-renames "$1...$2")
    while IFS= read -r path; do
        case $path in
        "") ;;
        build.zig | build.zig.zon | src/zefir.zig | .github/*) all=true ;;
        src/*/*)
            module=${path#src/}
            module=${module%%/*}
            case " $modules " in
            *" $module "*) changed="$changed $module" ;;
            *) all=true ;;
            esac
            ;;
        src/*) all=true ;;
        tests/nats/*) changed="$changed nats" ;;
        tests/rpc-nats/*) changed="$changed rpc-nats" ;;
        examples/rpc-custom-transport/*) changed="$changed rpc" ;;
        docker-compose.yml) changed="$changed nats rpc-nats" ;;
        docs/* | *.md) ;;
        *) all=true ;;
        esac
    done <<EOF
$paths
EOF
else
    usage
fi

affected=""
for module in $modules; do
    if [ "$all" = true ]; then
        affected="$affected $module"
        continue
    fi
    for name in $changed; do
        if [ "$module" = "$name" ] || depends_on "$module" "$name"; then
            affected="$affected $module"
            break
        fi
    done
done
echo "${affected# }"
