const std = @import("std");

const linux = std.os.linux;
const mem = std.mem;

const KDFONTOP: usize = 0x4B72;
const KD_FONT_OP_GET: c_uint = 1;

const max_font_width: c_uint = 64;
const max_font_height: c_uint = 128;

const ConsoleFontOp = extern struct {
    op: c_uint,
    flags: c_uint,
    width: c_uint,
    height: c_uint,
    charcount: c_uint,
    data: ?*anyopaque,
};

const CellSize = struct {
    width: u16,
    height: u16,
};

const Resolution = struct {
    width: u16,
    height: u16,
};

const FindResult = union(enum) {
    not_ready,
    ambiguous,
    resolution: Resolution,
};

pub const SyncResult = enum {
    not_ready,
    ambiguous,
    unchanged,
    resized,
};

/// Synchronize a Linux virtual console's rows/columns with the preferred
/// resolution of a DRM connector.
///
/// Unlike tuigreet's ws_xpixel/ws_ypixel inference, this asks the Linux
/// virtual console for its actual font dimensions with KDFONTOP. That means
/// the calculation still works when TIOCGWINSZ reports zero pixel dimensions.
pub fn syncTerminalToOutput(
    fd: std.posix.fd_t,
    requested_connector: ?[]const u8,
) !SyncResult {
    const resolution = switch (try findResolution(requested_connector)) {
        .not_ready => return .not_ready,
        .ambiguous => return .ambiguous,
        .resolution => |value| value,
    };

    const cell = try getConsoleFontCellSize(fd);

    const new_cols: u16 = resolution.width / cell.width;
    const new_rows: u16 = resolution.height / cell.height;

    if (new_cols == 0 or new_rows == 0) {
        return .not_ready;
    }

    const current = try getWinSize(fd);

    if (current.ws_col == new_cols and
        current.ws_row == new_rows and
        current.ws_xpixel == resolution.width and
        current.ws_ypixel == resolution.height)
    {
        return .unchanged;
    }

    try setWinSize(fd, .{
        .ws_row = new_rows,
        .ws_col = new_cols,
        .ws_xpixel = resolution.width,
        .ws_ypixel = resolution.height,
    });

    return .resized;
}

fn findResolution(requested_connector: ?[]const u8) !FindResult {
    var drm = std.fs.openDirAbsolute("/sys/class/drm", .{
        .iterate = true,
    }) catch return .not_ready;
    defer drm.close();

    var iter = drm.iterate();
    var automatic: ?Resolution = null;

    while (try iter.next()) |entry| {
        // Connector entries are named like card0-eDP-1, card1-DP-1, etc.
        const dash = mem.indexOfScalar(u8, entry.name, '-') orelse continue;
        const card = entry.name[0..dash];
        const connector = entry.name[dash + 1 ..];

        if (!mem.startsWith(u8, card, "card") or connector.len == 0) {
            continue;
        }

        if (requested_connector) |requested| {
            if (!mem.eql(u8, connector, requested)) {
                continue;
            }
        } else {
            // SimpleDRM commonly exposes an Unknown-* connector. Do not use
            // it for automatic sizing: wait for the native DRM driver instead.
            if (mem.startsWith(u8, connector, "Unknown-")) {
                continue;
            }
        }

        const resolution = readConnectedResolution(drm, entry.name) orelse continue;

        if (requested_connector != null) {
            return .{ .resolution = resolution };
        }

        // With multiple connected native outputs, choosing one implicitly is
        // unsafe because they may have different native resolutions.
        if (automatic != null) {
            return .ambiguous;
        }

        automatic = resolution;
    }

    if (automatic) |resolution| {
        return .{ .resolution = resolution };
    }

    return .not_ready;
}

fn readConnectedResolution(
    drm: std.fs.Dir,
    entry_name: []const u8,
) ?Resolution {
    var connector_dir = drm.openDir(entry_name, .{}) catch return null;
    defer connector_dir.close();

    var status_buffer: [32]u8 = undefined;
    const status = connector_dir.readFile("status", &status_buffer) catch return null;

    if (!mem.eql(u8, mem.trim(u8, status, " \t\r\n"), "connected")) {
        return null;
    }

    var modes_file = connector_dir.openFile("modes", .{}) catch return null;
    defer modes_file.close();

    var mode_buffer: [64]u8 = undefined;
    const mode = (modes_file.reader().readUntilDelimiterOrEof(
        &mode_buffer,
        '\n',
    ) catch return null) orelse return null;

    return parseResolution(mode);
}

fn parseResolution(mode: []const u8) ?Resolution {
    const trimmed = mem.trim(u8, mode, " \t\r\n");
    const x = mem.indexOfScalar(u8, trimmed, 'x') orelse return null;

    const width = std.fmt.parseInt(u16, trimmed[0..x], 10) catch return null;
    const height = std.fmt.parseInt(u16, trimmed[x + 1 ..], 10) catch return null;

    if (width == 0 or height == 0) {
        return null;
    }

    return .{
        .width = width,
        .height = height,
    };
}

fn getConsoleFontCellSize(fd: std.posix.fd_t) !CellSize {
    // KDFONTOP/KD_FONT_OP_GET fills width and height even when data is null.
    // width/height are input limits as well, so initialize them to the current
    // kernel's documented maximums before issuing the GET operation.
    var op: ConsoleFontOp = .{
        .op = KD_FONT_OP_GET,
        .flags = 0,
        .width = max_font_width,
        .height = max_font_height,
        .charcount = 0,
        .data = null,
    };

    try ioctlPtr(fd, KDFONTOP, &op);

    if (op.width == 0 or op.height == 0 or
        op.width > std.math.maxInt(u16) or op.height > std.math.maxInt(u16))
    {
        return error.InvalidConsoleFontSize;
    }

    return .{
        .width = @intCast(op.width),
        .height = @intCast(op.height),
    };
}

fn getWinSize(fd: std.posix.fd_t) !linux.winsize {
    var ws: linux.winsize = .{
        .ws_row = 0,
        .ws_col = 0,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    try ioctlPtr(fd, linux.T.IOCGWINSZ, &ws);
    return ws;
}

fn setWinSize(fd: std.posix.fd_t, new_size: linux.winsize) !void {
    var ws = new_size;
    try ioctlPtr(fd, linux.T.IOCSWINSZ, &ws);
}

fn ioctlPtr(fd: std.posix.fd_t, request: usize, ptr: anytype) !void {
    while (true) {
        const rc = linux.syscall3(
            .ioctl,
            @as(usize, @intCast(fd)),
            request,
            @intFromPtr(ptr),
        );

        switch (linux.E.init(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.IoctlFailed,
        }
    }
}
