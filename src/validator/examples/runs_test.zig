//! Every program of `cases.examples` logs its `records` and nothing else:
//! build.zig runs each program and hands this test what it printed, as the
//! anonymous import `<name>.out`, and its lines must be the lines of
//! `records`, in order, each after a timestamp. readme_test.zig checks that
//! README.md shows the same records, so a record that a program adds, drops
//! or moves fails one of the two. This test is not built for
//! compile-validator-tests: it needs the runs of the programs, which import
//! zefir-log, and zefir-log does not build for x86-linux-musl, the 32-bit
//! target of that step.

const std = @import("std");
const cases = @import("cases");
const check = @import("guide_check.zig");

test "every program logs its records and nothing else" {
    inline for (cases.examples) |example| {
        if (example.records) |records| {
            const out = @embedFile(example.name ++ ".out");
            if (!check.showsRecords(out, records)) {
                std.debug.print("{s} logged:\n{s}\nnot its records:\n{s}\n", .{ example.name, out, records });
                return error.TestRunDiffers;
            }
        }
    }
}
