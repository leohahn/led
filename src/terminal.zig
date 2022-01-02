const std = @import("std");
const assert = std.debug.assert;

pub const Key = enum(i16) {
    const Self = @This();

    a = @as(i16, 'a'),
    b = @as(i16, 'b'),
    c = @as(i16, 'c'),
    d = @as(i16, 'd'),
    e = @as(i16, 'e'),
    f = @as(i16, 'f'),
    g = @as(i16, 'g'),
    h = @as(i16, 'h'),
    i = @as(i16, 'i'),
    j = @as(i16, 'j'),
    k = @as(i16, 'k'),
    l = @as(i16, 'l'),
    m = @as(i16, 'm'),
    n = @as(i16, 'n'),
    o = @as(i16, 'o'),
    p = @as(i16, 'p'),
    q = @as(i16, 'q'),
    r = @as(i16, 'r'),
    s = @as(i16, 's'),
    t = @as(i16, 't'),
    u = @as(i16, 'u'),
    v = @as(i16, 'v'),
    x = @as(i16, 'x'),
    w = @as(i16, 'w'),
    y = @as(i16, 'y'),
    z = @as(i16, 'z'),

    A = @as(i16, 'A'),
    B = @as(i16, 'B'),
    C = @as(i16, 'C'),
    D = @as(i16, 'D'),
    E = @as(i16, 'E'),
    F = @as(i16, 'F'),
    G = @as(i16, 'G'),
    H = @as(i16, 'H'),
    I = @as(i16, 'I'),
    J = @as(i16, 'J'),
    K = @as(i16, 'K'),
    L = @as(i16, 'L'),
    M = @as(i16, 'M'),
    N = @as(i16, 'N'),
    O = @as(i16, 'O'),
    P = @as(i16, 'P'),
    Q = @as(i16, 'Q'),
    R = @as(i16, 'R'),
    S = @as(i16, 'S'),
    T = @as(i16, 'T'),
    U = @as(i16, 'U'),
    V = @as(i16, 'V'),
    X = @as(i16, 'X'),
    W = @as(i16, 'W'),
    Y = @as(i16, 'Y'),
    Z = @as(i16, 'Z'),

    num_0 = @as(i16, '0'),
    num_1 = @as(i16, '1'),
    num_2 = @as(i16, '2'),
    num_3 = @as(i16, '3'),
    num_4 = @as(i16, '4'),
    num_5 = @as(i16, '5'),
    num_6 = @as(i16, '6'),
    num_7 = @as(i16, '7'),
    num_8 = @as(i16, '8'),
    num_9 = @as(i16, '9'),

    semicolon = ';',
    colon = ':',
    greater = '>',
    smaller = '<',
    equal = '=',

    hash = '#',
    at = '@',
    bang = '!',
    dollar = '$',
    percent = '%',
    caret = '^',
    ampersand = '&',
    asterisk = '*',
    open_parenthesis = '(',
    close_parenthesis = ')',
    minus = '-',
    plus = '+',
    open_bracket = '[',
    close_bracket = ']',
    open_brace = '{',
    close_brace = '}',
    underline = '_',
    tilde = '~',
    quote = '\'',
    double_quote = '"',
    question_mark = '?',
    slash = '/',
    backslash = '\\',
    space = ' ',

    up = 256, 
    down = 257, 
    left = 258, 
    right = 259, 

    esc = 27,

    unknown = 260,

    fn isDigit(self: Self) bool {
        return switch (self) {
            .num_0, .num_1, .num_2, .num_3, .num_4, .num_5, .num_6, .num_7, .num_8, .num_9 => true,
            else => false,
        };
    }
};

pub fn readInputEvent() !?Key {
    var stdin = std.io.getStdIn();
    var buffer = [1]u8{0};
    const nread = try stdin.read(&buffer);

    if (nread == 0) {
        return null;
    }

    if (buffer[0] == '\x1b') {
        return .unknown;
    }

    if (buffer[0] >= 32 and buffer[0] <= 126) {
        return @intToEnum(Key, buffer[0]);
    }

    return .unknown;
}

pub fn ctrlKey(key: u8) u8 {
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
    const Self = @This();

    line: i32,
    col: i32,
};

fn readKey(key: Key) !void {
    const got_key = try readInputEvent();
    if (got_key == null) {
        return error.NoResponseFromTerminal;
    }
    if (got_key != key) {
        return error.GotDifferentChar;
    }
}

fn readIntUntil(int_type: anytype, until: Key) !i32 {
    var int_buffer = [1]u8{0} ** 32;
    var bytes_read: usize = 0;

    while (true) {
        var key = try readInputEvent();
        if (key == null) {
            break;
        }

        if (!key.?.isDigit()) {
            if (until != key.?) {
                return error.UnexpectedEnding;
            }
            break;
        }

        int_buffer[bytes_read] = @intCast(u8, @enumToInt(key.?));
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
    try readKey(Key.esc);
    try readKey(Key.open_brace);
    const line = try readIntUntil(i32, Key.semicolon);
    const col = try readIntUntil(i32, Key.R);

    return Position{
        .line = line,
        .col = col,
    };
}

pub fn getWindowSize() !WindowSize {
    const stdout = std.io.getStdOut();

    var ws: std.c.winsize = undefined;

    if (std.c.ioctl(stdout.handle, std.c.T.IOCGWINSZ, &ws) == -1 or ws.ws_col == 0) {
        _ = try stdout.write("\x1b[999C\x1b[999B");
        const cursor_pos = try getCursorPosition(); 
        return WindowSize{
            .lines = cursor_pos.line,
            .cols = cursor_pos.col,
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

pub fn moveCursorToPosition(writer: anytype, position: Position) !void {
    try writer.print(
        "\x1b[{d};{d}H",
        .{ position.line + 1, position.col + 1 },
    );
}

pub const RawMode = struct {
    const Self = @This();

    original_terminfo: std.os.termios,

    pub fn enable() !Self {
        const os = std.os;
        const handle = std.io.getStdIn().handle;

        //
        // reference:
        // https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html
        //
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

pub fn draw_contents(string: []const u8) void {
    std.log.info("DRAW CONTENTS:\n{s}\n", .{string});
}
