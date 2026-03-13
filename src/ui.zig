const std = @import("std");
const ascii = std.ascii;
const debug = std.debug;
const mem = std.mem;
const os = std.os;
const time = std.time;

const spoon = @import("spoon");

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
    mode: enum { insert, select },
    view: enum { home, power },
    field: enum { username, password },
    power: enum { shutdown, reboot } = .shutdown,
    username: std.BoundedArray(u8, 1024) = .{},
    password: std.BoundedArray(u8, 1024) = .{},
    cursor: usize = 0,

    const Action = union(enum) {
        login: struct {
            username: []const u8,
            password: []const u8,
        },
        power: []const u8,
    };

    pub fn init(self: *Loop) !void {
        try self.term.init(.{});
        try self.term.uncook(.{
            .request_kitty_keyboard_protocol = false,
            .request_mouse_tracking = false,
        });
        try self.term.fetchSize();

        self.context = try self.term.getRenderContext();
        try self.context.clear();
        try self.context.done();

        time.sleep(100 * time.ns_per_ms);

        self.context = try self.term.getRenderContext();
        try self.renderHome();
        try self.context.done();
    }

    pub fn deinit(self: *Loop) void {
        self.term.deinit() catch unreachable;
    }

    pub fn reset(self: *Loop) !void {
        self.mode = .insert;
        self.view = .home;
        self.field = .username;
        self.username.len = 0;
        self.password.len = 0;
        self.cursor = 0;

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
            _ = try std.posix.poll(&fds, -1);
            const size = try self.term.readInput(&buffer);
            var inputs = spoon.inputParser(buffer[0..size]);

            self.context = try self.term.getRenderContext();
            defer self.context.done() catch {};

            while (inputs.next()) |input| {
                switch (self.view) {
                    .home => switch (self.mode) {
                        .insert => {
                            if (input.eqlDescription("escape")) {
                                self.mode = .select;
                                try self.renderBar();
                                try self.renderHome();
                            } else if (input.eqlDescription("enter")) {
                                switch (self.field) {
                                    .username => {
                                        self.field = .password;
                                        self.cursor = 0;
                                        try self.renderBar();
                                        try self.renderHome();
                                    },
                                    .password => {
                                        try self.renderSplash();
                                        return .{ .login = .{
                                            .username = self.username.constSlice(),
                                            .password = self.password.constSlice(),
                                        } };
                                    },
                                }
                            } else if (input.eqlDescription("backspace") and self.cursor > 0) {
                                switch (self.field) {
                                    .username => _ = self.username.orderedRemove(self.cursor - 1),
                                    .password => _ = self.password.orderedRemove(self.cursor - 1),
                                }
                                self.cursor -= 1;
                                try self.renderHome();
                            } else if (size == 1 and ascii.isPrint(buffer[0])) {
                                const char = buffer[0];
                                switch (self.field) {
                                    .username => self.username.insert(self.cursor, char) catch {},
                                    .password => self.password.insert(self.cursor, char) catch {},
                                }
                                self.cursor += 1;
                                try self.renderHome();
                            }
                        },
                        .select => {
                            if (input.eqlDescription("q")) {
                                self.view = .power;
                                self.power = .shutdown;
                                try self.renderBar();
                                try self.renderHome();
                                try self.renderPower();
                            } else if (input.eqlDescription("i")) {
                                self.mode = .insert;
                                self.cursor = 0;
                                try self.renderBar();
                                try self.renderHome();
                            } else if (input.eqlDescription("a") or input.eqlDescription("A")) {
                                self.mode = .insert;
                                self.cursor = switch (self.field) {
                                    .username => self.username.len,
                                    .password => self.password.len,
                                };
                                try self.renderBar();
                                try self.renderHome();
                            } else if (input.eqlDescription("j")) {
                                self.field = .password;
                                try self.renderHome();
                            } else if (input.eqlDescription("k")) {
                                self.field = .username;
                                try self.renderHome();
                            } else if (input.eqlDescription("d")) {
                                switch (self.field) {
                                    .username => self.username.len = 0,
                                    .password => self.password.len = 0,
                                }
                                try self.renderHome();
                            }
                        },
                    },
                    .power => {
                        debug.assert(self.mode == .select);

                        if (input.eqlDescription("escape")) {
                            self.view = .home;
                            try self.renderBar();
                            try self.renderHome();
                        } else if (input.eqlDescription("enter")) {
                            return .{ .power = switch (self.power) {
                                .shutdown => "poweroff",
                                .reboot => "reboot",
                            } };
                        } else if (input.eqlDescription("j")) {
                            self.power = .reboot;
                            try self.renderPower();
                        } else if (input.eqlDescription("k")) {
                            self.power = .shutdown;
                            try self.renderPower();
                        }
                    },
                }
            }
        }
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
            .selected = self.view == .home and self.mode == .select and self.field == .username,
        }, .{
            .width = title_width,
            .height = field_height,
            .left = hpad,
            .top = username_top,
        });
        try drawField(rc, password, .{
            .label = "password",
            .hidden = true,
            .selected = self.view == .home and self.mode == .select and self.field == .password,
        }, .{
            .width = title_width,
            .height = field_height,
            .left = hpad,
            .top = password_top,
        });

        try self.renderBar();

        if (self.view == .home and self.mode == .insert) {
            const cursor_y = switch (self.field) {
                .username => username_top + 1 + (field_height - 1) / 2,
                .password => password_top + 1 + (field_height - 1) / 2,
            };
            const cursor_x = hpad + 2 + @min(self.cursor, title_width - 5);
            try rc.moveCursorTo(cursor_y, cursor_x);
            try rc.showCursor();
        }
    }

    fn renderPower(self: *Loop) !void {
        const rc = &self.context;
        try rc.hideCursor();

        const btn_height = 3;
        const width = 16;
        const height = btn_height * 2 + 2;

        const hpad = (self.term.width - width) / 2;
        const vpad = (self.term.height - height) / 2;

        try drawBox(rc, .{
            .width = width,
            .height = height,
            .left = hpad,
            .top = vpad,
        });

        try drawText(rc, "shutdown", .{
            .hidden = false,
            .selected = self.power == .shutdown,
            .halign = .center,
            .valign = .center,
        }, .{
            .width = width - 2,
            .height = 3,
            .left = hpad + 1,
            .top = vpad + 1,
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
            .top = vpad + 4,
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

        const mode = switch (self.mode) {
            .insert => "INSERT",
            .select => "SELECT",
        };
        const help = switch (self.mode) {
            .insert => switch (self.field) {
                .username => "enter: password, esc: select mode",
                .password => "enter: login, esc: select mode",
            },
            .select => switch (self.view) {
                .home => "q: power, i: insert, a: append, d: delete, j: down, k: up",
                .power => "enter: commit, j: down, k: up",
            },
        };

        try rc.moveCursorTo(self.term.height - 1, 1);
        var rpw = rc.restrictedPaddingWriter(self.term.width - 2);
        const writer = rpw.writer();

        try writer.writeAll(mode);
        try writer.writeByteNTimes(' ', rpw.len_left - help.len);
        try writer.writeAll(help);
        try rpw.finish();
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

    try drawText(rc, text, .{
        .hidden = options.hidden,
        .selected = options.selected,
        .halign = .left,
        .valign = .center,
    }, .{
        .width = box.width - 4,
        .height = box.height - 3,
        .left = box.left + 2,
        .top = box.top + 2,
    });
}
