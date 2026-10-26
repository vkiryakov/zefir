//! `scheduler.testing`: what the tests of a worker, an application or a
//! store need. `FaultyStore` fails any store on demand: the store's errors,
//! calls that hang until their deadline, and replies lost after the store
//! applied the change.

pub const FaultyStore = @import("testing/FaultyStore.zig");
/// The operations of a store that fail on demand (`now` never fails).
pub const Op = FaultyStore.Op;
