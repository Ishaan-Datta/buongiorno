const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;
const os = std.os;
const time = std.time;

const spoon = @import("spoon");
const console = @import("console.zig");
const PowerAction = enum { reboot, firmware, shutdown };
const title =
    \\ ____  _   _  ___  _   _  ____ ___ ___  ____  _   _  ___
    \\| __ )| | | |/ _ \| \ | |/ ___|_ _/ _ \|  _ \| \ | |/ _ \
    \\|  _ \| | | | | | |  \| | |  _ | | | | | |_) |  \| | | | |
    \\| |_) | |_| | |_| | |\  | |_| || | |_| |  _ <| |\  | |_| |
    \\|____/ \___/ \___/|_| \_|\____|___\___/|_| \_\_| \_|\___/
;
const splash =
    \\ _     ___   ____  ____ ___ _   _  ____     ___ _   _
    \\| |   / _ \ / ___|/ ___|_ _| \ | |/ ___|   |_ _| \ | |
    \\| |  | | | | |  _| |  _ | ||  \| | |  _     | ||  \| |
    \\| |__| |_| | |_| | |_| || || |\  | |_| |    | || |\  |    _   _   _
    \\|_____\___/ \____|\____|___|_| \_|\____|   |___|_| \_|   (_) (_) (_)
;
pub const Loop = struct {
    term: spoon.Term,
    context: spoon.Term.RenderContext = undefined,
    drm_output: ?[]const u8 = null,
    drm_sync_ticks: u8 = 0,
    drm_ambiguity_logged: bool = false,
    drm_error_logged: bool = false,
    view: enum { home, power } = .home,
    field: enum { username, password } = .username,
    power: PowerAction = .reboot,
    username: std.BoundedArray(u8, 1024) = .{},
    password: std.BoundedArray(u8, 1024) = .{},
    username_cursor: usize = 0,
    password_cursor: usize = 0,
    select_all: bool = false,
    pending_input: std.BoundedArray(u8, 64) = .{},
    const Key = union(enum) {
        escape,
        enter,
        tab,
        back_tab,
        backspace,
        left,
        right,
        up,
        down,
        select_all,
        character: u8,
    };
    const Action = union(enum) {
        login: struct {
            username: []const u8,
            password: []const u8,
        },
        power: PowerAction,
    };

    pub fn init(self: *Loop, drm_output: ?[]const u8) !void {
        self.drm_output = drm_output;

        try self.term.init(.{});
        try self.term.uncook(.{
            .request_kitty_keyboard_protocol = false,
            .request_mouse_tracking = false,
        });

        // Spoon disables DECARM while entering raw mode; login fields need
        // the terminal to keep generating repeated keys while they are held.
        const enable_auto_repeat = "\x1b[?8h";
        var written: usize = 0;
        while (written < enable_auto_repeat.len) {
            written += try std.posix.write(self.term.tty.?, enable_auto_repeat[written..]);
        }

        // Native DRM may already be ready by the time greetd starts.
        _ = self.syncDrmOutput(true);

        try self.term.fetchSize();
        self.context = try self.term.getRenderContext();
        try self.context.clear();
        try self.context.done();

        time.sleep(100 * time.ns_per_ms);

        // Try again after the existing startup delay. If the machine is still
        // transitioning from SimpleDRM to its native DRM driver, run() keeps
        // retrying every ~500 ms below.
        _ = self.syncDrmOutput(true);

        self.context = try self.term.getRenderContext();
        try self.renderHome();
        try self.context.done();
    }

    pub fn deinit(self: *Loop) void {
        self.term.deinit() catch unreachable;
    }
    pub fn reset(self: *Loop) !void {
        self.view = .home;
        self.field = .username;
        self.username.len = 0;
        self.password.len = 0;
        self.username_cursor = 0;
        self.password_cursor = 0;
        self.select_all = false;

        self.context = try self.term.getRenderContext();
        try self.renderHome();
        try self.context.done();
    }
    pub fn resetAfterFailedLogin(self: *Loop) !void {
        self.view = .home;
        self.field = .password;
        self.password.len = 0;
        self.password_cursor = 0;
        self.select_all = false;

        self.context = try self.term.getRenderContext();
        try self.renderHome();
        try self.context.done();
    }

    pub fn run(self: *Loop) !Action {
        try self.term.fetchSize();
        var fds = [_]std.posix.pollfd{
            .{
                .fd = self.term.tty.?,
                .events = std.posix.POLL.IN,
                .revents = undefined,
            },
        };

        var buffer: [32]u8 = undefined;
        while (true) {
            fds[0].revents = 0;

            const ready = try std.posix.poll(&fds, 100);
            if (ready == 0) {
                if (self.pending_input.len > 0) {
                    self.context = try self.term.getRenderContext();
                    defer self.context.done() catch {};
                    if (try self.processPendingInput(true)) |action| return action;
                }
                try self.redrawIfResized();
                continue;
            }
            if ((fds[0].revents & std.posix.POLL.IN) == 0) continue;

            const size = try self.term.readInput(&buffer);
            self.pending_input.appendSlice(buffer[0..size]) catch {
                self.pending_input.len = 0;
                continue;
            };

            self.context = try self.term.getRenderContext();
            defer self.context.done() catch {};
            if (try self.processPendingInput(false)) |action| return action;
        }
    }

    fn processPendingInput(self: *Loop, flush_escape: bool) !?Action {
        const bytes = self.pending_input.constSlice();
        var consumed: usize = 0;
        while (parseKey(bytes[consumed..], flush_escape)) |parsed| {
            consumed += parsed.len;
            if (parsed.key) |key| {
                if (try self.processKey(key)) |action| {
                    self.pending_input.len = 0;
                    return action;
                }
            }
        }

        self.discardPendingInput(consumed);
        return null;
    }

    fn discardPendingInput(self: *Loop, count: usize) void {
        const remaining = self.pending_input.constSlice()[count..];
        std.mem.copyForwards(u8, self.pending_input.slice()[0..remaining.len], remaining);
        self.pending_input.len = @intCast(remaining.len);
    }

    fn processKey(self: *Loop, key: Key) !?Action {
        if (self.handleKey(key)) |action| {
            switch (action) {
                .login => try self.renderSplash(),
                .power => {},
            }
            return action;
        }

        try self.renderHome();
        if (self.view == .power) try self.renderPower();
        return null;
    }

    fn handleKey(self: *Loop, key: Key) ?Action {
        switch (self.view) {
            .home => switch (key) {
                .escape => {
                    self.view = .power;
                    self.power = .reboot;
                    self.select_all = false;
                },
                .tab, .back_tab => {
                    self.field = switch (self.field) {
                        .username => .password,
                        .password => .username,
                    };
                    self.select_all = false;
                },
                .enter => switch (self.field) {
                    .username => {
                        self.field = .password;
                        self.select_all = false;
                    },
                    .password => return .{ .login = .{
                        .username = self.username.constSlice(),
                        .password = self.password.constSlice(),
                    } },
                },
                .select_all => {
                    self.select_all = true;
                    self.currentCursor().* = self.currentText().len;
                },
                .left => {
                    const cursor = self.currentCursor();
                    if (self.select_all) {
                        cursor.* = 0;
                    } else {
                        cursor.* -|= 1;
                    }
                    self.select_all = false;
                },
                .up => {
                    self.currentCursor().* = 0;
                    self.select_all = false;
                },
                .right => {
                    const cursor = self.currentCursor();
                    const text = self.currentText();
                    if (self.select_all) {
                        cursor.* = text.len;
                    } else {
                        cursor.* = @min(cursor.* + 1, text.len);
                    }
                    self.select_all = false;
                },
                .down => {
                    self.currentCursor().* = self.currentText().len;
                    self.select_all = false;
                },
                .backspace => {
                    const text = self.currentText();
                    const cursor = self.currentCursor();
                    if (self.select_all) {
                        text.len = 0;
                        cursor.* = 0;
                        self.select_all = false;
                    } else if (cursor.* > 0) {
                        _ = text.orderedRemove(cursor.* - 1);
                        cursor.* -= 1;
                    }
                },
                .character => |char| {
                    const text = self.currentText();
                    const cursor = self.currentCursor();
                    if (self.select_all) {
                        text.len = 0;
                        cursor.* = 0;
                        self.select_all = false;
                    }
                    text.insert(cursor.*, char) catch return null;
                    cursor.* += 1;
                },
            },
            .power => switch (key) {
                .escape => self.view = .home,
                .enter => return .{ .power = self.power },
                .up => self.power = switch (self.power) {
                    .reboot => .reboot,
                    .firmware => .reboot,
                    .shutdown => .firmware,
                },
                .down => self.power = switch (self.power) {
                    .reboot => .firmware,
                    .firmware => .shutdown,
                    .shutdown => .shutdown,
                },
                .tab => self.power = switch (self.power) {
                    .reboot => .firmware,
                    .firmware => .shutdown,
                    .shutdown => .reboot,
                },
                .back_tab => self.power = switch (self.power) {
                    .reboot => .shutdown,
                    .firmware => .reboot,
                    .shutdown => .firmware,
                },
                else => {},
            },
        }
        return null;
    }

    fn currentText(self: *Loop) *std.BoundedArray(u8, 1024) {
        return switch (self.field) {
            .username => &self.username,
            .password => &self.password,
        };
    }

    fn currentCursor(self: *Loop) *usize {
        return switch (self.field) {
            .username => &self.username_cursor,
            .password => &self.password_cursor,
        };
    }
    fn renderHome(self: *Loop) !void {
        try self.term.fetchSize();
        const rc = &self.context;
        try rc.clear();
        try rc.hideCursor();

        const title_height = mem.count(u8, title, "\n") + 1;
        const title_width = mem.indexOfScalar(u8, title, '\n').?;

        const title_spacing = 2;
        const field_spacing = 1;
        const field_height = 4;
        const region_height = title_height + title_spacing + field_height * 2 + field_spacing;
        const bar_height = 2;
        const vpad = (self.term.height - bar_height - region_height) / 2;
        const hpad = (self.term.width - title_width) / 2;

        var title_rows = mem.split(u8, title, "\n");
        var i: usize = 0;
        while (title_rows.next()) |line| : (i += 1) {
            try rc.moveCursorTo(vpad + i, hpad);
            try rc.writeAllWrapping(line);
        }
        const username_top = vpad + title_height + title_spacing;
        const password_top = username_top + field_height + field_spacing;

        const username = self.username.constSlice();
        const password = self.password.constSlice();
        try drawField(rc, username, .{
            .label = "username",
            .hidden = false,
            .cursor = self.username_cursor,
            .selected = self.view == .home and self.field == .username and self.select_all,
        }, .{
            .width = title_width,
            .height = field_height,
            .left = hpad,
            .top = username_top,
        });
        try drawField(rc, password, .{
            .label = "password",
            .hidden = true,
            .cursor = self.password_cursor,
            .selected = self.view == .home and self.field == .password and self.select_all,
        }, .{
            .width = title_width,
            .height = field_height,
            .left = hpad,
            .top = password_top,
        });
        try self.renderBar();

        if (self.view == .home) {
            const cursor_y = switch (self.field) {
                .username => username_top + 1 + (field_height - 1) / 2,
                .password => password_top + 1 + (field_height - 1) / 2,
            };
            const text = self.currentText();
            const cursor = self.currentCursor().*;
            const viewport_start = textViewportStart(text.len, cursor, title_width - 5);
            const cursor_x = hpad + 2 + cursor - viewport_start;
            try rc.moveCursorTo(cursor_y, cursor_x);
            try rc.showCursor();
        }
    }
    fn syncDrmOutput(self: *Loop, force: bool) bool {
        if (!force) {
            if (self.drm_sync_ticks > 0) {
                self.drm_sync_ticks -= 1;
                return false;
            }
        }

        // redrawIfResized() runs every 100 ms while idle. Four skipped ticks
        // means one DRM/VC synchronization attempt roughly every 500 ms.
        self.drm_sync_ticks = 4;

        const result = console.syncTerminalToOutput(
            self.term.tty.?,
            self.drm_output,
        ) catch |err| {
            if (!self.drm_error_logged) {
                std.log.warn(
                    "failed to synchronize virtual-console geometry: {s}",
                    .{@errorName(err)},
                );
                self.drm_error_logged = true;
            }
            return false;
        };

        switch (result) {
            .not_ready => return false,
            .ambiguous => {
                if (!self.drm_ambiguity_logged) {
                    std.log.warn(
                        "multiple connected DRM outputs; pass --output <connector> to select one",
                        .{},
                    );
                    self.drm_ambiguity_logged = true;
                }
                return false;
            },
            .unchanged => return false,
            .resized => {
                self.drm_error_logged = false;
                std.log.info(
                    "synchronized virtual-console geometry with DRM output",
                    .{},
                );
                return true;
            },
        }
    }
    fn redrawIfResized(self: *Loop) !void {
        const old_width = self.term.width;
        const old_height = self.term.height;

        const drm_resized = self.syncDrmOutput(false);

        try self.term.fetchSize();

        if (!drm_resized and
            self.term.width == old_width and self.term.height == old_height)
        {
            return;
        }

        self.context = try self.term.getRenderContext();
        defer self.context.done() catch {};

        try self.renderHome();

        if (self.view == .power) {
            try self.renderPower();
        }
    }
    fn renderPower(self: *Loop) !void {
        const rc = &self.context;
        try rc.hideCursor();

        const btn_height = 3;
        const width = 24;
        const height = btn_height * 3 + 2;

        const hpad = (self.term.width - width) / 2;
        const vpad = (self.term.height - height) / 2;

        try drawBox(rc, .{
            .width = width,
            .height = height,
            .left = hpad,
            .top = vpad,
        });
        try drawText(rc, "reboot", .{
            .hidden = false,
            .selected = self.power == .reboot,
            .halign = .center,
            .valign = .center,
        }, .{
            .width = width - 2,
            .height = 3,
            .left = hpad + 1,
            .top = vpad + 1,
        });
        try drawText(rc, "reboot to firmware", .{
            .hidden = false,
            .selected = self.power == .firmware,
            .halign = .center,
            .valign = .center,
        }, .{
            .width = width - 2,
            .height = 3,
            .left = hpad + 1,
            .top = vpad + 4,
        });
        try drawText(rc, "shut down", .{
            .hidden = false,
            .selected = self.power == .shutdown,
            .halign = .center,
            .valign = .center,
        }, .{
            .width = width - 2,
            .height = 3,
            .left = hpad + 1,
            .top = vpad + 7,
        });
    }

    fn renderBar(self: *Loop) !void {
        const rc = &self.context;
        try rc.hideCursor();
        try rc.moveCursorTo(self.term.height - 2, 0);
        var i: usize = 0;
        while (i < self.term.width) : (i += 1) {
            try rc.writeAllWrapping("\u{2500}");
        }
        const help = switch (self.view) {
            .home => switch (self.field) {
                .username => "tab: switch, enter: password, esc: power",
                .password => "tab: switch, enter: login, esc: power",
            },
            .power => "up/down/tab: select, enter: commit, esc: back",
        };
        try rc.moveCursorTo(self.term.height - 1, 1);
        var rpw = rc.restrictedPaddingWriter(self.term.width - 2);
        const writer = rpw.writer();

        try writer.writeAll(help);
        try rpw.pad();
    }

    fn renderSplash(self: *Loop) !void {
        const rc = &self.context;
        try rc.clear();
        try rc.hideCursor();
        const splash_height = mem.count(u8, splash, "\n") + 1;
        const splash_width = mem.indexOfScalar(u8, splash, '\n').?;

        const vpad = (self.term.height - splash_height) / 2;
        const hpad = (self.term.width - splash_width) / 2;

        var lines = mem.split(u8, splash, "\n");
        var i: usize = 0;
        while (lines.next()) |line| : (i += 1) {
            try rc.moveCursorTo(vpad + i, hpad);
            try rc.writeAllWrapping(line);
        }
    }
};

const ParsedKey = struct {
    key: ?Loop.Key,
    len: usize,
};

fn parseKey(bytes: []const u8, flush_escape: bool) ?ParsedKey {
    if (bytes.len == 0) return null;

    if (bytes[0] == '\x1b') {
        if (bytes.len == 1) {
            return if (flush_escape) .{ .key = .escape, .len = 1 } else null;
        }
        if (bytes[1] != '[' and bytes[1] != 'O') {
            return .{ .key = .escape, .len = 1 };
        }
        if (bytes.len < 3) {
            return if (flush_escape) .{ .key = .escape, .len = 1 } else null;
        }

        const key: ?Loop.Key = switch (bytes[2]) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'Z' => if (bytes[1] == '[') .back_tab else null,
            else => null,
        };
        if (key != null or ascii.isAlphabetic(bytes[2])) {
            return .{ .key = key, .len = 3 };
        }

        for (bytes[2..], 2..) |byte, index| {
            if (ascii.isAlphabetic(byte) or byte == '~') {
                return .{ .key = null, .len = index + 1 };
            }
        }
        return if (flush_escape) .{ .key = .escape, .len = 1 } else null;
    }

    return .{
        .key = switch (bytes[0]) {
            '\x01' => .select_all,
            '\t' => .tab,
            '\n', '\r' => .enter,
            8, 127 => .backspace,
            else => if (ascii.isPrint(bytes[0])) .{ .character = bytes[0] } else null,
        },
        .len = 1,
    };
}

const Box = struct {
    width: usize,
    height: usize,
    left: usize,
    top: usize,
};

fn drawBox(rc: *spoon.Term.RenderContext, box: Box) !void {
    {
        try rc.moveCursorTo(box.top, box.left);
        var rpw = rc.restrictedPaddingWriter(box.width);
        const writer = rpw.writer();

        try writer.writeAll("\u{250c}");
        while (rpw.len_left > 1) try writer.writeAll("\u{2500}");
        try writer.writeAll("\u{2510}");

        try rpw.finish();
    }
    var row: usize = 1;
    while (row < box.height - 1) : (row += 1) {
        try rc.moveCursorTo(box.top + row, box.left);
        try rc.writeAllWrapping("\u{2502}");

        try rc.moveCursorTo(box.top + row, box.left + box.width - 1);
        try rc.writeAllWrapping("\u{2502}");
    }

    {
        try rc.moveCursorTo(box.top + box.height - 1, box.left);
        var rpw = rc.restrictedPaddingWriter(box.width);
        const writer = rpw.writer();
        try writer.writeAll("\u{2514}");
        while (rpw.len_left > 1) try writer.writeAll("\u{2500}");
        try writer.writeAll("\u{2518}");

        try rpw.finish();
    }
}

const TextOptions = struct {
    hidden: bool,
    selected: bool,
    halign: enum { left, center, right },
    valign: enum { top, center, bottom },
};
fn drawText(rc: *spoon.Term.RenderContext, text: []const u8, options: TextOptions, box: Box) !void {
    const tail_len = @min(text.len, box.width - 1);
    const tail = text[text.len - tail_len ..];

    const hpad = switch (options.halign) {
        .left => 0,
        .center => (box.width - tail.len) / 2,
        .right => box.width - tail.len,
    };
    const vpad = switch (options.valign) {
        .top => 0,
        .center => box.height / 2,
        .bottom => box.height - 1,
    };
    try rc.setAttribute(.{ .reverse = options.selected });

    var line: usize = 0;
    while (line < box.height) : (line += 1) {
        if (line == vpad) continue;
        try rc.moveCursorTo(box.top + line, box.left);
        var rpw = rc.restrictedPaddingWriter(box.width);
        try rpw.pad();
    }

    try rc.moveCursorTo(box.top + vpad, box.left);
    var rpw = rc.restrictedPaddingWriter(box.width);
    const writer = rpw.writer();
    try writer.writeByteNTimes(' ', hpad);
    for (tail) |char| {
        const codepoint: []const u8 = if (options.hidden) "\u{2022}" else &.{char};
        try writer.writeAll(codepoint);
    }
    try rpw.pad();
    try rc.setAttribute(.{ .reverse = false });
}

const FieldOptions = struct {
    label: []const u8,
    hidden: bool,
    cursor: usize,
    selected: bool,
};
fn drawField(rc: *spoon.Term.RenderContext, text: []const u8, options: FieldOptions, box: Box) !void {
    try rc.moveCursorTo(box.top, box.left + 1);
    try rc.writeAllWrapping(options.label);

    try drawBox(rc, .{
        .width = box.width,
        .height = box.height - 1,
        .left = box.left,
        .top = box.top + 1,
    });
    try drawEditableText(rc, text, options, .{
        .width = box.width - 4,
        .height = box.height - 3,
        .left = box.left + 2,
        .top = box.top + 2,
    });
}

fn drawEditableText(rc: *spoon.Term.RenderContext, text: []const u8, options: FieldOptions, box: Box) !void {
    const capacity = box.width - 1;
    const start = textViewportStart(text.len, options.cursor, capacity);
    const end = @min(text.len, start + capacity);

    try rc.moveCursorTo(box.top, box.left);
    var rpw = rc.restrictedPaddingWriter(box.width);
    const writer = rpw.writer();
    try rc.setAttribute(.{ .reverse = options.selected });
    for (text[start..end]) |char| {
        const codepoint: []const u8 = if (options.hidden) "\u{2022}" else &.{char};
        try writer.writeAll(codepoint);
    }
    try rc.setAttribute(.{ .reverse = false });
    try rpw.pad();
}

fn textViewportStart(text_len: usize, cursor: usize, capacity: usize) usize {
    const end = @min(text_len, @max(capacity, cursor));
    return end -| capacity;
}

test "form edits text and retains field cursors" {
    var loop: Loop = .{ .term = undefined };

    for ("iajkdq") |char| _ = loop.handleKey(.{ .character = char });
    try std.testing.expectEqualStrings("iajkdq", loop.username.constSlice());
    try std.testing.expectEqual(@as(usize, 6), loop.username_cursor);

    _ = loop.handleKey(.left);
    _ = loop.handleKey(.up);
    try std.testing.expectEqual(@as(usize, 0), loop.username_cursor);
    _ = loop.handleKey(.right);
    _ = loop.handleKey(.down);
    try std.testing.expectEqual(@as(usize, 6), loop.username_cursor);

    _ = loop.handleKey(.tab);
    try std.testing.expectEqual(.password, loop.field);
    _ = loop.handleKey(.{ .character = 'x' });
    _ = loop.handleKey(.back_tab);
    try std.testing.expectEqual(.username, loop.field);
    try std.testing.expectEqual(@as(usize, 6), loop.username_cursor);
    _ = loop.handleKey(.tab);
    try std.testing.expectEqual(@as(usize, 1), loop.password_cursor);
}

test "select all replaces, clears, and moves to either edge" {
    var loop: Loop = .{ .term = undefined };
    try loop.username.appendSlice("hello");
    loop.username_cursor = loop.username.len;

    _ = loop.handleKey(.select_all);
    _ = loop.handleKey(.left);
    try std.testing.expect(!loop.select_all);
    try std.testing.expectEqual(@as(usize, 0), loop.username_cursor);
    try std.testing.expectEqualStrings("hello", loop.username.constSlice());

    _ = loop.handleKey(.select_all);
    _ = loop.handleKey(.right);
    try std.testing.expectEqual(loop.username.len, loop.username_cursor);
    try std.testing.expectEqualStrings("hello", loop.username.constSlice());

    _ = loop.handleKey(.select_all);
    _ = loop.handleKey(.up);
    try std.testing.expectEqual(@as(usize, 0), loop.username_cursor);
    _ = loop.handleKey(.select_all);
    _ = loop.handleKey(.down);
    try std.testing.expectEqual(loop.username.len, loop.username_cursor);

    _ = loop.handleKey(.select_all);
    _ = loop.handleKey(.{ .character = 'x' });
    try std.testing.expectEqualStrings("x", loop.username.constSlice());
    try std.testing.expectEqual(@as(usize, 1), loop.username_cursor);

    _ = loop.handleKey(.select_all);
    _ = loop.handleKey(.backspace);
    try std.testing.expectEqualStrings("", loop.username.constSlice());
    try std.testing.expectEqual(@as(usize, 0), loop.username_cursor);
}

test "enter submits from password and power menu navigates all actions" {
    var loop: Loop = .{ .term = undefined };
    try loop.username.appendSlice("user");
    try loop.password.appendSlice("secret");

    try std.testing.expect(loop.handleKey(.enter) == null);
    try std.testing.expectEqual(.password, loop.field);

    const login = loop.handleKey(.enter).?;
    switch (login) {
        .login => |fields| {
            try std.testing.expectEqualStrings("user", fields.username);
            try std.testing.expectEqualStrings("secret", fields.password);
        },
        else => return error.UnexpectedAction,
    }

    _ = loop.handleKey(.escape);
    try std.testing.expectEqual(.power, loop.view);
    try std.testing.expectEqual(.reboot, loop.power);
    _ = loop.handleKey(.down);
    try std.testing.expectEqual(.firmware, loop.power);
    const power = loop.handleKey(.enter).?;
    switch (power) {
        .power => |power_action| try std.testing.expectEqual(.firmware, power_action),
        else => return error.UnexpectedAction,
    }

    _ = loop.handleKey(.down);
    try std.testing.expectEqual(.shutdown, loop.power);
    _ = loop.handleKey(.up);
    try std.testing.expectEqual(.firmware, loop.power);
    _ = loop.handleKey(.tab);
    try std.testing.expectEqual(.shutdown, loop.power);
    _ = loop.handleKey(.tab);
    try std.testing.expectEqual(.reboot, loop.power);
    _ = loop.handleKey(.back_tab);
    try std.testing.expectEqual(.shutdown, loop.power);

    _ = loop.handleKey(.escape);
    try std.testing.expectEqual(.home, loop.view);
}

test "full field does not move cursor after failed insertion" {
    var loop: Loop = .{ .term = undefined };
    while (loop.username.len < loop.username.capacity()) try loop.username.append('x');
    loop.username_cursor = loop.username.len;

    _ = loop.handleKey(.{ .character = 'y' });
    try std.testing.expectEqual(loop.username.len, loop.username_cursor);
}

test "raw input maps form navigation and select all" {
    const cases = .{
        .{ "\x1b[D", Loop.Key.left },
        .{ "\x1b[C", Loop.Key.right },
        .{ "\x1b[A", Loop.Key.up },
        .{ "\x1b[B", Loop.Key.down },
        .{ "\x1b[Z", Loop.Key.back_tab },
        .{ "\t", Loop.Key.tab },
        .{ "\x01", Loop.Key.select_all },
    };

    inline for (cases) |case| {
        const parsed = parseKey(case[0], false).?;
        const actual = parsed.key.?;
        try std.testing.expect(std.meta.eql(case[1], actual));
        try std.testing.expectEqual(case[0].len, parsed.len);
    }
}

test "raw input waits for complete escape sequences" {
    try std.testing.expect(parseKey("\x1b", false) == null);
    try std.testing.expect(parseKey("\x1b[", false) == null);

    const escape = parseKey("\x1b", true).?;
    try std.testing.expect(std.meta.eql(Loop.Key.escape, escape.key.?));
    try std.testing.expectEqual(@as(usize, 1), escape.len);
}

test "text viewport keeps the cursor visible" {
    try std.testing.expectEqual(@as(usize, 0), textViewportStart(20, 0, 10));
    try std.testing.expectEqual(@as(usize, 0), textViewportStart(20, 10, 10));
    try std.testing.expectEqual(@as(usize, 1), textViewportStart(20, 11, 10));
    try std.testing.expectEqual(@as(usize, 10), textViewportStart(20, 20, 10));
}
