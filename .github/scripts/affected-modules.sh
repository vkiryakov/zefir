#!/bin/sh
# Prints the modules that a change affects, on one line and separated by
# spaces; CI runs `zig build test-<module>` for each of them.
#
#   affected-modules.sh BASE HEAD   the changes of `git diff BASE...HEAD`
#   affected-modules.sh --all       every module
#
# A file under src/<module>/ affects that module and every module whose
# tests import it, directly or through other modules; zefir imports them
# all. tests/nats/, tests/rpc-nats/, tests/http/ and tests/mongo/, the
# end-to-end tests of nats, of rpc-nats, of http and of mongo, count as
# their modules. tests/openapi/, the checks of the JSON Schema that
# zefir-openapi and the validator write, counts as openapi, which imports
# the validator. docker-compose.yml, the servers of nats, rpc-nats and
# mongo, counts as all three.
# examples/rpc-custom-transport/, a transport outside zefir that CI runs
# against rpc, counts as rpc. build.zig, build.zig.zon, src/zefir.zig,
# .github/ and any other path the script does not know affect every
# module.
# Documentation outside src/ (*.md files and docs/) affects none, but
# README.md at the root: its "rpc in a minute" and "http in a minute" are
# programs of the guides of rpc and of http, which their tests check, so it
# counts as both.
set -eu

# The modules and what the tests of each one import. Keep this in sync with
# build.zig: the `.imports` of each module and of the programs that its
# test-<module> step builds. CI tests only the modules listed here.
modules="core log confy validator rpc rpc-nats orm mongo nats http openapi zefir"
imports() {
    case $1 in
    core) ;;
    log) echo core ;;
    confy) echo log ;;
    # The validator imports nothing, but the examples of its guide log the
    # violations they find.
    validator) echo log ;;
    # rpc imports core and validator, and the examples of its guide read
    # their settings with confy and log with log.
    rpc) echo core validator confy log ;;
    # rpc-nats imports nats for its adapter of zefir-nats, and the examples
    # of its guide, which its end-to-end tests run, read their settings
    # with confy and log with log.
    rpc-nats) echo rpc core nats confy log ;;
    # nats imports nothing, but the examples of its guide read their
    # settings with confy, log with log and take deadlines from core, and
    # its end-to-end tests build and run them. confy brings log.
    nats) echo core confy ;;
    orm) echo log ;;
    # mongo imports core, and the examples of its guide and its end-to-end
    # tests read their settings with confy and log with log.
    mongo) echo core confy log ;;
    # http imports core and validator; the examples of its guide read
    # their settings with confy and log with log.
    http) echo core validator confy log ;;
    # openapi reads the server through http and the rules through the
    # validator.
    openapi) echo http validator ;;
    zefir) echo core log confy validator rpc rpc-nats orm mongo nats http openapi ;;
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
        tests/http/*) changed="$changed http" ;;
        tests/mongo/*) changed="$changed mongo" ;;
        tests/openapi/*) changed="$changed openapi" ;;
        examples/rpc-custom-transport/*) changed="$changed rpc" ;;
        docker-compose.yml) changed="$changed nats rpc-nats mongo" ;;
        README.md) changed="$changed rpc http" ;;
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
