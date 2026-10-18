//! Drivers and cursors that must not compile, one test each.
//! `zig build test-mongo` compiles every test on its own and checks its
//! error message; the list of messages is in build.zig.

const std = @import("std");
const mongo = @import("mongo");

/// A driver with all four methods right.
const Driver = struct {
    calls: u32 = 0,

    pub fn runCommand(self: *Driver, io: std.Io, op: mongo.OperationContext, command: *const mongo.Command, options: mongo.CommandOptions) mongo.Error!mongo.bson.OwnedDocument {
        _ = self;
        _ = io;
        _ = op;
        _ = command;
        _ = options;
        return error.Unsupported;
    }

    pub fn openCursor(self: *Driver, io: std.Io, op: mongo.OperationContext, command: *const mongo.Command, options: mongo.CursorOptions) mongo.Error!mongo.Cursor {
        _ = self;
        _ = io;
        _ = op;
        _ = command;
        _ = options;
        return error.Unsupported;
    }

    pub fn write(self: *Driver, io: std.Io, op: mongo.OperationContext, request: *const mongo.WriteRequest, options: mongo.WriteOptions) mongo.Error!mongo.WriteResult {
        _ = self;
        _ = io;
        _ = op;
        _ = request;
        _ = options;
        return error.Unsupported;
    }

    pub fn capabilities(self: *Driver) mongo.Capabilities {
        _ = self;
        return .{ .revision = 1, .name = "driver" };
    }
};

/// A cursor with all three methods right.
const Cursor = struct {
    closed: bool = false,

    pub fn next(self: *Cursor, io: std.Io, op: mongo.OperationContext) mongo.Error!?mongo.bson.RawDocument {
        _ = self;
        _ = io;
        _ = op;
        return null;
    }

    pub fn close(self: *Cursor, io: std.Io) void {
        _ = io;
        self.closed = true;
    }

    pub fn deinit(self: *Cursor, io: std.Io) void {
        _ = io;
        self.closed = true;
    }
};

test "client init with a value" {
    const driver: Driver = .{};
    _ = mongo.Client.init(driver);
}

test "client init with a pointer to a constant" {
    const driver: Driver = .{};
    _ = mongo.Client.init(&driver);
}

test "driver without write" {
    const NoWrite = struct {
        calls: u32 = 0,
        pub fn runCommand(self: *@This(), io: std.Io, op: mongo.OperationContext, command: *const mongo.Command, options: mongo.CommandOptions) mongo.Error!mongo.bson.OwnedDocument {
            _ = self;
            _ = io;
            _ = op;
            _ = command;
            _ = options;
            return error.Unsupported;
        }
        pub fn openCursor(self: *@This(), io: std.Io, op: mongo.OperationContext, command: *const mongo.Command, options: mongo.CursorOptions) mongo.Error!mongo.Cursor {
            _ = self;
            _ = io;
            _ = op;
            _ = command;
            _ = options;
            return error.Unsupported;
        }
        pub fn capabilities(self: *@This()) mongo.Capabilities {
            _ = self;
            return .{ .revision = 1, .name = "x" };
        }
    };
    var driver: NoWrite = .{};
    _ = mongo.Client.init(&driver);
}

test "runCommand that takes the command by value" {
    const ByValue = struct {
        calls: u32 = 0,
        pub fn runCommand(self: *@This(), io: std.Io, op: mongo.OperationContext, command: mongo.Command, options: mongo.CommandOptions) mongo.Error!mongo.bson.OwnedDocument {
            _ = self;
            _ = io;
            _ = op;
            _ = command;
            _ = options;
            return error.Unsupported;
        }
        pub fn openCursor(self: *@This(), io: std.Io, op: mongo.OperationContext, command: *const mongo.Command, options: mongo.CursorOptions) mongo.Error!mongo.Cursor {
            _ = self;
            _ = io;
            _ = op;
            _ = command;
            _ = options;
            return error.Unsupported;
        }
        pub fn write(self: *@This(), io: std.Io, op: mongo.OperationContext, request: *const mongo.WriteRequest, options: mongo.WriteOptions) mongo.Error!mongo.WriteResult {
            _ = self;
            _ = io;
            _ = op;
            _ = request;
            _ = options;
            return error.Unsupported;
        }
        pub fn capabilities(self: *@This()) mongo.Capabilities {
            _ = self;
            return .{ .revision = 1, .name = "x" };
        }
    };
    var driver: ByValue = .{};
    _ = mongo.Client.init(&driver);
}

test "openCursor with an inferred error set" {
    const Inferred = struct {
        calls: u32 = 0,
        pub fn runCommand(self: *@This(), io: std.Io, op: mongo.OperationContext, command: *const mongo.Command, options: mongo.CommandOptions) mongo.Error!mongo.bson.OwnedDocument {
            _ = self;
            _ = io;
            _ = op;
            _ = command;
            _ = options;
            return error.Unsupported;
        }
        pub fn openCursor(self: *@This(), io: std.Io, op: mongo.OperationContext, command: *const mongo.Command, options: mongo.CursorOptions) !mongo.Cursor {
            _ = self;
            _ = io;
            _ = op;
            _ = command;
            _ = options;
            return error.Unsupported;
        }
        pub fn write(self: *@This(), io: std.Io, op: mongo.OperationContext, request: *const mongo.WriteRequest, options: mongo.WriteOptions) mongo.Error!mongo.WriteResult {
            _ = self;
            _ = io;
            _ = op;
            _ = request;
            _ = options;
            return error.Unsupported;
        }
        pub fn capabilities(self: *@This()) mongo.Capabilities {
            _ = self;
            return .{ .revision = 1, .name = "x" };
        }
    };
    var driver: Inferred = .{};
    _ = mongo.Client.init(&driver);
}

test "capabilities that take io" {
    const WithIo = struct {
        calls: u32 = 0,
        pub fn runCommand(self: *@This(), io: std.Io, op: mongo.OperationContext, command: *const mongo.Command, options: mongo.CommandOptions) mongo.Error!mongo.bson.OwnedDocument {
            _ = self;
            _ = io;
            _ = op;
            _ = command;
            _ = options;
            return error.Unsupported;
        }
        pub fn openCursor(self: *@This(), io: std.Io, op: mongo.OperationContext, command: *const mongo.Command, options: mongo.CursorOptions) mongo.Error!mongo.Cursor {
            _ = self;
            _ = io;
            _ = op;
            _ = command;
            _ = options;
            return error.Unsupported;
        }
        pub fn write(self: *@This(), io: std.Io, op: mongo.OperationContext, request: *const mongo.WriteRequest, options: mongo.WriteOptions) mongo.Error!mongo.WriteResult {
            _ = self;
            _ = io;
            _ = op;
            _ = request;
            _ = options;
            return error.Unsupported;
        }
        pub fn capabilities(self: *@This(), io: std.Io) mongo.Capabilities {
            _ = self;
            _ = io;
            return .{ .revision = 1, .name = "x" };
        }
    };
    var driver: WithIo = .{};
    _ = mongo.Client.init(&driver);
}

test "cursor init with a value" {
    const cursor: Cursor = .{};
    _ = mongo.Cursor.init(cursor);
}

test "cursor init with a pointer to a constant" {
    const cursor: Cursor = .{};
    _ = mongo.Cursor.init(&cursor);
}

test "cursor without close" {
    const NoClose = struct {
        closed: bool = false,
        pub fn next(self: *@This(), io: std.Io, op: mongo.OperationContext) mongo.Error!?mongo.bson.RawDocument {
            _ = self;
            _ = io;
            _ = op;
            return null;
        }
        pub fn deinit(self: *@This(), io: std.Io) void {
            _ = io;
            self.closed = true;
        }
    };
    var cursor: NoClose = .{};
    _ = mongo.Cursor.init(&cursor);
}

test "next that gives an owned document" {
    const Owned = struct {
        closed: bool = false,
        pub fn next(self: *@This(), io: std.Io, op: mongo.OperationContext) mongo.Error!?mongo.bson.OwnedDocument {
            _ = self;
            _ = io;
            _ = op;
            return null;
        }
        pub fn close(self: *@This(), io: std.Io) void {
            _ = io;
            self.closed = true;
        }
        pub fn deinit(self: *@This(), io: std.Io) void {
            _ = io;
            self.closed = true;
        }
    };
    var cursor: Owned = .{};
    _ = mongo.Cursor.init(&cursor);
}
