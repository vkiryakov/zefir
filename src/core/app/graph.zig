//! The module graph of zefir.App, and the tuples of controllers and
//! handlers a server factory takes.

/// The tuple of pointers to the controllers of module M, for a factory
/// param: `controllers: zefir.app.Controllers(AppModule)`.
pub fn Controllers(comptime M: type) type {
    return ListTuple(M, "controllers");
}

/// Like `Controllers`, for the handlers of rpc.
pub fn Handlers(comptime M: type) type {
    return ListTuple(M, "handlers");
}

fn ListTuple(comptime M: type, comptime list: []const u8) type {
    var types: []const type = &.{};
    for (@field(M.module, list)) |C| types = types ++ &[_]type{*C};
    return @Tuple(types);
}
