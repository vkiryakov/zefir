//! The users service of this guide as a package: its handler and its
//! repository. The examples of the guide of rpc-nats serve them on NATS.

pub const UserHandler = @import("UserHandler.zig");
pub const UserRepository = @import("UserRepository.zig");
