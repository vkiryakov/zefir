//! The variants of the probe's programs: the server alone (`None`, the
//! baseline), and the server with its document (`Real`), which
//! zefir.openapi.document builds at compile time from the type of the
//! server's options and `Document.write` writes when the program runs.
const oa = @import("openapi");

pub const None = struct {
    pub const Result = void;

    pub fn document(comptime Options: type) void {
        _ = Options;
    }
};

pub const Real = struct {
    pub const Result = oa.Document;

    pub fn document(comptime Options: type) oa.Document {
        return comptime oa.document(Options, .{ .info = .{ .title = "Probe API", .version = "1.0.0" } });
    }
};
