//! The guide of rpc-nats, src/rpc-nats/examples/README.md, against what
//! its examples printed in this build, on the servers of the repository's
//! docker-compose.yml, and against the configuration of the server with
//! the permissions of the guide, conf/acl.conf. The build embeds the guide
//! as `guide`, each example as `<name>.zig` and its output as `<name>.out`,
//! and the configuration as `acl.conf`.

const std = @import("std");
const check = @import("guide-check");
const examples = @import("guide_examples");

const guide = @embedFile("guide");
const name = "src/rpc-nats/examples/README.md";

test "the guide shows a run of every example as it printed, after the example" {
    inline for (examples.names, examples.commands) |example, command| {
        try check.expectRun(name, guide, @embedFile(example ++ ".zig"), command, @embedFile(example ++ ".out"));
    }
}

test "the guide shows the configuration of the permissions as it is" {
    try check.expectFile(name, guide, "text", @embedFile("acl.conf"));
}
