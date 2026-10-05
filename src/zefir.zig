//! Zefir — фреймворк. Общий модуль, реэкспортирующий все подсистемы.

pub const logger = @import("logger");
pub const confy = @import("confy");
pub const rpc = @import("rpc");
pub const orm = @import("orm");

test {
    @import("std").testing.refAllDecls(@This());
}
