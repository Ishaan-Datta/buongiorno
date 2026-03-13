const std = @import("std");
const builtin = @import("builtin");

const native_endian = builtin.target.cpu.arch.endian();

pub const Login = struct {
    request: Request,
    password: []const u8,
    command: []const u8,
    command_sent: bool = false,

    const Reaction = enum {
        ok,
        failed,
    };

    pub fn run(self: *Login, allocator: std.mem.Allocator, stream: std.net.Stream) !Reaction {
        while (true) {
            try self.request.writeTo(allocator, stream.writer().any());
            if (self.request == .cancel_session) return .failed;

            const response = try Response.readFrom(allocator, stream.reader());
            defer response.deinit(allocator);

            switch (response) {
                .success => {
                    if (self.command_sent) {
                        return .ok;
                    } else {
                        self.command_sent = true;
                        self.request = .{ .start_session = .{
                            .cmd = &.{self.command},
                            .env = &.{},
                        } };
                    }
                },
                .@"error" => {
                    self.request = .cancel_session;
                },
                .auth_message => |data| {
                    self.request = switch (data.auth_message_type) {
                        .secret => .{ .post_auth_message_response = .{
                            .response = self.password,
                        } },
                        else => .cancel_session,
                    };
                },
            }
        }
    }
};

pub const Request = union(enum) {
    create_session: struct {
        username: []const u8,
    },
    post_auth_message_response: struct {
        response: ?[]const u8,
    },
    start_session: struct {
        cmd: []const []const u8,
        env: []const []const u8,
    },
    cancel_session,

    pub fn writeTo(self: Request, allocator: std.mem.Allocator, writer: std.io.AnyWriter) !void {
        var payload = std.ArrayList(u8).init(allocator);
        defer payload.deinit();

        switch (self) {
            .cancel_session => {
                try payload.appendSlice("{{\"type\":\"cancel_session\"}}");
            },
            inline else => |data| {
                const content = try std.json.stringifyAlloc(allocator, data, .{});
                defer allocator.free(content);

                try payload.writer().print("{{\"type\":\"{s}\",{s}}}", .{
                    @tagName(self),
                    content[1 .. content.len - 1],
                });
            },
        }

        try writer.writeInt(u32, @intCast(payload.items.len), native_endian);
        try writer.writeAll(payload.items);
    }
};

pub const Response = union(enum) {
    success: struct {},
    @"error": struct {
        error_type: enum { auth_error, @"error" },
        description: []const u8,
    },
    auth_message: struct {
        auth_message_type: enum { visible, secret, info, @"error" },
        auth_message: []const u8,
    },

    pub fn readFrom(allocator: std.mem.Allocator, reader: std.net.Stream.Reader) !Response {
        const length = try reader.readInt(u32, native_endian);

        const payload = try allocator.alloc(u8, length);
        defer allocator.free(payload);

        const bytes_read = try reader.readAll(payload);
        if (bytes_read != length) return error.ResponseTooShort;

        const Partial = struct { type: []const u8 };
        const partial = try std.json.parseFromSlice(Partial, allocator, payload, .{
            .ignore_unknown_fields = true,
        });
        defer partial.deinit();

        inline for (std.meta.fields(Response)) |field| {
            if (std.mem.eql(u8, field.name, partial.value.type)) {
                const parsed = try std.json.parseFromSliceLeaky(field.type, allocator, payload, .{
                    .ignore_unknown_fields = true,
                });
                return @unionInit(Response, field.name, parsed);
            }
        }
        return error.UnknownResponseType;
    }

    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        switch (self) {
            .success => {},
            .@"error" => |res| {
                allocator.free(res.description);
            },
            .auth_message => |res| {
                allocator.free(res.auth_message);
            },
        }
    }
};

test "request: create_session" {
    var string = std.ArrayList(u8).init(std.testing.allocator);
    defer string.deinit();

    const request: Request = .{ .create_session = .{ .username = "root" } };
    try request.writeTo(std.testing.allocator, string.writer().any());

    const size = std.mem.readIntNative(u32, string.items[0..4]);
    try std.testing.expectEqual(@as(u32, 43), size);

    try std.testing.expectEqualStrings(
        "{\"type\":\"create_session\",\"username\":\"root\"}",
        string.items[4..],
    );
}

test "request: start_session" {
    var string = std.ArrayList(u8).init(std.testing.allocator);
    defer string.deinit();

    const request: Request = .{ .start_session = .{
        .cmd = &.{ "cmd", "arg" },
        .env = &.{ "name", "value" },
    } };
    try request.writeTo(std.testing.allocator, string.writer().any());

    const size = std.mem.readIntNative(u32, string.items[0..4]);
    try std.testing.expectEqual(@as(u32, 67), size);

    try std.testing.expectEqualStrings(
        "{\"type\":\"start_session\",\"cmd\":[\"cmd\",\"arg\"],\"env\":[\"name\",\"value\"]}",
        string.items[4..],
    );
}
