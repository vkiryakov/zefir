//! The compile-time checks behind `init(impl)` of the transport interfaces:
//! a mistake in a transport's method stops the build with a message that
//! names the method and the signature to write, instead of an error deep
//! inside rpc.

const std = @import("std");

/// The type that `Impl` points to. Stops the build unless `Impl` is a
/// pointer to one mutable struct, union, enum or opaque. `interface` names
/// the caller in the message ("rpc.ClientTransport"), `noun` what to pass
/// ("transport").
pub fn expectPointer(comptime interface: []const u8, comptime noun: []const u8, comptime Impl: type) type {
    const not_a_pointer = interface ++ ".init: pass a pointer to the " ++ noun ++ ", e.g. &" ++ noun ++ "; got " ++ @typeName(Impl);
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
        @compileError(interface ++ ".init: the " ++ noun ++ " must be mutable, declared with var; got " ++ @typeName(Impl));
    return ptr.child;
}

/// Stops the build unless `T` has a method `name` of type `Expected`.
/// `signature` is how to declare it, for the message.
pub fn expectMethod(
    comptime interface: []const u8,
    comptime T: type,
    comptime name: []const u8,
    comptime Expected: type,
    comptime signature: []const u8,
) void {
    if (!@hasDecl(T, name))
        @compileError(interface ++ ".init: " ++ @typeName(T) ++ " has no method " ++ name ++ "; expected " ++ signature);
    if (@TypeOf(@field(T, name)) != Expected)
        @compileError(interface ++ ".init: " ++ @typeName(T) ++ "." ++ name ++ " has another signature; expected " ++ signature);
}

test "the pointee of a pointer to a mutable container" {
    const S = struct { x: u8 };
    const O = opaque {};
    try std.testing.expect(expectPointer("rpc.X", "x", *S) == S);
    try std.testing.expect(expectPointer("rpc.X", "x", *O) == O);
}

test "a method of the expected type passes" {
    const S = struct {
        pub fn get(self: *@This()) u8 {
            _ = self;
            return 1;
        }
    };
    comptime expectMethod("rpc.X", S, "get", fn (*S) u8, "pub fn get(self: *@This()) u8");
}
