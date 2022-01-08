const std = @import("std");
const assert = std.debug.assert;

pub const Key = enum(i32) {
    const Self = @This();

    unknown = -1,

    a = 'a',
    b = 'b',
    c = 'c',
    d = 'd',
    e = 'e',
    f = 'f',
    g = 'g',
    h = 'h',
    i = 'i',
    j = 'j',
    k = 'k',
    l = 'l',
    m = 'm',
    n = 'n',
    o = 'o',
    p = 'p',
    q = 'q',
    r = 'r',
    s = 's',
    t = 't',
    u = 'u',
    v = 'v',
    x = 'x',
    w = 'w',
    y = 'y',
    z = 'z',

    A = 'A',
    B = 'B',
    C = 'C',
    D = 'D',
    E = 'E',
    F = 'F',
    G = 'G',
    H = 'H',
    I = 'I',
    J = 'J',
    K = 'K',
    L = 'L',
    M = 'M',
    N = 'N',
    O = 'O',
    P = 'P',
    Q = 'Q',
    R = 'R',
    S = 'S',
    T = 'T',
    U = 'U',
    V = 'V',
    X = 'X',
    W = 'W',
    Y = 'Y',
    Z = 'Z',

    num_0 = '0',
    num_1 = '1',
    num_2 = '2',
    num_3 = '3',
    num_4 = '4',
    num_5 = '5',
    num_6 = '6',
    num_7 = '7',
    num_8 = '8',
    num_9 = '9',

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

    up = 1000,
    down = 1001,
    left = 1002,
    right = 1003,

    del = 1004,
    page_up = 1005,
    page_down = 1006,
    home = 1007,
    end = 1008,

    esc = 27,

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
