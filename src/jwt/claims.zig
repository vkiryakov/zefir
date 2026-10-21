//! The claims of a token. The application describes its own claims as a
//! struct, `Claims`, which `verify` fills from the payload and `sign`
//! writes into it; the registered claims of RFC 7519 §4.1 ("iss", "sub",
//! "aud", "exp", "nbf", "iat", "jti") are jwt's own, in `jwt.Registered`,
//! and the struct never names them at its top level.
//!
//! | Field        | From JSON                                    |
//! |--------------|----------------------------------------------|
//! | `bool`       | `true`, `false`                              |
//! | an integer   | a number without a fraction or an exponent   |
//! | `f32`, `f64` | a number, finite                             |
//! | an enum      | a string, the name of a variant              |
//! | `[]const u8` | a string                                     |
//! | `[]const T`  | an array                                     |
//! | `?T`         | `null`, or the claim absent                  |
//! | a struct     | an object, with its own names and rules      |
//!
//! A claim's name is its entry in `pub const claim_names`, such as
//! `.{ .is_root = "http://example.com/is_root" }`, or else the outside name
//! of zefir-validator: `v.rename("userName")` or the Zig name. A type the
//! table does not have, a claims type that contains itself, and a name
//! that is empty, given twice or registered stop the build with a message
//! that starts with `jwt: `.

const std = @import("std");
const v = @import("validator");
const root = @import("root.zig");
const errors = @import("errors.zig");
const json = @import("json.zig");

const Details = errors.Details;
const VerifyError = errors.VerifyError;

/// The registered claims (RFC 7519 §4.1), which jwt sets and checks itself.
pub const registered_names = [_][]const u8{ "iss", "sub", "aud", "exp", "nbf", "iat", "jti" };

/// The name of the claim that `field` of `T` holds: its entry in
/// `T.claim_names`, or else its outside name for zefir-validator.
pub fn nameOf(comptime T: type, comptime field: std.meta.FieldEnum(T)) []const u8 {
    comptime {
        if (claimName(T, @tagName(field))) |name| return name;
        return v.nameOf(T, field);
    }
}

/// Stops the build when `Claims` cannot be the claims of `verify` and
/// `sign`: when it is not `void` or a struct of the types of the table,
/// when it contains itself, or when its names are wrong.
pub fn check(comptime Claims: type) void {
    comptime {
        @setEvalBranchQuota(100_000);
        if (Claims == void) return;
        if (isPlainStruct(Claims)) return checkStruct(Claims, @typeName(Claims), true, &.{});
        @compileError("jwt: " ++ @typeName(Claims) ++ ": claims are a struct, or void when jwt.Registered is enough");
    }
}

fn checkStruct(comptime S: type, comptime label: []const u8, comptime top: bool, comptime outer: []const type) void {
    const info = @typeInfo(S).@"struct";
    if (@hasDecl(S, "claim_names")) {
        const Names = @TypeOf(S.claim_names);
        if (!isPlainStruct(Names))
            @compileError("jwt: " ++ label ++ ".claim_names: write .{ .field = \"name\" }, such as .{ .is_root = \"http://example.com/is_root\" }");
        for (@typeInfo(Names).@"struct".field_names) |entry| {
            if (!@hasField(S, entry)) @compileError("jwt: " ++ label ++ ".claim_names." ++ entry ++ ": " ++ label ++ " has no field " ++ entry);
            const name = asName(@field(S.claim_names, entry));
            if (name == null or name.?.len == 0 or !std.unicode.utf8ValidateSlice(name.?))
                @compileError("jwt: " ++ label ++ ".claim_names." ++ entry ++ ": a claim name is a non-empty string of UTF-8, such as \"https://shop.example.com/" ++ entry ++ "\"");
            if (!std.mem.eql(u8, v.nameOf(S, @field(std.meta.FieldEnum(S), entry)), entry))
                @compileError("jwt: " ++ label ++ "." ++ entry ++ ": both claim_names and v.rename name the field; keep one of them");
        }
    }
    for (info.field_names, info.field_attrs, 0..) |field, attrs, i| {
        if (attrs.@"comptime") continue;
        const name = nameOf(S, @field(std.meta.FieldEnum(S), field));
        if (!std.unicode.utf8ValidateSlice(name))
            @compileError("jwt: " ++ label ++ "." ++ field ++ ": a claim name is a non-empty string of UTF-8; name the field in claim_names");
        if (top and isRegistered(name))
            @compileError("jwt: " ++ label ++ "." ++ field ++ ": \"" ++ name ++ "\" is a registered claim, which jwt sets and checks itself (jwt.Registered); remove the field or give it another claim name");
        for (info.field_names[0..i], info.field_attrs[0..i]) |earlier, earlier_attrs| {
            if (!earlier_attrs.@"comptime" and std.mem.eql(u8, nameOf(S, @field(std.meta.FieldEnum(S), earlier)), name))
                @compileError("jwt: " ++ label ++ ": " ++ earlier ++ " and " ++ field ++ " are both the claim \"" ++ name ++ "\"; give each field a claim name of its own");
        }
    }
    for (info.field_names, info.field_types, info.field_attrs) |field, F, attrs| {
        if (!attrs.@"comptime") checkType(F, label ++ "." ++ field, outer ++ &[_]type{S});
    }
}

fn checkType(comptime T: type, comptime where: []const u8, comptime outer: []const type) void {
    switch (@typeInfo(T)) {
        .bool => return,
        .int => |int| {
            if (int.bits >= 1 and int.bits <= 64) return;
            @compileError(std.fmt.comptimePrint("jwt: {s}: {s} has {d} bits; a claim integer has 1 to 64, such as u64 or i64", .{ where, @typeName(T), int.bits }));
        },
        .float => if (T == f32 or T == f64) return,
        .@"enum" => |info| if (info.mode == .exhaustive) return,
        .optional => |info| {
            if (@typeInfo(info.child) == .optional)
                @compileError("jwt: " ++ where ++ ": " ++ @typeName(T) ++ " is an optional of an optional, which JSON null cannot tell apart; use " ++ @typeName(info.child));
            return checkType(info.child, where, outer);
        },
        .pointer => if (ListItem(T)) |Item| {
            if (Item == u8) return;
            return checkType(Item, where ++ "[]", outer);
        },
        .@"struct" => if (isPlainStruct(T)) {
            for (outer) |Outer| {
                if (Outer == T)
                    @compileError("jwt: " ++ where ++ ": " ++ @typeName(T) ++ " contains itself; claims nest only as deep as their type, so give each level a type of its own");
            }
            return checkStruct(T, if (isAnonymous(T)) where else @typeName(T), false, outer);
        },
        else => {},
    }
    @compileError("jwt: " ++ where ++ ": " ++ @typeName(T) ++ " is not a claim type; a claim is bool, an integer, f32, f64, an enum, []const u8 or a struct, alone, as ?T or as []const T");
}

/// The items of `T` when it is a slice `[]const Item` that holds a string
/// (`u8`) or a list; null for every other pointer.
fn ListItem(comptime T: type) ?type {
    const p = @typeInfo(T).pointer;
    if (p.size != .slice or !p.attrs.@"const" or p.sentinel_ptr != null) return null;
    if (p.attrs.@"volatile" or p.attrs.@"allowzero") return null;
    if ((p.attrs.@"align" orelse @alignOf(p.child)) != @alignOf(p.child)) return null;
    if ((p.attrs.@"addrspace" orelse .generic) != .generic) return null;
    return p.child;
}

fn isPlainStruct(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| !s.is_tuple and s.layout == .auto,
        else => false,
    };
}

/// A struct declared inline, such as `order: struct { id: u64 }`: errors
/// name it by the path of its field.
fn isAnonymous(comptime T: type) bool {
    const name = @typeName(T);
    const at = std.mem.findLast(u8, name, "__struct_") orelse return false;
    const digits = name[at + "__struct_".len ..];
    if (digits.len == 0) return false;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn isRegistered(name: []const u8) bool {
    for (registered_names) |registered| {
        if (std.mem.eql(u8, registered, name)) return true;
    }
    return false;
}

/// The entry of `field` in `T.claim_names`, if it has one.
fn claimName(comptime T: type, comptime field: []const u8) ?[]const u8 {
    if (!@hasDecl(T, "claim_names") or !@hasField(@TypeOf(T.claim_names), field)) return null;
    return asName(@field(T.claim_names, field));
}

/// The code of a claim whose JSON is of another type than its field.
pub const invalid_type = "jwt.invalid_type";
/// The code of a required claim that the payload lacks.
pub const missing_claim = "jwt.missing_claim";
/// The code of a number that its field cannot hold.
pub const out_of_range = "jwt.out_of_range";

/// The messages of the mapping, without the claim's name; static, as the
/// validator's are, so a violation never holds bytes of the token.
const messages = struct {
    const required = "is required";
    const integer = "must be an integer";
    const number = "must be a number";
    const true_or_false = "must be true or false";
    const string = "must be a string";
    const array = "must be an array";
    const object = "must be an object";
    const range = "is out of range";

    /// "must be one of low, high": the variants of `E`.
    fn oneOf(comptime E: type) []const u8 {
        comptime {
            var text: []const u8 = "must be one of ";
            for (@typeInfo(E).@"enum".field_names, 0..) |name, i| {
                text = text ++ (if (i == 0) "" else ", ") ++ name;
            }
            return text;
        }
    }
};

pub const DecodeError = error{ Malformed, InvalidClaims, OutOfMemory };

/// The claims of `payload`, a JSON object, as a `Claims`; `void` only
/// checks that the payload is an object. Unknown claims, the registered
/// ones among them, are skipped. `Malformed`: not one JSON object, a claim
/// of the struct given twice, or nesting deeper than `max_json_depth`.
/// `InvalidClaims`: the first claim, in the order of the payload, that does
/// not fit its field, or a required claim that is absent; the violation is
/// in `details.violation`, its path in `details.path_buf`. Strings point
/// into `payload`, or into `arena` when they had escapes. The first problem
/// ends the read; `verify` has read the whole payload for the registered
/// claims before.
pub fn decode(comptime Claims: type, arena: std.mem.Allocator, payload: []const u8, details: *Details) DecodeError!Claims {
    comptime check(Claims);
    var decoder: Decoder = .{ .reader = .init(arena, payload), .arena = arena, .details = details };
    var claims: Claims = undefined;
    if (Claims == void) {
        try decoder.reader.beginObject();
        while (try decoder.reader.nextKey()) |_| try decoder.reader.skip();
    } else {
        try decoder.readObject(Claims, &claims);
    }
    try decoder.reader.finish();
    return claims;
}

const Decoder = struct {
    reader: json.Reader,
    arena: std.mem.Allocator,
    details: *Details,
    /// The length of the path of the value being read, in
    /// `details.path_buf`; past its end when the path does not fit.
    path_len: usize = 0,

    /// The claim being read does not fit: `InvalidClaims`, with a violation
    /// at the path, or without a field when the path did not fit.
    fn fail(d: *Decoder, code: []const u8, message: []const u8) DecodeError {
        const fits = d.path_len <= d.details.path_buf.len;
        d.details.violation = .{ .code = code, .message = message, .field = if (fits) d.details.path_buf[0..d.path_len] else null };
        return error.InvalidClaims;
    }

    /// Adds `bytes` to the path, as much of them as fits, and returns the
    /// length to go back to.
    fn push(d: *Decoder, bytes: []const u8) usize {
        const mark = d.path_len;
        const buf = &d.details.path_buf;
        if (d.path_len < buf.len) {
            const n = @min(bytes.len, buf.len - d.path_len);
            @memcpy(buf[d.path_len..][0..n], bytes[0..n]);
        }
        d.path_len +|= bytes.len;
        return mark;
    }

    fn pushName(d: *Decoder, name: []const u8) usize {
        const mark = d.path_len;
        if (mark > 0) _ = d.push(".");
        _ = d.push(name);
        return mark;
    }

    fn pushIndex(d: *Decoder, index: usize) usize {
        var buf: [24]u8 = undefined;
        return d.push(std.fmt.bufPrint(&buf, "[{d}]", .{index}) catch unreachable);
    }

    /// Reads the next value into `out`.
    fn read(d: *Decoder, comptime T: type, out: *T) DecodeError!void {
        const kind = try d.reader.peek();
        switch (@typeInfo(T)) {
            .optional => |o| {
                if (try d.reader.isNull()) {
                    out.* = null;
                    return;
                }
                var payload: o.child = undefined;
                try d.read(o.child, &payload);
                out.* = payload;
                return;
            },
            .bool => if (kind == .true or kind == .false) {
                out.* = try d.reader.boolean();
                return;
            },
            .int => if (kind == .number) {
                const text = try d.reader.number();
                if (std.mem.findAny(u8, text, ".eE") != null) return d.fail(invalid_type, messages.integer);
                out.* = std.fmt.parseInt(T, text, 10) catch |err| switch (err) {
                    error.Overflow => return d.fail(out_of_range, messages.range),
                    error.InvalidCharacter => return error.Malformed,
                };
                return;
            },
            .float => if (kind == .number) {
                const value = std.fmt.parseFloat(T, try d.reader.number()) catch return error.Malformed;
                if (!std.math.isFinite(value)) return d.fail(out_of_range, messages.range);
                out.* = value;
                return;
            },
            .@"enum" => if (kind == .string) {
                out.* = std.meta.stringToEnum(T, try d.reader.string()) orelse return d.fail(invalid_type, comptime messages.oneOf(T));
                return;
            },
            .pointer => |p| if (p.child == u8) {
                if (kind == .string) {
                    out.* = try d.reader.string();
                    return;
                }
            } else if (kind == .array_begin) {
                return d.readList(p.child, out);
            },
            .@"struct" => if (kind == .object_begin) return d.readObject(T, out),
            else => comptime unreachable,
        }
        return d.fail(invalid_type, comptime messageOf(T));
    }

    fn readList(d: *Decoder, comptime Item: type, out: *[]const Item) DecodeError!void {
        try d.reader.beginArray();
        var items: std.ArrayList(Item) = .empty;
        var index: usize = 0;
        while (try d.reader.nextItem()) : (index += 1) {
            const mark = d.pushIndex(index);
            try d.read(Item, try items.addOne(d.arena));
            d.path_len = mark;
        }
        out.* = items.items;
    }

    fn readObject(d: *Decoder, comptime S: type, out: *S) DecodeError!void {
        const info = @typeInfo(S).@"struct";
        try d.reader.beginObject();
        var seen: [@max(1, info.field_names.len)]bool = @splat(false);
        while (try d.reader.nextKey()) |key| {
            const index = fieldIndex(S, key) orelse {
                try d.reader.skip();
                continue;
            };
            // A claim given twice: two readers could each take another
            // value of it.
            if (seen[index]) return error.Malformed;
            seen[index] = true;
            inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, i| {
                if (comptime !attrs.@"comptime") {
                    if (index == i) {
                        const mark = d.pushName(comptime nameOf(S, @field(std.meta.FieldEnum(S), name)));
                        try d.read(F, &@field(out, name));
                        d.path_len = mark;
                    }
                }
            }
        }
        inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, i| {
            if (comptime !attrs.@"comptime") {
                if (!seen[i]) {
                    if (comptime attrs.defaultValue(F)) |default| {
                        @field(out, name) = default;
                    } else if (comptime @typeInfo(F) == .optional) {
                        @field(out, name) = null;
                    } else {
                        _ = d.pushName(comptime nameOf(S, @field(std.meta.FieldEnum(S), name)));
                        return d.fail(missing_claim, messages.required);
                    }
                }
            }
        }
    }
};

/// The index of the non-comptime field of `S` whose claim name is `key`.
fn fieldIndex(comptime S: type, key: []const u8) ?usize {
    const table = comptime lookup(S);
    return table.get(key);
}

fn lookup(comptime S: type) std.StaticStringMap(usize) {
    comptime {
        const info = @typeInfo(S).@"struct";
        var pairs: []const struct { []const u8, usize } = &.{};
        for (info.field_names, info.field_attrs, 0..) |name, attrs, i| {
            if (!attrs.@"comptime") pairs = pairs ++ .{.{ nameOf(S, @field(std.meta.FieldEnum(S), name)), i }};
        }
        return .initComptime(pairs);
    }
}

/// What a value of `T` must be.
fn messageOf(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .optional => |o| messageOf(o.child),
        .int => messages.integer,
        .float => messages.number,
        .bool => messages.true_or_false,
        .@"enum" => messages.oneOf(T),
        .@"struct" => messages.object,
        .pointer => if (T == []const u8) messages.string else messages.array,
        else => comptime unreachable,
    };
}

/// The last second a NumericDate may name: the end of the year 9999.
pub const max_numeric_date = 253402300799;

/// The registered claims of a token that passed `verify`, which checked
/// "iss", "aud", "exp", "nbf" and "iat" itself. A time is in seconds of
/// Unix time; a fraction in the token is rounded to the safe side.
pub const Registered = struct {
    /// "iss": the verifier's issuer, byte for byte.
    issuer: []const u8,
    /// "sub": whom the token is about, such as a user's id.
    subject: ?[]const u8,
    /// "aud": the audiences of the token in its order; one of them is the
    /// verifier's.
    audience: []const []const u8,
    /// "exp", rounded down.
    expires_at: i64,
    /// "nbf", rounded up.
    not_before: ?i64,
    /// "iat", rounded up.
    issued_at: ?i64,
    /// "jti": the token's own id.
    id: ?[]const u8,
};

/// A registered claim as the payload has it: absent, of the wrong type
/// or out of range, or its value.
pub fn Found(comptime Value: type) type {
    return union(enum) { absent, invalid, value: Value };
}

/// The registered claims of a payload, read but not checked yet.
pub const RegisteredInput = struct {
    issuer: Found([]const u8) = .absent,
    subject: Found([]const u8) = .absent,
    audience: Found([]const []const u8) = .absent,
    expires_at: Found(i64) = .absent,
    not_before: Found(i64) = .absent,
    issued_at: Found(i64) = .absent,
    id: Found([]const u8) = .absent,
};

/// What `checkRegistered` holds the registered claims to.
pub const RegisteredRules = struct {
    issuer: []const u8,
    audiences: []const []const u8,
    leeway_seconds: i64,
};

const RegisteredName = enum { iss, sub, aud, exp, nbf, iat, jti };

/// The registered claims of `payload`, a JSON object, in one pass over
/// the whole of it; the other claims are skipped. `Malformed`: not one JSON
/// object, a registered claim given twice, or nesting deeper than
/// `max_json_depth`. A registered claim of the wrong type is not an error
/// here: `checkRegistered` refuses it in its turn.
pub fn readRegistered(arena: std.mem.Allocator, payload: []const u8) error{ Malformed, OutOfMemory }!RegisteredInput {
    var reader: json.Reader = .init(arena, payload);
    var input: RegisteredInput = .{};
    var seen: [registered_names.len]bool = @splat(false);
    try reader.beginObject();
    while (try reader.nextKey()) |key| {
        const name = std.meta.stringToEnum(RegisteredName, key) orelse {
            try reader.skip();
            continue;
        };
        if (seen[@backingInt(name)]) return error.Malformed;
        seen[@backingInt(name)] = true;
        switch (name) {
            .iss => input.issuer = try readString(&reader),
            .sub => input.subject = try readString(&reader),
            .aud => input.audience = try readAudience(&reader, arena),
            .exp => input.expires_at = try readDate(&reader, .down),
            .nbf => input.not_before = try readDate(&reader, .up),
            .iat => input.issued_at = try readDate(&reader, .up),
            .jti => input.id = try readString(&reader),
        }
    }
    try reader.finish();
    return input;
}

fn readString(reader: *json.Reader) json.Reader.Error!Found([]const u8) {
    if (try reader.peek() == .string) return .{ .value = try reader.string() };
    try reader.skip();
    return .invalid;
}

/// "aud": a string, kept as a list of one, or a non-empty array of strings.
fn readAudience(reader: *json.Reader, arena: std.mem.Allocator) json.Reader.Error!Found([]const []const u8) {
    switch (try reader.peek()) {
        .string => {
            const one = try arena.alloc([]const u8, 1);
            one[0] = try reader.string();
            return .{ .value = one };
        },
        .array_begin => {
            try reader.beginArray();
            var list: std.ArrayList([]const u8) = .empty;
            var valid = true;
            while (try reader.nextItem()) {
                if (valid and try reader.peek() == .string) {
                    try list.append(arena, try reader.string());
                } else {
                    valid = false;
                    try reader.skip();
                }
            }
            if (!valid or list.items.len == 0) return .invalid;
            return .{ .value = list.items };
        },
        else => {
            try reader.skip();
            return .invalid;
        },
    }
}

/// A NumericDate (RFC 7519 §2): an integer, or a number with a fraction or
/// an exponent, from 0 to `max_numeric_date`, rounded `down` or `up` to a
/// second.
fn readDate(reader: *json.Reader, comptime rounding: enum { down, up }) json.Reader.Error!Found(i64) {
    if (try reader.peek() != .number) {
        try reader.skip();
        return .invalid;
    }
    const text = try reader.number();
    if (std.mem.findAny(u8, text, ".eE") == null) {
        const seconds = std.fmt.parseInt(i64, text, 10) catch return .invalid;
        if (seconds < 0 or seconds > max_numeric_date) return .invalid;
        return .{ .value = seconds };
    }
    const seconds = std.fmt.parseFloat(f64, text) catch return .invalid;
    // NaN and the infinities fail the comparison too.
    if (!(seconds >= 0 and seconds <= max_numeric_date)) return .invalid;
    return .{ .value = @intFromFloat(switch (rounding) {
        .down => @floor(seconds),
        .up => @ceil(seconds),
    }) };
}

/// Holds the registered claims of `input` to `rules` at `now`, in seconds
/// of Unix time, in this order: "iss", "aud", "exp", "nbf", "iat"; then
/// the types of "sub" and "jti". On an error `details.claim` names the
/// claim. `MissingClaim`: "iss", "aud" or "exp" is absent. `InvalidClaims`:
/// a registered claim of the wrong type or out of range. `WrongIssuer`,
/// `WrongAudience`; `Expired`: `now ≥ exp + leeway`; `NotYetValid`:
/// `nbf` or `iat` later than `now + leeway`.
pub fn checkRegistered(input: RegisteredInput, rules: RegisteredRules, now: i64, details: *Details) VerifyError!Registered {
    const leeway: i128 = rules.leeway_seconds;
    const issuer = try required([]const u8, input.issuer, "iss", details);
    if (!std.mem.eql(u8, issuer, rules.issuer)) return refuse(details, "iss", error.WrongIssuer);
    const audience = try required([]const []const u8, input.audience, "aud", details);
    if (!anyOf(audience, rules.audiences)) return refuse(details, "aud", error.WrongAudience);
    const expires_at = try required(i64, input.expires_at, "exp", details);
    if (now >= expires_at + leeway) return refuse(details, "exp", error.Expired);
    const not_before = try optional(i64, input.not_before, "nbf", details);
    if (not_before) |nbf| {
        if (nbf > now + leeway) return refuse(details, "nbf", error.NotYetValid);
    }
    const issued_at = try optional(i64, input.issued_at, "iat", details);
    if (issued_at) |iat| {
        if (iat > now + leeway) return refuse(details, "iat", error.NotYetValid);
    }
    return .{
        .issuer = issuer,
        .subject = try optional([]const u8, input.subject, "sub", details),
        .audience = audience,
        .expires_at = expires_at,
        .not_before = not_before,
        .issued_at = issued_at,
        .id = try optional([]const u8, input.id, "jti", details),
    };
}

fn required(comptime Value: type, found: Found(Value), comptime claim: []const u8, details: *Details) VerifyError!Value {
    return switch (found) {
        .absent => refuse(details, claim, error.MissingClaim),
        .invalid => refuse(details, claim, error.InvalidClaims),
        .value => |value| value,
    };
}

fn optional(comptime Value: type, found: Found(Value), comptime claim: []const u8, details: *Details) VerifyError!?Value {
    return switch (found) {
        .absent => null,
        .invalid => refuse(details, claim, error.InvalidClaims),
        .value => |value| value,
    };
}

/// Whether one of `values` is one of `wanted`.
fn anyOf(values: []const []const u8, wanted: []const []const u8) bool {
    for (values) |value| {
        for (wanted) |name| {
            if (std.mem.eql(u8, value, name)) return true;
        }
    }
    return false;
}

fn refuse(details: *Details, claim: []const u8, err: VerifyError) VerifyError {
    details.claim = claim;
    return err;
}

/// `value` as a string, when it is one: a literal or a `[]const u8`.
fn asName(comptime value: anytype) ?[]const u8 {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) return value,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| if (a.child == u8) return value,
                else => {},
            },
            else => {},
        },
        else => {},
    }
    return null;
}

const testing = std.testing;
const rfc7515 = @import("testdata/rfc7515.zig");

const Named = struct {
    is_root: bool = false,
    user_name: []const u8 = "",
    level: u8 = 0,

    pub const claim_names = .{ .is_root = "http://example.com/is_root" };
    pub const field_rules = .{ .user_name = v.rename("userName") };
};

test "a claim is named by claim_names first, then by its outside name" {
    try testing.expectEqualStrings("http://example.com/is_root", comptime nameOf(Named, .is_root));
    try testing.expectEqualStrings("userName", comptime nameOf(Named, .user_name));
    try testing.expectEqualStrings("level", comptime nameOf(Named, .level));
    comptime check(Named);
    comptime check(void);
}

/// `payload` decoded as a `T` in `arena`; on an error, prints what
/// `Details` says.
fn decoded(comptime T: type, arena: std.mem.Allocator, payload: []const u8) !T {
    var details: Details = .{};
    return decode(T, arena, payload, &details) catch |err| {
        if (details.violation) |violation| std.debug.print("{t}: {s} at {?s}: {s}\n", .{ err, violation.code, violation.field, violation.message });
        return err;
    };
}

/// Decodes `payload` as a `T` and expects `InvalidClaims` with this
/// violation; `field` null: a path that did not fit.
fn expectViolation(comptime T: type, payload: []const u8, code: []const u8, field: ?[]const u8, message: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var details: Details = .{};
    if (decode(T, arena_state.allocator(), payload, &details)) |_| {
        std.debug.print("decoded: {s}\n", .{payload});
        return error.TestUnexpectedResult;
    } else |err| try testing.expectEqual(error.InvalidClaims, err);
    const violation = details.violation orelse return error.TestExpectedViolation;
    try testing.expectEqualStrings(code, violation.code);
    try testing.expectEqualStrings(message, violation.message);
    if (field) |name| {
        try testing.expectEqualStrings(name, violation.field orelse "(none)");
    } else {
        try testing.expectEqual(null, violation.field);
    }
    try testing.expectEqual(null, details.claim);
}

fn expectMalformed(comptime T: type, payload: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var details: Details = .{};
    try testing.expectError(error.Malformed, decode(T, arena_state.allocator(), payload, &details));
}

const Flag = struct { flag: bool };

test "5.5: bool is true or false" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect((try decoded(Flag, arena, "{\"flag\":true}")).flag);
    try testing.expect(!(try decoded(Flag, arena, "{\"flag\":false}")).flag);
    try expectViolation(Flag, "{\"flag\":1}", invalid_type, "flag", "must be true or false");
    try expectViolation(Flag, "{\"flag\":\"true\"}", invalid_type, "flag", "must be true or false");
}

const Small = struct { small: i8 };
const Count = struct { count: u32 };
const Wide = struct { total: u64, delta: i64 };

test "5.5: an integer is a number without a fraction or an exponent, within its type" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(127, (try decoded(Small, arena, "{\"small\":127}")).small);
    try testing.expectEqual(-128, (try decoded(Small, arena, "{\"small\":-128}")).small);
    try expectViolation(Small, "{\"small\":128}", out_of_range, "small", "is out of range");
    try expectViolation(Count, "{\"count\":-1}", out_of_range, "count", "is out of range");
    try expectViolation(Count, "{\"count\":99999999999999999999999999}", out_of_range, "count", "is out of range");
    const wide = try decoded(Wide, arena, "{\"total\":18446744073709551615,\"delta\":-9223372036854775808}");
    try testing.expectEqual(std.math.maxInt(u64), wide.total);
    try testing.expectEqual(std.math.minInt(i64), wide.delta);
    try expectViolation(Count, "{\"count\":1.0}", invalid_type, "count", "must be an integer");
    try expectViolation(Count, "{\"count\":1e3}", invalid_type, "count", "must be an integer");
    try expectViolation(Count, "{\"count\":\"1\"}", invalid_type, "count", "must be an integer");
}

const Ratio = struct { ratio: f64 };
const Single = struct { value: f32 };

test "5.5: a float is a finite number" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(1500, (try decoded(Ratio, arena, "{\"ratio\":1.5e3}")).ratio);
    try testing.expectEqual(-2, (try decoded(Ratio, arena, "{\"ratio\":-2}")).ratio);
    try testing.expectEqual(0.25, (try decoded(Single, arena, "{\"value\":0.25}")).value);
    try expectViolation(Ratio, "{\"ratio\":1e400}", out_of_range, "ratio", "is out of range");
    try expectViolation(Single, "{\"value\":1e39}", out_of_range, "value", "is out of range");
    try expectViolation(Ratio, "{\"ratio\":true}", invalid_type, "ratio", "must be a number");
}

const Priority = enum { low, high };
const Task = struct { priority: Priority };

test "5.5: an enum is the name of one of its variants" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(.high, (try decoded(Task, arena_state.allocator(), "{\"priority\":\"high\"}")).priority);
    try expectViolation(Task, "{\"priority\":\"urgent\"}", invalid_type, "priority", "must be one of low, high");
    try expectViolation(Task, "{\"priority\":1}", invalid_type, "priority", "must be one of low, high");
}

const Note = struct { note: []const u8 };

test "5.5: a string is decoded, its escapes into the arena" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const plain = "{\"note\":\"café 😀\"}";
    const note = (try decoded(Note, arena, plain)).note;
    try testing.expectEqualStrings("café 😀", note);
    // Without escapes the string is a part of the payload.
    try testing.expect(note.ptr == plain.ptr + 9);
    const escaped = (try decoded(Note, arena, "{\"note\":\"caf\x5cu00e9 \x5cud83d\x5cude00 \x5c\"q\x5c\"\"}")).note;
    try testing.expectEqualStrings("café 😀 \"q\"", escaped);
    try expectViolation(Note, "{\"note\":5}", invalid_type, "note", "must be a string");
    try expectViolation(Note, "{\"note\":null}", invalid_type, "note", "must be a string");
}

const Ids = struct { ids: []const u32 };

test "5.5: a list is an array, each item of its type" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, (try decoded(Ids, arena, "{\"ids\":[1,2]}")).ids);
    try testing.expectEqual(0, (try decoded(Ids, arena, "{\"ids\":[]}")).ids.len);
    try expectViolation(Ids, "{\"ids\":[1,\"a\"]}", invalid_type, "ids[1]", "must be an integer");
    try expectViolation(Ids, "{\"ids\":\"x\"}", invalid_type, "ids", "must be an array");
}

const Maybe = struct { level: ?u32 };
const MaybeDefault = struct { level: ?u32 = 7 };

test "5.5: an optional is null or absent" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(null, (try decoded(Maybe, arena, "{\"level\":null}")).level);
    try testing.expectEqual(null, (try decoded(Maybe, arena, "{}")).level);
    try testing.expectEqual(3, (try decoded(Maybe, arena, "{\"level\":3}")).level.?);
    try testing.expectEqual(7, (try decoded(MaybeDefault, arena, "{}")).level.?);
    try testing.expectEqual(null, (try decoded(MaybeDefault, arena, "{\"level\":null}")).level);
    try expectViolation(Maybe, "{\"level\":\"3\"}", invalid_type, "level", "must be an integer");
}

const Profile = struct { count: u32, name: []const u8, page: u32 = 1 };

test "5.5: a required claim that is absent is jwt.missing_claim, after the other keys" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try expectViolation(Profile, "{\"name\":\"x\"}", missing_claim, "count", "is required");
    // The value of the wrong type comes first, though its key is the last.
    try expectViolation(Profile, "{\"page\":2,\"count\":\"x\"}", invalid_type, "count", "must be an integer");
    const profile = try decoded(Profile, arena_state.allocator(), "{\"count\":2,\"name\":\"x\"}");
    try testing.expectEqual(1, profile.page);
}

const Line = struct { sku: []const u8, qty: u32 = 1 };
const Order = struct {
    order: struct { id: u64, items: []const Line },
};

test "5.5: a nested struct is an object, and the path names each level" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const order = try decoded(Order, arena_state.allocator(), "{\"order\":{\"id\":5,\"items\":[{\"sku\":\"a\"},{\"sku\":\"b\",\"qty\":2}]}}");
    try testing.expectEqual(5, order.order.id);
    try testing.expectEqualStrings("b", order.order.items[1].sku);
    try testing.expectEqual(2, order.order.items[1].qty);
    try testing.expectEqual(1, order.order.items[0].qty);
    try expectViolation(Order, "{\"order\":{\"id\":5,\"items\":[{\"sku\":\"a\"},{\"sku\":\"b\"},{\"qty\":3}]}}", missing_claim, "order.items[2].sku", "is required");
    try expectViolation(Order, "{\"order\":[]}", invalid_type, "order", "must be an object");
}

const Renamed = struct {
    user_name: []const u8,

    pub const field_rules = .{ .user_name = v.rename("userName") };
};

const Rooted = struct {
    is_root: bool = false,

    pub const claim_names = .{ .is_root = "http://example.com/is_root" };
};

test "claims are read by their claim names" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("ann", (try decoded(Renamed, arena, "{\"userName\":\"ann\"}")).user_name);
    try expectViolation(Renamed, "{\"user_name\":\"ann\"}", missing_claim, "userName", "is required");
    try testing.expect((try decoded(Rooted, arena, "{\"http://example.com/is_root\":true}")).is_root);
    try testing.expect(!(try decoded(Rooted, arena, "{\"is_root\":true}")).is_root);
}

test "RFC 7519 §3.1: is_root comes through claim_names" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    // "iss" and "exp" are registered: the claims skip them.
    try testing.expect((try decoded(Rooted, arena_state.allocator(), rfc7515.a1_payload)).is_root);
}

test "a claim given twice is Malformed, an unknown one is not looked at" {
    try expectMalformed(Count, "{\"count\":1,\"count\":1}");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(1, (try decoded(Count, arena_state.allocator(), "{\"x\":1,\"x\":2,\"count\":1}")).count);
}

/// `{"x":` and `arrays` arrays inside each other, then `,"count":1}`.
fn deepUnknown(arena: std.mem.Allocator, arrays: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"x\":");
    try out.appendNTimes(arena, '[', arrays);
    try out.appendNTimes(arena, ']', arrays);
    try out.appendSlice(arena, ",\"count\":1}");
    return out.items;
}

test "unknown claims are skipped, within the depth of max_json_depth" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(1, (try decoded(Count, arena, "{\"x\":{\"y\":[1,2,{\"z\":null}]},\"count\":1}")).count);
    // The top object is level 1: 31 arrays reach level 32.
    try testing.expectEqual(1, (try decoded(Count, arena, try deepUnknown(arena, root.max_json_depth - 1))).count);
    try expectMalformed(Count, try deepUnknown(arena, root.max_json_depth));
    try expectMalformed(void, try deepUnknown(arena, root.max_json_depth));
}

test "the payload is one JSON object, for void claims too" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try decoded(void, arena, "{}");
    try decoded(void, arena, "{\"iss\":\"orders\",\"x\":[1,{\"y\":null}]}");
    inline for (.{ void, Count }) |T| {
        for ([_][]const u8{ "[]", "\"x\"", "5", "null", "", "{\"count\":1} x", "{\"count\":1", "\xef\xbb\xbf{}", "{\"s\":\"\xff\"}" }) |payload| {
            try expectMalformed(T, payload);
        }
    }
}

const Long = struct {
    deep: struct { deeper: u32 },

    pub const claim_names = .{ .deep = &@as([300]u8, @splat('a')) };
};

test "a path longer than path_buf gives a violation without a field" {
    try expectViolation(Long, "{\"" ++ @as([300]u8, @splat('a')) ++ "\":{\"deeper\":\"x\"}}", invalid_type, null, "must be an integer");
    try expectViolation(Ids, "{\"ids\":[1,\"a\"]}", invalid_type, "ids[1]", "must be an integer");
}

const t0 = 1_760_000_000;
const orders: RegisteredRules = .{ .issuer = "orders", .audiences = &.{"orders"}, .leeway_seconds = 60 };

/// The registered claims of `payload` checked at `now` by `rules`.
fn readChecked(arena: std.mem.Allocator, payload: []const u8, rules: RegisteredRules, now: i64, details: *Details) VerifyError!Registered {
    return checkRegistered(try readRegistered(arena, payload), rules, now, details);
}

fn expectRegistered(arena: std.mem.Allocator, payload: []const u8, now: i64) !Registered {
    var details: Details = .{};
    return readChecked(arena, payload, orders, now, &details) catch |err| {
        std.debug.print("{t} at {s}: {s}\n", .{ err, details.claim orelse "(none)", payload });
        return err;
    };
}

fn expectRefusedAt(payload: []const u8, rules: RegisteredRules, now: i64, expected: VerifyError, claim: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var details: Details = .{};
    if (readChecked(arena_state.allocator(), payload, rules, now, &details)) |_| {
        std.debug.print("accepted: {s}\n", .{payload});
        return error.TestUnexpectedResult;
    } else |err| {
        testing.expectEqual(expected, err) catch |e| {
            std.debug.print("{s}\n", .{payload});
            return e;
        };
    }
    try testing.expectEqualStrings(claim, details.claim orelse "(none)");
    try testing.expectEqual(null, details.violation);
}

fn expectRefused(payload: []const u8, now: i64, expected: VerifyError, claim: []const u8) !void {
    return expectRefusedAt(payload, orders, now, expected, claim);
}

test "5.6: iss, aud and exp are required, in this order" {
    try expectRefused("{}", t0, error.MissingClaim, "iss");
    try expectRefused("{\"iss\":\"orders\"}", t0, error.MissingClaim, "aud");
    try expectRefused("{\"iss\":\"orders\",\"aud\":\"orders\"}", t0, error.MissingClaim, "exp");
    try expectRefused("{\"iss\":\"x\",\"exp\":\"no\"}", t0, error.WrongIssuer, "iss");
    try expectRefused("{\"aud\":\"x\",\"exp\":1,\"iss\":5}", t0, error.InvalidClaims, "iss");
    try expectRefused("{\"iss\":\"orders\",\"exp\":\"no\",\"aud\":\"x\"}", t0, error.WrongAudience, "aud");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const got = try expectRegistered(arena_state.allocator(), "{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":1760000900}", t0);
    try testing.expectEqualStrings("orders", got.issuer);
    try testing.expectEqual(1760000900, got.expires_at);
    try testing.expectEqual(null, got.subject);
    try testing.expectEqual(null, got.not_before);
    try testing.expectEqual(null, got.issued_at);
    try testing.expectEqual(null, got.id);
}

test "iss is compared byte for byte" {
    try expectRefused("{\"iss\":\"Orders\",\"aud\":\"orders\",\"exp\":1760000900}", t0, error.WrongIssuer, "iss");
    try expectRefused("{\"iss\":\"orders \",\"aud\":\"orders\",\"exp\":1760000900}", t0, error.WrongIssuer, "iss");
}

test "aud is a string or a non-empty array of strings" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var details: Details = .{};
    const one = try readChecked(arena, "{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":1760000900}", orders, t0, &details);
    try testing.expectEqual(1, one.audience.len);
    try testing.expectEqualStrings("orders", one.audience[0]);
    const two = try readChecked(arena, "{\"iss\":\"orders\",\"aud\":[\"billing\",\"orders\"],\"exp\":1760000900}", orders, t0, &details);
    try testing.expectEqual(2, two.audience.len);
    try testing.expectEqualStrings("billing", two.audience[0]);
    try testing.expectEqualStrings("orders", two.audience[1]);
    // Any of the verifier's audiences will do.
    const billing: RegisteredRules = .{ .issuer = "orders", .audiences = &.{ "billing", "reports" }, .leeway_seconds = 60 };
    _ = try readChecked(arena, "{\"iss\":\"orders\",\"aud\":[\"orders\",\"reports\"],\"exp\":1760000900}", billing, t0, &details);

    try expectRefused("{\"iss\":\"orders\",\"aud\":[\"billing\"],\"exp\":1760000900}", t0, error.WrongAudience, "aud");
    try expectRefused("{\"iss\":\"orders\",\"aud\":\"Orders\",\"exp\":1760000900}", t0, error.WrongAudience, "aud");
    for ([_][]const u8{ "5", "[]", "[\"orders\",5]", "null", "{}", "[[\"orders\"]]" }) |aud| {
        const payload = try std.fmt.allocPrint(arena, "{{\"iss\":\"orders\",\"aud\":{s},\"exp\":1760000900}}", .{aud});
        try expectRefused(payload, t0, error.InvalidClaims, "aud");
    }
}

test "a NumericDate is 0 to 253402300799, whole or fractional" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const head = "{\"iss\":\"orders\",\"aud\":\"orders\",";
    // 0 is a date, long past.
    try expectRefused(head ++ "\"exp\":0}", t0, error.Expired, "exp");
    try testing.expectEqual(max_numeric_date, (try expectRegistered(arena, head ++ "\"exp\":253402300799}", t0)).expires_at);
    for ([_][]const u8{ "253402300800", "-1", "\"1700000000\"", "1e400", "-0.5", "253402300799.5", "true", "99999999999999999999" }) |exp| {
        const payload = try std.fmt.allocPrint(arena, "{s}\"exp\":{s}}}", .{ head, exp });
        try expectRefused(payload, t0, error.InvalidClaims, "exp");
    }
    // A fraction rounds to the safe side: exp down, nbf and iat up.
    try testing.expectEqual(t0, (try expectRegistered(arena, head ++ "\"exp\":1760000000.9}", t0 - 10)).expires_at);
    const late = try expectRegistered(arena, head ++ "\"exp\":1760000900,\"nbf\":1760000000.1,\"iat\":1760000000.5}", t0 + 1);
    try testing.expectEqual(t0 + 1, late.not_before.?);
    try testing.expectEqual(t0 + 1, late.issued_at.?);
    try testing.expectEqual(1760000000, (try expectRegistered(arena, head ++ "\"exp\":1.76e9}", t0 - 10)).expires_at);
    try testing.expectEqual(1760000060, (try expectRegistered(arena, head ++ "\"exp\":1760000060E0}", t0)).expires_at);
    try testing.expectEqual(0, (try expectRegistered(arena, head ++ "\"exp\":1760000900,\"nbf\":0.0}", t0)).not_before.?);
    try expectRefused(head ++ "\"exp\":1760000900,\"nbf\":\"0\"}", t0, error.InvalidClaims, "nbf");
    try expectRefused(head ++ "\"exp\":1760000900,\"iat\":-1}", t0, error.InvalidClaims, "iat");
}

test "leeway on the edges of exp, nbf and iat" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const head = "{\"iss\":\"orders\",\"aud\":\"orders\",";
    _ = try expectRegistered(arena, head ++ "\"exp\":1760000000}", t0 + 59);
    try expectRefused(head ++ "\"exp\":1760000000}", t0 + 60, error.Expired, "exp");
    _ = try expectRegistered(arena, head ++ "\"exp\":1760000900,\"nbf\":1760000000}", t0 - 60);
    try expectRefused(head ++ "\"exp\":1760000900,\"nbf\":1760000000}", t0 - 61, error.NotYetValid, "nbf");
    _ = try expectRegistered(arena, head ++ "\"exp\":1760000900,\"iat\":1760000000}", t0 - 60);
    try expectRefused(head ++ "\"exp\":1760000900,\"iat\":1760000000}", t0 - 61, error.NotYetValid, "iat");
    const strict: RegisteredRules = .{ .issuer = "orders", .audiences = &.{"orders"}, .leeway_seconds = 0 };
    try expectRefusedAt(head ++ "\"exp\":1760000000}", strict, t0, error.Expired, "exp");
    try expectRefusedAt(head ++ "\"exp\":1760000900,\"nbf\":1760000001}", strict, t0, error.NotYetValid, "nbf");
    // A clock at the ends of i64 overflows nothing.
    try expectRefused(head ++ "\"exp\":1760000900}", std.math.maxInt(i64), error.Expired, "exp");
    try expectRefused(head ++ "\"exp\":1760000900,\"nbf\":1760000000}", std.math.minInt(i64), error.NotYetValid, "nbf");
}

test "sub and jti are strings when present" {
    const head = "{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":1760000900,";
    try expectRefused(head ++ "\"sub\":5}", t0, error.InvalidClaims, "sub");
    try expectRefused(head ++ "\"jti\":[]}", t0, error.InvalidClaims, "jti");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const got = try expectRegistered(arena_state.allocator(), head ++ "\"sub\":\"user-7\",\"jti\":\"t-1\",\"iat\":1759999990}", t0);
    try testing.expectEqualStrings("user-7", got.subject.?);
    try testing.expectEqualStrings("t-1", got.id.?);
    try testing.expectEqual(1759999990, got.issued_at.?);
}

test "a registered claim given twice is Malformed" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.Malformed, readRegistered(arena, "{\"exp\":1,\"exp\":1}"));
    try testing.expectError(error.Malformed, readRegistered(arena, "{\"aud\":\"a\",\"aud\":[\"b\"]}"));
    for ([_][]const u8{ "[]", "5", "{} x", "{\"iss\":\"\xff\"}", "{\"x\":" }) |payload| {
        try testing.expectError(error.Malformed, readRegistered(arena, payload));
    }
}
