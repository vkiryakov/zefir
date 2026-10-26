//! Must not compile: a `When` built at run time takes a schedule whose
//! arguments the compiler knows, and checks it.
const scheduler = @import("scheduler");

test {
    var when: scheduler.When = .{ .repeat = .weeklyOn(.friday, 5, 0, 60, .pm) };
    _ = &when;
}
