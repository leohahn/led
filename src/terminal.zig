const std = @import("std");
const assert = std.debug.assert;

pub const KeyEvent = union(enum) {
    char: u8,
    unknown,

    up,
    down,
    left,
    right,

    del,
    page_up,
    page_down,
    home,
    end,

    esc,
    backspace,

    const Self = @This();

    fn isDigit(self: Self) bool {
        switch (self) {
            .char => |c| {
                return c >= '0' and c <= '9';
            },
            else => return false,
        }
    }
};

pub fn readInputEvent() !?KeyEvent {
    var stdin = std.io.getStdIn();
    var buffer = [1]u8{0};
    const nread = try stdin.read(&buffer);

    if (nread == 0) {
        return null;
    }

    if (buffer[0] == '\x1b') {
        var escape_seq = [1]u8{0} ** 3;

        if ((try stdin.read(escape_seq[0..1])) != 1) return .unknown;
        if ((try stdin.read(escape_seq[1..2])) != 1) return .unknown;

        if (escape_seq[0] == '[') {
            if (escape_seq[1] >= '0' and escape_seq[1] <= '9') {
                if ((try stdin.read(escape_seq[2..3])) != 1) return .unknown;
                if (escape_seq[2] == '~') {
                    switch (escape_seq[1]) {
                        '1' => return .home,
                        '3' => return .del,
                        '4' => return .end,
                        '5' => return .page_up,
                        '6' => return .page_down,
                        '7' => return .home,
                        '8' => return .end,
                        else => return .unknown,
                    }
                }
            } else {
                switch (escape_seq[1]) {
                    'A' => return .up,
                    'B' => return .down,
                    'C' => return .right,
                    'D' => return .left,
                    'H' => return .home,
                    'F' => return .end,
                    else => return .unknown,
                }
            }
        } else if (escape_seq[0] == '0') {
            switch (escape_seq[1]) {
                'H' => return .home,
                'F' => return .end,
                else => return .unknown,
            }
        }

        return .unknown;
    }

    if (buffer[0] >= 32 and buffer[0] <= 126) {
        return KeyEvent{
            .char = buffer[0],
        };
    }

    if (buffer[0] == 8) {
        return .backspace;
    }

    if (buffer[0] == 127) {
        return .backspace;
    }

    return .unknown;
}

pub fn ctrlKeyEvent(key: u8) u8 {
    return key & 0x1f;
}

pub fn refreshScreen(writer: anytype) !void {
    _ = try writer.write("\x1b[2J");
}

pub fn useAlternateScreenBuffer(writer: anytype) !void {
    _ = try writer.write("\x1b[?1049h");
}

pub fn leaveAlternateScreenBuffer() !void {
    const stdout = std.io.getStdOut();
    _ = try stdout.write("\x1b[?1049l");
}

const WindowSize = struct {
    lines: i32,
    cols: i32,
};

pub const Position = struct {
    line: Line,
    col: Col,

    const Self = @This();
    pub fn start() Self {
        return .{
            .line = .{ .val = 0 },
            .col = .{ .val = 0 },
        };
    }
};

fn readKeyEvent(key: KeyEvent) !void {
    const got_key = (try readInputEvent()) orelse {
        return error.NoResponseFromTerminal;
    };
    if (!std.meta.eql(key, got_key)) {
        return error.GotDifferentChar;
    }
}

fn readIntUntil(int_type: anytype, until: KeyEvent) !i32 {
    var int_buffer = [1]u8{0} ** 32;
    var bytes_read: usize = 0;

    while (true) {
        var key = (try readInputEvent()) orelse {
            break;
        };

        if (!key.isDigit()) {
            if (!std.meta.eql(until, key)) {
                return error.UnexpectedEnding;
            }
            break;
        }

        int_buffer[bytes_read] = @intCast(u8, @enumToInt(key));
        bytes_read += 1;

        assert(bytes_read <= 32);
    }

    if (bytes_read == 0) {
        return error.IntExpected;
    }

    const parsed_int = try std.fmt.parseInt(int_type, int_buffer[0..bytes_read], 10);
    return parsed_int;
}

pub fn getCursorPosition() !Position {
    const stdout = std.io.getStdOut();

    // request cursor position
    _ = try stdout.write("\x1b[6n");

    // read cursor position.
    try readKeyEvent(KeyEvent.esc);
    try readKeyEvent(.{ .char = '[' });
    const line = try readIntUntil(i32, .{ .char = ';' });
    const col = try readIntUntil(i32, .{ .char = 'R' });

    return Position{
        .line = .{ .val = line - 1 },
        .col = .{ .val = col - 1 },
    };
}

pub fn getWindowSize() !WindowSize {
    const stdout = std.io.getStdOut();

    var ws: std.c.winsize = undefined;

    if (std.c.ioctl(stdout.handle, std.c.T.IOCGWINSZ, &ws) == -1 or ws.ws_col == 0) {
        _ = try stdout.write("\x1b[999C\x1b[999B");
        const cursor_pos = try getCursorPosition();
        return WindowSize{
            .lines = cursor_pos.line.val + 1,
            .cols = cursor_pos.col.val + 1,
        };
    }

    return WindowSize{
        .lines = ws.ws_row,
        .cols = ws.ws_col,
    };
}

pub fn hideCursor(writer: anytype) !void {
    _ = try writer.write("\x1b[?25l");
}

pub fn showCursor(writer: anytype) !void {
    _ = try writer.write("\x1b[?25h");
}

pub const Line = struct { val: i32 };
pub const Col = struct { val: i32 };

pub fn moveCursorToPosition(writer: anytype, position: Position) !void {
    try writer.print(
        "\x1b[{d};{d}H",
        .{ position.line.val + 1, position.col.val + 1 },
    );
}

pub const RawMode = struct {
    const Self = @This();

    original_terminfo: std.os.termios,

    pub fn enable() !Self {
        const os = std.os;
        const handle = std.io.getStdIn().handle;

        //==================================================================
        // reference:
        // https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html
        //==================================================================
        const original_terminfo = try os.tcgetattr(handle);

        var new_terminfo = original_terminfo;

        new_terminfo.iflag &= ~(os.system.BRKINT |
            os.system.ICRNL |
            os.system.INPCK |
            os.system.ISTRIP |
            os.system.IXON);
        new_terminfo.oflag &= ~(os.system.OPOST);
        new_terminfo.cflag |= (os.system.CS8);
        new_terminfo.lflag &= ~(os.system.ECHO | os.system.ICANON | os.system.ISIG | os.system.IEXTEN);
        new_terminfo.cc[os.system.V.MIN] = 0;
        new_terminfo.cc[os.system.V.TIME] = 1;

        try std.os.tcsetattr(handle, .FLUSH, new_terminfo);

        return Self{
            .original_terminfo = original_terminfo,
        };
    }

    pub fn disable(self: Self) !void {
        try std.os.tcsetattr(std.io.getStdIn().handle, .FLUSH, self.original_terminfo);
    }
};
