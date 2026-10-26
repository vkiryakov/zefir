//! The compile-time checks behind `Store.init(impl)`: a mistake in a
//! store's method stops the build with a message that names the method and
//! the signature to write, instead of an error deep inside the scheduler.

const std = @import("std");

/// The type that `Impl` points to. Stops the build unless `Impl` is a
/// pointer to one mutable struct, union, enum or opaque. `interface` names
/// the caller in the message ("scheduler: Store.init"), `noun` what to pass
/// ("store").
pub fn expectPointer(comptime interface: []const u8, comptime noun: []const u8, comptime Impl: type) type {
    const not_a_pointer = interface ++ ": pass a pointer to the " ++ noun ++ ", e.g. &" ++ noun ++ "; got " ++ shortName(Impl);
    const ptr = switch (@typeInfo(Impl)) {
        .pointer => |ptr| ptr,
        else => @compileError(not_a_pointer),
    };
    if (ptr.size != .one) @compileError(not_a_pointer);
    switch (@typeInfo(ptr.child)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => @compileError(not_a_pointer),
    }
    if (ptr.attrs.@"const")
        @compileError(interface ++ ": the " ++ noun ++ " must be mutable, declared with var; got " ++ shortName(Impl));
    return ptr.child;
}

/// Stops the build unless `T` has a method `name` of type `Expected`.
/// `declaration` is how to declare it, for the message.
pub fn expectMethod(
    comptime interface: []const u8,
    comptime T: type,
    comptime name: []const u8,
    comptime Expected: type,
    comptime declaration: []const u8,
) void {
    if (!@hasDecl(T, name))
        @compileError(interface ++ ": " ++ shortName(T) ++ " has no method " ++ name ++ "; expected " ++ declaration);
    if (@TypeOf(@field(T, name)) != Expected)
        @compileError(interface ++ ": " ++ shortName(T) ++ "." ++ name ++ " has the wrong signature; expected " ++ declaration);
}

/// Whether `S` is the type of a string: a slice of bytes or a pointer to an
/// array of them, as a string literal is.
pub fn isString(comptime S: type) bool {
    return switch (@typeInfo(S)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

/// The name of `T` in messages, without its namespaces: "app.BadStore" is
/// "BadStore", "*const app.BadStore" is "*const BadStore", and
/// "app.Page(app.Todo)" is "Page(app.Todo)".
pub fn shortName(comptime T: type) []const u8 {
    const full = @typeName(T);
    var depth: usize = 0;
    // Where the qualified name starts, and its last dot outside parentheses.
    var start: usize = 0;
    var dot: ?usize = null;
    for (full, 0..) |c, i| switch (c) {
        '(' => depth += 1,
        ')' => depth -= 1,
        '.' => if (depth == 0) {
            dot = i;
        },
        ' ', '*', ']', '?', '!' => if (depth == 0 and dot == null) {
            start = i + 1;
        },
        else => {},
    };
    const last = dot orelse return full;
    return full[0..start] ++ full[last + 1 ..];
}

test "the pointee of a pointer to a mutable container" {
    const S = struct { x: u8 };
    const O = opaque {};
    try std.testing.expect(expectPointer("scheduler: X.init", "x", *S) == S);
    try std.testing.expect(expectPointer("scheduler: X.init", "x", *O) == O);
}

test "a method of the expected type passes" {
    const S = struct {
        pub fn get(self: *@This()) u8 {
            _ = self;
            return 1;
        }
    };
    comptime expectMethod("scheduler: X.init", S, "get", fn (*S) u8, "pub fn get(self: *S) u8");
}

test "short names drop the namespaces" {
    const Todo = struct { x: u8 };
    try std.testing.expectEqualStrings("Todo", comptime shortName(Todo));
    try std.testing.expectEqualStrings("*const Todo", comptime shortName(*const Todo));
    try std.testing.expectEqualStrings("[]Todo", comptime shortName([]Todo));
    try std.testing.expectEqualStrings("u8", comptime shortName(u8));
    try std.testing.expect(isString(@TypeOf("memory")));
    try std.testing.expect(isString([]const u8));
    try std.testing.expect(!isString(u8));
}
