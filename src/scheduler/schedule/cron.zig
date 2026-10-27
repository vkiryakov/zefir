//! Cron expressions of v1, in UTC: 5 fields (minute, hour, day of the
//! month, month, day of the week) or 6 with the second first. A field is
//! `*`, `a`, `a-b`, `a,b,…`, `*/n` or `a-b/n`, a range going up from `a`
//! to `b`; the month and the day of the week take the names JAN–DEC and
//! SUN–SAT in any case, and Sunday is 0 and 7. The macros are @yearly,
//! @annually, @monthly, @weekly, @daily, @midnight and @hourly. When
//! neither the day of the month nor the day of the week is exactly `*`, a
//! day that matches either one comes; when one is exactly `*`, the other
//! decides. Only `*` itself counts so: with `*/2`, or `*/1`, either field
//! may match, so `0 0 */2 * MON` comes on the odd days of the month and on
//! Mondays, and `0 0 1 * */1` every day.
//!
//! One parser serves the compile time and the run time, so the texts of
//! its refusals are the same in both. `next` searches field by field with
//! carry, at most 9 years ahead, and allocates nothing.

const std = @import("std");
const Io = std.Io;
const calendar = @import("calendar.zig");
const args = @import("args.zig");

/// A parsed expression: the values of each field as bits, and the text,
/// which the schedule borrows.
pub const Cron = struct {
    /// Bits 0–59; only bit 0 in an expression of 5 fields.
    seconds: u64,
    /// Bits 0–59.
    minutes: u64,
    /// Bits 0–23.
    hours: u32,
    /// Bits 1–31.
    days: u32,
    /// Bits 1–12.
    months: u16,
    /// Bits 0–6, Sunday 0.
    weekdays: u8,
    /// The day of the month is exactly `*`: the day of the week decides.
    any_day: bool,
    /// The day of the week is exactly `*`: the day of the month decides.
    any_weekday: bool,
    /// The expression as the code wrote it.
    expression: []const u8,

    /// The first moment strictly after `from`, both in milliseconds from
    /// the epoch, at most 9 years ahead; null when none comes in that time.
    pub fn next(c: Cron, from: i64) ?i64 {
        const start = @divFloor(from, 1000) + 1;
        var day = @divFloor(start, 86_400);
        var from_second: u17 = @intCast(@mod(start, 86_400));
        const last_day = day + search_days;
        while (day <= last_day) {
            const date = calendar.civilFromDays(day);
            if (c.months & bit(date.month) == 0) {
                // On to the first day of the next month.
                const year = if (date.month == 12) date.year + 1 else date.year;
                day = calendar.daysFromCivil(year, if (date.month == 12) 1 else date.month + 1, 1);
                from_second = 0;
                continue;
            }
            if (c.hasDay(day, date.day)) {
                if (c.firstSecond(from_second)) |second| return (day * 86_400 + second) * 1000;
            }
            day += 1;
            from_second = 0;
        }
        return null;
    }

    fn hasDay(c: Cron, day: i64, day_of_month: u5) bool {
        const by_day = c.days & bit(day_of_month) != 0;
        // 1970-01-01 was a Thursday, day 4 with Sunday 0.
        const by_weekday = c.weekdays & bit(@intCast(@mod(day + 4, 7))) != 0;
        if (c.any_day) return by_weekday;
        if (c.any_weekday) return by_day;
        return by_day or by_weekday;
    }

    /// The first second of a day, at `from` or later, that the hours, the
    /// minutes and the seconds allow.
    fn firstSecond(c: Cron, from: u17) ?i64 {
        const from_hour: u6 = @intCast(from / 3600);
        const from_minute: u6 = @intCast(from / 60 % 60);
        const from_second: u6 = @intCast(from % 60);
        var hour = firstBit(c.hours, from_hour);
        while (hour) |h| : (hour = if (h == 23) null else firstBit(c.hours, h + 1)) {
            var minute = firstBit(c.minutes, if (h == from_hour) from_minute else 0);
            while (minute) |m| : (minute = if (m == 59) null else firstBit(c.minutes, m + 1)) {
                const second = firstBit(c.seconds, if (h == from_hour and m == from_minute) from_second else 0) orelse continue;
                return @as(i64, h) * 3600 + @as(i64, m) * 60 + second;
            }
        }
        return null;
    }

    /// `cron` and the fields joined by single spaces; a macro as written.
    pub fn format(c: Cron, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll("cron");
        var fields = std.mem.tokenizeAny(u8, c.expression, " \t");
        while (fields.next()) |field| {
            try w.writeByte(' ');
            try w.writeAll(field);
        }
    }
};

/// How far `next` looks ahead: 9 years. The longest wait of an expression
/// that `parse` takes is 29 February from 2096 to 2104.
const search_days = 9 * 365 + 3;

fn bit(v: u6) u64 {
    return @as(u64, 1) << v;
}

/// The first bit of `set` at `from` or after it.
fn firstBit(set: u64, from: u6) ?u6 {
    const rest = set >> from;
    if (rest == 0) return null;
    return @intCast(from + @ctz(rest));
}

/// Why `parse` refused an expression.
pub const Problem = struct {
    kind: Kind,
    /// The field at fault, 0 for the first as written; with `six`, the
    /// first is the second.
    field: u8 = 0,
    six: bool = false,
    /// The item, the field or the macro at fault, as written.
    item: []const u8 = "",
    /// The character that is not in v1.
    char: u8 = 0,
    /// The count of fields.
    count: usize = 0,
    /// The days of the month and the months that never meet.
    days: u32 = 0,
    months: u16 = 0,

    pub const Kind = enum { fields, reboot, every, macro, alone, not_in_v1, value, step, step_after_value, backwards, empty_item, impossible };

    /// Why the expression is refused; the text after `cron "<expression>": `.
    pub fn format(p: Problem, w: *Io.Writer) Io.Writer.Error!void {
        switch (p.kind) {
            .fields => {
                if (p.count != 0) try w.print("{d} fields; ", .{p.count});
                try w.writeAll("an expression has 5 fields (minute, hour, day of the month, month, day of the week) or 6, the second first");
                if (p.count == 7) try w.writeAll("; a year is not in v1");
            },
            .reboot => try w.writeAll("@reboot is not in v1"),
            .every => try w.writeAll("@every is not in v1; a step from the epoch is .everySeconds(n), .everyMinutes(n) or .everyHours(n)"),
            .macro => try w.print("{f} is no macro; the macros are @yearly, @annually, @monthly, @weekly, @daily, @midnight and @hourly", .{args.Quoted{ .text = p.item }}),
            .alone => try w.writeAll("a macro stands alone"),
            .impossible => try p.writeImpossible(w),
            .not_in_v1, .value, .step, .step_after_value, .backwards, .empty_item => {
                const fields: []const Field = if (p.six) &all_fields else all_fields[1..];
                const field = fields[p.field];
                try w.print("field {d}, {s}, \"{f}\": ", .{ p.field + 1, field.name, args.Quoted{ .text = p.item } });
                switch (p.kind) {
                    .not_in_v1 => try w.print("{c} is not in v1{s}", .{ p.char, if (p.char == '?') "; write *" else "" }),
                    .value => try w.writeAll(field.rule),
                    .step => try w.writeAll("a step is 1 or more"),
                    .step_after_value => {
                        const slash = std.mem.indexOfScalar(u8, p.item, '/') orelse p.item.len;
                        const step: args.Quoted = .{ .text = p.item[@min(slash + 1, p.item.len)..] };
                        try w.print("a step goes after * or a range, as */{f} or {f}-{d}/{f}", .{ step, args.Quoted{ .text = p.item[0..slash] }, field.star_max, step });
                    },
                    .backwards => try writeBackwards(w, field, p.item),
                    .empty_item => try w.writeAll("a list has no empty item"),
                    else => unreachable,
                }
            },
        }
    }

    /// "day 30 never comes in February, and the day of the week is *".
    fn writeImpossible(p: Problem, w: *Io.Writer) Io.Writer.Error!void {
        const many = @popCount(p.days) > 1;
        try w.writeAll(if (many) "days " else "day ");
        var days: [31][]const u8 = undefined;
        var numbers: [31][2]u8 = undefined;
        var day_count: usize = 0;
        for (1..32) |day| {
            if (p.days & bit(@intCast(day)) == 0) continue;
            const text = std.fmt.bufPrint(&numbers[day_count], "{d}", .{day}) catch unreachable;
            days[day_count] = text;
            day_count += 1;
        }
        try writeList(w, days[0..day_count], "and");
        try w.writeAll(if (many) " never come in " else " never comes in ");
        var months: [12][]const u8 = undefined;
        var month_count: usize = 0;
        for (1..13) |month| {
            if (p.months & bit(@intCast(month)) == 0) continue;
            months[month_count] = month_titles[month - 1];
            month_count += 1;
        }
        try writeList(w, months[0..month_count], "or");
        try w.writeAll(", and the day of the week is *");
    }
};

/// "a", "a and b", "a, b and c".
fn writeList(w: *Io.Writer, items: []const []const u8, last: []const u8) Io.Writer.Error!void {
    for (items, 0..) |item, i| {
        if (i != 0) try w.writeAll(if (i == items.len - 1) " " else ", ");
        if (i != 0 and i == items.len - 1) try w.print("{s} ", .{last});
        try w.writeAll(item);
    }
}

/// The rule a range breaks whose lower end comes last, `item` of `field`,
/// and the line that means what it most likely meant: the range wrapped
/// round the end of its field, "22-2" as "22-23,0-2", by the same step. A
/// range of the days of the week that ends on Sunday ends on 7 instead,
/// and one that starts on 7 starts on 0.
fn writeBackwards(w: *Io.Writer, field: Field, item: []const u8) Io.Writer.Error!void {
    const slash = std.mem.indexOfScalar(u8, item, '/') orelse item.len;
    const base = item[0..slash];
    // "/n", or "" without a step.
    const step_text = item[slash..];
    const step: u64 = @max(1, if (step_text.len == 0) 1 else number(step_text[1..]) orelse 1);
    const dash = std.mem.indexOfScalar(u8, base, '-') orelse base.len;
    const low_text = base[0..dash];
    const high_text = base[@min(dash + 1, base.len)..];
    const low = value(low_text, field) orelse return w.writeAll("a range goes up and does not wrap");
    const high = value(high_text, field) orelse return w.writeAll("a range goes up and does not wrap");
    // The day of the week, whose 7 is Sunday again.
    if (field.max > field.star_max) {
        if (high == 0) return w.print("a range goes up, and Sunday is 7 too: write {s}-7{s}", .{ low_text, step_text });
        if (low == field.max) return w.print("a range goes up, and Sunday is 0 too: write 0-{s}{s}", .{ high_text, step_text });
    }
    try w.writeAll("a range goes up and does not wrap: write ");
    // From the lower end to the end of the field, then on from its start.
    const last = low + (field.star_max - low) / step * step;
    try w.writeAll(low_text);
    if (last != low) {
        try w.writeByte('-');
        try writeValue(w, field, field.star_max, low_text);
        if (step > 1) try w.writeAll(step_text);
    }
    // A step past the end saturates, and leaves nothing after it.
    const first = (last +| step) - (field.star_max - field.min + 1);
    if (first > high) return;
    try w.writeByte(',');
    if (first == high) return w.writeAll(high_text);
    try writeValue(w, field, first, high_text);
    if (first +| step > high) return;
    try w.print("-{s}{s}", .{ high_text, if (step > 1) step_text else "" });
}

/// `v` of `field` as `like` writes its end of a range: a name, in its case,
/// or a number.
fn writeValue(w: *Io.Writer, field: Field, v: u64, like: []const u8) Io.Writer.Error!void {
    if (number(like) != null or field.names.len == 0) return w.print("{d}", .{v});
    const lower = std.ascii.isLower(like[0]);
    for (field.names[@intCast(v - field.first_name)]) |c| try w.writeByte(if (lower) c else std.ascii.toUpper(c));
}

const month_titles = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

/// A field of an expression: how the texts name it and the values it takes.
const Field = struct {
    name: []const u8,
    /// Its values, for the text of a value it refuses.
    rule: []const u8,
    min: u8,
    max: u8,
    /// The last value of `*`: 6 for the day of the week, whose 7 is Sunday
    /// again.
    star_max: u8,
    names: []const []const u8 = &.{},
    first_name: u8 = 0,
};

/// The six fields; an expression of five starts at the minute.
const all_fields = [6]Field{
    .{ .name = "the second", .rule = "a second is 0–59", .min = 0, .max = 59, .star_max = 59 },
    .{ .name = "the minute", .rule = "a minute is 0–59", .min = 0, .max = 59, .star_max = 59 },
    .{ .name = "the hour", .rule = "an hour is 0–23", .min = 0, .max = 23, .star_max = 23 },
    .{ .name = "the day of the month", .rule = "a day of the month is 1–31", .min = 1, .max = 31, .star_max = 31 },
    .{
        .name = "the month",
        .rule = "a month is 1–12 or JAN–DEC",
        .min = 1,
        .max = 12,
        .star_max = 12,
        .names = &.{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" },
        .first_name = 1,
    },
    .{
        .name = "the day of the week",
        .rule = "a day of the week is 0–7 or SUN–SAT; Sunday is 0 and 7",
        .min = 0,
        .max = 7,
        .star_max = 6,
        .names = &.{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" },
    },
};

/// The macros and the expressions they stand for.
const macros = [_][2][]const u8{
    .{ "@yearly", "0 0 1 1 *" },
    .{ "@annually", "0 0 1 1 *" },
    .{ "@monthly", "0 0 1 * *" },
    .{ "@weekly", "0 0 * * 0" },
    .{ "@daily", "0 0 * * *" },
    .{ "@midnight", "0 0 * * *" },
    .{ "@hourly", "0 * * * *" },
};

pub const Parsed = union(enum) { cron: Cron, problem: Problem };

/// Reads an expression; spaces and tabs around and between the fields do
/// not count. The result borrows `expression`.
pub fn parse(expression: []const u8) Parsed {
    const trimmed = std.mem.trim(u8, expression, " \t");
    if (trimmed.len != 0 and trimmed[0] == '@') return parseMacro(expression, trimmed);
    var tokens: [6][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    while (it.next()) |token| : (count += 1) {
        if (count < tokens.len) tokens[count] = token;
    }
    if (count != 5 and count != 6) return .{ .problem = .{ .kind = .fields, .count = count } };
    const six = count == 6;
    const fields: []const Field = if (six) &all_fields else all_fields[1..];
    var sets: [6]u64 = undefined;
    for (tokens[0..count], fields, 0..) |token, field, i| {
        var problem: Problem = .{ .kind = .value, .field = @intCast(i), .six = six };
        sets[i] = parseField(token, field, &problem) catch return .{ .problem = problem };
    }
    // The sets in the order of the six fields.
    const at: [6]u64 = if (six) sets else .{ 1, sets[0], sets[1], sets[2], sets[3], sets[4] };
    const day_token = tokens[if (six) 3 else 2];
    const weekday_token = tokens[if (six) 5 else 4];
    var weekdays = at[5];
    // 7 is Sunday, which is 0.
    if (weekdays & bit(7) != 0) weekdays = (weekdays & ~bit(7)) | 1;
    const c: Cron = .{
        .seconds = at[0],
        .minutes = at[1],
        .hours = @intCast(at[2]),
        .days = @intCast(at[3]),
        .months = @intCast(at[4]),
        .weekdays = @intCast(weekdays),
        .any_day = std.mem.eql(u8, day_token, "*"),
        .any_weekday = std.mem.eql(u8, weekday_token, "*"),
        .expression = expression,
    };
    // With the day of the week `*`, the day of the month decides: some day
    // of it must come in some month of the expression. 29 February comes
    // in a leap year.
    if (c.any_weekday and !c.any_day) {
        const comes = for (1..13) |month| {
            if (c.months & bit(@intCast(month)) == 0) continue;
            const longest: u6 = if (month == 2) 29 else calendar.daysIn(2026, @intCast(month));
            if (c.days & (bit(longest + 1) - 2) != 0) break true;
        } else false;
        if (!comes) return .{ .problem = .{ .kind = .impossible, .days = c.days, .months = c.months } };
    }
    return .{ .cron = c };
}

fn parseMacro(expression: []const u8, trimmed: []const u8) Parsed {
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    const word = trimmed[0..end];
    for (macros) |macro| {
        if (!std.ascii.eqlIgnoreCase(word, macro[0])) continue;
        if (end != trimmed.len) return .{ .problem = .{ .kind = .alone, .item = word } };
        var parsed = parse(macro[1]);
        parsed.cron.expression = expression;
        return parsed;
    }
    if (std.ascii.eqlIgnoreCase(word, "@reboot")) return .{ .problem = .{ .kind = .reboot, .item = word } };
    if (std.ascii.eqlIgnoreCase(word, "@every")) return .{ .problem = .{ .kind = .every, .item = word } };
    return .{ .problem = .{ .kind = .macro, .item = word } };
}

/// The values of a field as bits; on a refusal, `problem` says why.
fn parseField(token: []const u8, field: Field, problem: *Problem) error{Refused}!u64 {
    var set: u64 = 0;
    var items = std.mem.splitScalar(u8, token, ',');
    while (items.next()) |item| {
        if (item.len == 0) return refuse(problem, .empty_item, token, 0);
        set |= try parseItem(item, field, problem);
    }
    return set;
}

fn parseItem(item: []const u8, field: Field, problem: *Problem) error{Refused}!u64 {
    const slash = std.mem.indexOfScalar(u8, item, '/');
    const base = if (slash) |i| item[0..i] else item;
    var step: u64 = 1;
    if (slash) |i| {
        step = number(item[i + 1 ..]) orelse 0;
        if (step == 0) return refuse(problem, .step, item, 0);
    }
    var low: u8 = field.min;
    var high: u8 = field.star_max;
    if (!std.mem.eql(u8, base, "*")) {
        if (std.mem.indexOfScalar(u8, base, '-')) |dash| {
            low = value(base[0..dash], field) orelse return refuseValue(problem, item, base);
            high = value(base[dash + 1 ..], field) orelse return refuseValue(problem, item, base);
            if (low > high) return refuse(problem, .backwards, item, 0);
        } else {
            low = value(base, field) orelse return refuseValue(problem, item, base);
            if (slash != null) return refuse(problem, .step_after_value, item, 0);
            high = low;
        }
    }
    var set: u64 = 0;
    var v: u64 = low;
    while (v <= high) : (v +|= step) set |= bit(@intCast(v));
    return set;
}

fn refuse(problem: *Problem, kind: Problem.Kind, item: []const u8, char: u8) error{Refused} {
    problem.kind = kind;
    problem.item = item;
    problem.char = char;
    return error.Refused;
}

/// A value that is no number and no name of the field: one of the
/// characters of other dialects that v1 lacks, or a wrong value.
fn refuseValue(problem: *Problem, item: []const u8, base: []const u8) error{Refused} {
    if (std.mem.indexOfAny(u8, item, "?#")) |i| return refuse(problem, .not_in_v1, item, item[i]);
    const last = base.len != 0 and (base[base.len - 1] == 'L' or base[base.len - 1] == 'l');
    if (std.ascii.eqlIgnoreCase(base, "LW") or (last and digits(base[0 .. base.len - 1]))) return refuse(problem, .not_in_v1, item, 'L');
    const nearest = base.len > 1 and (base[base.len - 1] == 'W' or base[base.len - 1] == 'w');
    if (nearest and digits(base[0 .. base.len - 1])) return refuse(problem, .not_in_v1, item, 'W');
    const hash = base.len != 0 and (base[0] == 'H' or base[0] == 'h') and (base.len == 1 or base[1] == '(');
    if (hash) return refuse(problem, .not_in_v1, item, 'H');
    return refuse(problem, .value, item, 0);
}

/// Whether `text` is digits only; "" counts, for a lone `L`.
fn digits(text: []const u8) bool {
    for (text) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// A number or a name of the field within its values.
fn value(text: []const u8, field: Field) ?u8 {
    if (number(text)) |n| return if (n >= field.min and n <= field.max) @intCast(n) else null;
    for (field.names, 0..) |name, i| {
        if (std.ascii.eqlIgnoreCase(text, name)) return @intCast(i + field.first_name);
    }
    return null;
}

/// A decimal number, digits only; one too long for `u64` saturates.
fn number(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    var n: u64 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        n = n *| 10 +| (c - '0');
    }
    return n;
}
