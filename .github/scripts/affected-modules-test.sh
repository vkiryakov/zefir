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
edit src/core/Context.zig                       | core log confy validator rpc orm zefir
edit src/log/Logger.zig                         | log confy validator rpc orm zefir
edit src/confy/root.zig                         | confy zefir
edit src/validator/strings.zig                  | validator rpc zefir
edit src/rpc/root.zig                           | rpc zefir
edit src/orm/root.zig                           | orm zefir
edit src/rpc/root.zig src/orm/root.zig          | rpc orm zefir
edit src/confy/examples/README.md               | confy zefir
edit README.md src/validator/root.zig           | validator rpc zefir
edit README.md                                  |
edit docs/plan.md docs/notes.txt                |
edit build.zig                                  | core log confy validator rpc orm zefir
edit build.zig.zon                              | core log confy validator rpc orm zefir
edit src/zefir.zig                              | core log confy validator rpc orm zefir
edit .github/workflows/ci.yml                   | core log confy validator rpc orm zefir
edit src/nats/root.zig                          | core log confy validator rpc orm zefir
edit src/helpers.zig                            | core log confy validator rpc orm zefir
edit src/notes.md                               | core log confy validator rpc orm zefir
edit LICENSE                                    | core log confy validator rpc orm zefir
git rm -q src/log/root.zig                      | log confy validator rpc orm zefir
git mv src/orm/root.zig src/rpc/orm.zig         | rpc orm zefir
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
expect "a later base" "validator rpc zefir" "$(sh "$script" "$later" HEAD)"

expect "--all" "core log confy validator rpc orm zefir" "$(sh "$script" --all)"

if [ "$failures" -ne 0 ]; then
    echo "$failures failed"
    exit 1
fi
