#!/bin/sh
# Tests affected-modules.sh: each case commits a change on top of a base
# commit in a scratch repository and checks the modules that the script
# prints for it. CI runs it before using the script.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
script=$here/affected-modules.sh
failures=0

# expect NAME EXPECTED GOT
expect() {
    if [ "$3" = "$2" ]; then
        echo "ok    $1"
    else
        echo "FAIL  $1: expected \"$2\", got \"$3\""
        failures=$((failures + 1))
    fi
}

# The script must know every module that build.zig declares: CI tests only
# the modules that the script prints.
declared=$(sed -n 's/.*b\.addModule("\([a-z-]*\)".*/\1/p' "$here/../../build.zig" | sed 's/^zefir-//' | sort)
known=$(sh "$script" --all | tr ' ' '\n' | sort)
expect "the script knows the modules of build.zig" "$(echo $declared)" "$(echo $known)"

# An acceptance criterion of zefir-rpc: it depends on no application
# container and no optional module, so build.zig gives it only core and
# validator.
rpc_imports=$(awk '
    /b\.addModule\("zefir-rpc",/ { inside = 1; next }
    inside && /^    }\);/ { exit }
    inside && match($0, /\.name = "[^"]*"/) { print substr($0, RSTART + 9, RLENGTH - 10) }
' "$here/../../build.zig" | sort)
expect "zefir-rpc imports only core and validator" "core validator" "$(echo $rpc_imports)"
# The same in its code, which an addImport elsewhere in build.zig would
# also reach: only std, builtin, those two and the module's own files.
# src/rpc/tests/ and src/rpc/examples/ hold programs with imports of their
# own.
rpc_foreign=$(grep -rhoE '@import\("[^"]*"\)' "$here/../../src/rpc" --include='*.zig' --exclude-dir=tests --exclude-dir=examples |
    sed 's/@import("\(.*\)")/\1/' | grep -vE '^(std|builtin|core|validator)$|\.zig$' | sort -u)
expect "the code of zefir-rpc imports only std, builtin, core and validator" "" "$(echo $rpc_foreign)"

# The same for zefir-http: it stands on core and validator alone, and its
# code imports nothing else. src/http/tests/ and src/http/examples/ hold
# programs with imports of their own.
http_imports=$(awk '
    /b\.addModule\("zefir-http",/ { inside = 1; next }
    inside && /^    }\);/ { exit }
    inside && match($0, /\.name = "[^"]*"/) { print substr($0, RSTART + 9, RLENGTH - 10) }
' "$here/../../build.zig" | sort)
expect "zefir-http imports only core and validator" "core validator" "$(echo $http_imports)"
http_foreign=$(grep -rhoE '@import\("[^"]*"\)' "$here/../../src/http" --include='*.zig' --exclude-dir=tests --exclude-dir=examples |
    sed 's/@import("\(.*\)")/\1/' | grep -vE '^(std|builtin|core|validator)$|\.zig$' | sort -u)
expect "the code of zefir-http imports only std, builtin, core and validator" "" "$(echo $http_foreign)"

# The same for zefir-openapi: it reads the server through http and the
# rules through the validator, and nothing else; http does not import it.
# src/openapi/tests/ and src/openapi/examples/ hold programs with imports of
# their own.
openapi_imports=$(awk '
    /b\.addModule\("zefir-openapi",/ { inside = 1; next }
    inside && /^    }\);/ { exit }
    inside && match($0, /\.name = "[^"]*"/) { print substr($0, RSTART + 9, RLENGTH - 10) }
' "$here/../../build.zig" | sort)
expect "zefir-openapi imports only http and validator" "http validator" "$(echo $openapi_imports)"
openapi_foreign=$(grep -rhoE '@import\("[^"]*"\)' "$here/../../src/openapi" --include='*.zig' --exclude-dir=tests --exclude-dir=examples |
    sed 's/@import("\(.*\)")/\1/' | grep -vE '^(std|builtin|http|validator)$|\.zig$' | sort -u)
expect "the code of zefir-openapi imports only std, builtin, http and validator" "" "$(echo $openapi_foreign)"

# An acceptance criterion of zefir-mongo: it stands on core alone, so
# build.zig gives it only core.
mongo_imports=$(awk '
    /b\.addModule\("zefir-mongo",/ { inside = 1; next }
    inside && /^    }\);/ { exit }
    inside && match($0, /\.name = "[^"]*"/) { print substr($0, RSTART + 9, RLENGTH - 10) }
' "$here/../../build.zig" | sort)
expect "zefir-mongo imports only core" "core" "$(echo $mongo_imports)"
# The same in its code: only std, builtin, core, build_options, which holds
# the version it sends in hello, and the module's own files.
# src/mongo/tests/, src/mongo/testdata/ and src/mongo/examples/ hold
# programs with imports of their own.
mongo_foreign=$(grep -rhoE '@import\("[^"]*"\)' "$here/../../src/mongo" --include='*.zig' --exclude-dir=tests --exclude-dir=testdata --exclude-dir=examples |
    sed 's/@import("\(.*\)")/\1/' | grep -vE '^(std|builtin|core|build_options)$|\.zig$' | sort -u)
expect "the code of zefir-mongo imports only std, builtin, core and build_options" "" "$(echo $mongo_foreign)"

repo=$(mktemp -d)
trap 'rm -rf "$repo"' EXIT
cd "$repo"
# Keep the global and system git settings, such as commit signing, out.
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_NOSYSTEM=1
GIT_AUTHOR_NAME=test
GIT_AUTHOR_EMAIL=test@example.com
GIT_COMMITTER_NAME=test
GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# edit PATH...: appends a line to each file, creating the file if needed.
edit() {
    for path in "$@"; do
        mkdir -p "$(dirname "$path")"
        echo "$path" >>"$path"
    done
}

git init -q
edit build.zig README.md src/zefir.zig
for module in core log confy validator rpc orm; do
    edit "src/$module/root.zig"
done
git add -A
git commit -q -m base
base=$(git rev-parse HEAD)

# A change, as shell commands, and the modules it affects. The table comes
# on descriptor 3, so that no command in the loop reads it from stdin.
while IFS='|' read -r change modules <&3; do
    git checkout -q --detach "$base"
    eval "$change"
    git add -A
    git commit -q -m "$change"
    expect "$(echo $change)" "$(echo $modules)" "$(sh "$script" "$base" HEAD)"
done 3<<'EOF'
edit src/core/Context.zig                       | core log confy validator rpc rpc-nats orm mongo nats http openapi zefir
edit src/log/Logger.zig                         | log confy validator rpc rpc-nats orm mongo nats http openapi zefir
edit src/confy/root.zig                         | confy rpc rpc-nats mongo nats http openapi zefir
edit src/validator/strings.zig                  | validator rpc rpc-nats http openapi zefir
edit src/rpc/root.zig                           | rpc rpc-nats zefir
edit src/orm/root.zig                           | orm zefir
edit src/rpc/root.zig src/orm/root.zig          | rpc rpc-nats orm zefir
edit src/mongo/bson.zig                         | mongo zefir
edit src/mongo/bson/RawDocument.zig             | mongo zefir
edit src/orm/root.zig src/mongo/root.zig        | orm mongo zefir
edit src/mongo/Client.zig                       | mongo zefir
edit src/mongo/engine/Connection.zig            | mongo zefir
edit src/rpc-nats/Transport.zig                 | rpc-nats zefir
edit src/nats/Client.zig                        | rpc-nats nats zefir
edit tests/nats/e2e/pubsub.zig                  | rpc-nats nats zefir
edit tests/nats/README.md                       | rpc-nats nats zefir
edit docker-compose.yml                         | rpc-nats mongo nats zefir
edit tests/rpc-nats/e2e/root.zig                | rpc-nats zefir
edit tests/rpc-nats/conf/acl.conf               | rpc-nats zefir
edit tests/http/build.zig                       | http openapi zefir
edit tests/mongo/e2e/crud.zig                   | mongo zefir
edit tests/mongo/build.zig.zon                  | mongo zefir
edit tests/mongo/stress/storm.zig               | mongo zefir
edit tests/openapi/build.zig                    | openapi zefir
edit tests/openapi/node/regex.mjs               | openapi zefir
edit examples/rpc-custom-transport/src/root.zig | rpc rpc-nats zefir
edit examples/rpc-custom-transport/consumer/build.zig | rpc rpc-nats zefir
edit examples/rpc-custom-transport/README.md    | rpc rpc-nats zefir
edit examples/other/main.zig                    | core log confy validator rpc rpc-nats orm mongo nats http openapi zefir
edit src/core/root.zig src/nats/root.zig        | core log confy validator rpc rpc-nats orm mongo nats http openapi zefir
edit src/confy/examples/README.md               | confy rpc rpc-nats mongo nats http openapi zefir
edit README.md src/validator/root.zig           | validator rpc rpc-nats http openapi zefir
edit README.md                                  | rpc rpc-nats http openapi zefir
edit docs/plan.md docs/notes.txt                |
edit build.zig                                  | core log confy validator rpc rpc-nats orm mongo nats http openapi zefir
edit build.zig.zon                              | core log confy validator rpc rpc-nats orm mongo nats http openapi zefir
edit src/zefir.zig                              | core log confy validator rpc rpc-nats orm mongo nats http openapi zefir
edit .github/workflows/ci.yml                   | core log confy validator rpc rpc-nats orm mongo nats http openapi zefir
edit src/http/root.zig                          | http openapi zefir
edit src/openapi/schema.zig                     | openapi zefir
edit src/ws/root.zig                            | core log confy validator rpc rpc-nats orm mongo nats http openapi zefir
edit src/helpers.zig                            | core log confy validator rpc rpc-nats orm mongo nats http openapi zefir
edit src/notes.md                               | core log confy validator rpc rpc-nats orm mongo nats http openapi zefir
edit tests/other/main.zig                       | core log confy validator rpc rpc-nats orm mongo nats http openapi zefir
edit LICENSE                                    | core log confy validator rpc rpc-nats orm mongo nats http openapi zefir
git rm -q src/log/root.zig                      | log confy validator rpc rpc-nats orm mongo nats http openapi zefir
git mv src/orm/root.zig src/rpc/orm.zig         | rpc rpc-nats orm zefir
EOF

# Only the changes on HEAD's side count: here the base moved on with a
# change to build.zig after HEAD branched off.
git checkout -q --detach "$base"
edit build.zig
git commit -q -am "later base"
later=$(git rev-parse HEAD)
git checkout -q --detach "$base"
edit src/validator/root.zig
git commit -q -am "head"
expect "a later base" "validator rpc rpc-nats http openapi zefir" "$(sh "$script" "$later" HEAD)"

expect "--all" "core log confy validator rpc rpc-nats orm mongo nats http openapi zefir" "$(sh "$script" --all)"

if [ "$failures" -ne 0 ]; then
    echo "$failures failed"
    exit 1
fi
