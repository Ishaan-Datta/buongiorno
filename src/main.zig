const std = @import("std");

const clap = @import("clap");
const spoon = @import("spoon");

const ipc = @import("ipc.zig");
const ui = @import("ui.zig");

pub fn logFn(
    comptime level: std.log.Level,
    comptime _: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const syslog_level = switch (level) {
        .err => std.posix.LOG.ERR,
        .warn => std.posix.LOG.WARNING,
        .info => std.posix.LOG.INFO,
        .debug => std.posix.LOG.DEBUG,
    };
    var buffer: [1024]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buffer, format, args) catch unreachable;
    std.c.syslog(syslog_level, "%s", msg.ptr);
}

pub const std_options: std.Options = .{
    .logFn = logFn,
};

var loop: ui.Loop = .{
    .term = undefined,
    .mode = .select,
    .view = .home,
    .field = .username,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stderr = std.io.getStdErr().writer();
    const template = comptime clap.parseParamsComptime(
        \\-h, --help           Display this help and exit.
        \\-c, --command <str>  Command to run on successful login.
        \\-u, --user <str>     Set default username.
        \\
    );

    var diagnostic: clap.Diagnostic = .{};
    const params = clap.parse(clap.Help, &template, clap.parsers.default, .{
        .diagnostic = &diagnostic,
        .allocator = allocator,
    }) catch |err| {
        diagnostic.report(stderr, err) catch {};
        return;
    };
    defer params.deinit();

    if (params.args.help != 0) {
        return clap.help(stderr, clap.Help, &template, .{});
    }
    const command = params.args.command orelse {
        return clap.help(stderr, clap.Help, &template, .{});
    };
    if (params.args.user) |username| {
        try loop.username.appendSlice(username);
        loop.mode = .insert;
        loop.field = .password;
    }

    var envmap = try std.process.getEnvMap(allocator);
    defer envmap.deinit();

    const usernames = try getUsernames(allocator);
    defer {
        for (usernames) |username| allocator.free(username);
        allocator.free(usernames);
    }

    const socket_path = envmap.get("GREETD_SOCK") orelse {
        std.log.err("environment variable GREETD_SOCK must be set", .{});
        return;
    };

    const socket = std.net.connectUnixSocket(socket_path) catch {
        std.log.err("could not connect to socket at {s}", .{socket_path});
        return;
    };
    defer socket.close();

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("hello");

    try loop.init();
    defer loop.deinit();

    while (true) {
        const action = try loop.run();
        switch (action) {
            .login => |fields| {
                var login: ipc.Login = .{
                    .request = .{ .create_session = .{ .username = fields.username } },
                    .password = fields.password,
                    .command = command,
                };
                const reaction = try login.run(allocator, socket);
                switch (reaction) {
                    .ok => return,
                    .failed => try loop.reset(),
                }
            },
            .power => |subcommand| {
                loop.deinit();
                _ = try std.process.Child.run(.{
                    .allocator = allocator,
                    .argv = &.{ "systemctl", subcommand },
                });
            },
        }
    }
}

fn getUsernames(allocator: std.mem.Allocator) ![][]const u8 {
    var usernames = std.ArrayList([]const u8).init(allocator);

    passwd: {
        const passwd = std.fs.openFileAbsolute("/etc/passwd", .{}) catch break :passwd;
        defer passwd.close();

        var buffer: [128]u8 = undefined;
        while (try passwd.reader().readUntilDelimiterOrEof(&buffer, '\n')) |line| {
            var fields = std.mem.split(u8, line, ":");
            const first = fields.next().?;
            const username = try allocator.dupe(u8, first);
            try usernames.append(username);
        }
    }

    homectl: {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "homectl", "list", "--no-legend" },
        }) catch break :homectl;
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        var lines = std.mem.split(u8, result.stdout, "\n");
        while (lines.next()) |line| {
            var fields = std.mem.split(u8, line, " ");
            const first = fields.next().?;
            if (first.len == 0) continue;
            const username = try allocator.dupe(u8, first);
            try usernames.append(username);
        }
    }

    return usernames.toOwnedSlice();
}

pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    @setCold(true);
    loop.term.cook() catch {};
    std.builtin.default_panic(msg, trace, ret_addr);
}
