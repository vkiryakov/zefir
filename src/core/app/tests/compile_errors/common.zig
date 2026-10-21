//! The shared shapes of the compile-error fixtures of zefir.App: the ready
//! objects a root declares in `.values`. Each fixture is application code
//! that imports "core" and these.
pub const Recorder = struct { len: usize = 0 };
pub const Config = struct { port: u16 = 8080 };
pub const Logger = struct { id: u32 = 0 };

/// A provider that takes the three values, so that a root which declares
/// them gives each to a bean.
pub const Uses = struct {
    rec: *Recorder,
    config: *const Config,
    logger: *const Logger,
};
