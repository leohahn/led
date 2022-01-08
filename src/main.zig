const std = @import("std");
const piece_table = @import("./piece_table.zig");
const terminal = @import("./terminal.zig");
const assert = std.debug.assert;

const VERSION = "0.1.0";

const Allocator = std.mem.Allocator;
const PieceTable = piece_table.PieceTable;

const CursorPosition = struct {
    const Self = @This();

    line: i32,
    col: i32,

    fn down(self: Self, screen: *const Screen) Self {
        return .{
            .line = std.math.min(self.line + 1, screen.lines - 1),
            .col = self.col,
        };
    }

    fn up(self: Self) Self {
        return .{
            .line = std.math.max(self.line - 1, 0),
            .col = self.col,
        };
    }

    fn left(self: Self) Self {
        return .{
            .line = self.line,
            .col = std.math.max(self.col - 1, 1),
        };
    }

    fn right(self: Self, screen: *const Screen) Self {
        return .{
            .line = self.line,
            .col = std.math.min(self.col + 1, screen.cols - 1),
        };
    }
};

const Screen = struct {
    lines: i32,
    cols: i32,
    cursor_position: CursorPosition,
    raw_mode: terminal.RawMode,

    const Self = @This();

    fn init(writer: anytype) !Self {
        const raw_mode = try terminal.RawMode.enable();
        try terminal.useAlternateScreenBuffer(writer);
        const size = try terminal.getWindowSize();

        return Self{
            .lines = size.lines,
            .cols = size.cols,
            .raw_mode = raw_mode,
            .cursor_position = CursorPosition{
                .line = 0,
                .col = 1,
            },
        };
    }

    fn deinit(self: *const Self) !void {
        try terminal.leaveAlternateScreenBuffer();
        try self.raw_mode.disable();
    }
};

fn processInput(screen: *Screen) !bool {
    const ev = try terminal.readInputEvent();
    if (ev == null) {
        std.log.info("timeout", .{});
        return false;
    }

    switch (ev.?) {
        .q => {
            return true;
        },
        .j, .down => {
            screen.cursor_position = screen.cursor_position.down(screen);
        },
        .k, .up => {
            screen.cursor_position = screen.cursor_position.up();
        },
        .h, .left => {
            screen.cursor_position = screen.cursor_position.left();
        },
        .l, .right => {
            screen.cursor_position = screen.cursor_position.right(screen);
        },
        .page_up => {
            var times = screen.lines;
            while (times > 0) : (times -= 1) {
                screen.cursor_position = screen.cursor_position.up();
            }
        },
        .page_down => {
            var times = screen.lines;
            while (times > 0) : (times -= 1) {
                screen.cursor_position = screen.cursor_position.down(screen);
            }
        },
        .home => {
            var times = screen.cols;
            while (times > 0) : (times -= 1) {
                screen.cursor_position = screen.cursor_position.left();
            }
        },
        .end => {
            var times = screen.cols;
            while (times > 0) : (times -= 1) {
                screen.cursor_position = screen.cursor_position.right(screen);
            }
        },
        else => {},
    }

    return false;
}

fn findCharInString(slice: []const u8, char: u8) ?usize {
    for (slice) |c, i| {
        if (char == c) {
            return i;
        }
    }
    return null;
}

fn drawBuffer(writer: anytype, screen: Screen, buffer: Buffer) !void {
    try terminal.moveCursorToPosition(writer, .{ .line = 0, .col = 0 });
    _ = screen;
    _ = buffer;

    var line: i32 = 0;
    var remaining_string = buffer.contents;

    while (line < screen.lines) : (line += 1) {
        if (remaining_string.len == 0) {
            _ = try writer.write("~\r\n");
            continue;
        }

        const index = findCharInString(remaining_string, '\n');

        _ = try writer.write(" ");

        if (index == null) {
            _ = try writer.write(remaining_string);
            remaining_string = "";
            _ = try writer.write("\r\n");
            continue;
        }

        _ = try writer.write(remaining_string[0..index.?]);
        _ = try writer.write("\r\n");
        remaining_string = remaining_string[index.? + 1..remaining_string.len];
    }

    try terminal.moveCursorToPosition(writer, .{
        .line = screen.cursor_position.line,
        .col = screen.cursor_position.col,
    });
}

const Args = struct {
    const Self = @This();

    allocator: Allocator,
    file_path: ?[]const u8,

    fn init(allocator: Allocator) !Self {
        var args_it = std.process.args();
        var file_path: ?[]const u8 = null;

        // Skip first parameter since it is always the program name.
        _ = args_it.skip();

        while (args_it.next(allocator)) |arg_err| {
            const arg = try arg_err; 
            file_path = arg;
            break;
        }

        return Args{
            .allocator = allocator,
            .file_path = file_path,
        };
    }

    fn deinit(self: *Self) void {
        if (self.file_path != null) self.allocator.free(self.file_path.?);
    }
};

fn createPaddingString(allocator: Allocator, padding_len: i32) ![]const u8 {
    assert(padding_len > 0);
    const string = try allocator.alloc(u8, @intCast(usize, padding_len));
    std.mem.set(u8, string, ' ');
    return string;
}

const Buffer = struct {
    allocator: Allocator,
    piece_table: PieceTable,
    contents: []const u8,
    read_only: bool,

    const Self = @This();

    fn welcome(allocator: Allocator, screen: Screen) !Self {
        const max_col_len = 17;
        const padding_len = @divFloor(screen.cols - max_col_len, 2);

        const padding = try createPaddingString(allocator, padding_len);
        defer allocator.free(padding);

        var buf = try allocator.alloc(u8, 2048);
        defer allocator.free(buf);

        const message = try std.fmt.bufPrint(
            buf,
            \\
            \\
            \\{s} _             _ 
            \\{s}| |    ___  __| |
            \\{s}| |   / _ \/ _` |
            \\{s}| |__|  __/ (_| |
            \\{s}|_____\___|\__,_|
            \\
            \\{s}  version {s}
        , .{padding, padding, padding, padding, padding, padding, VERSION});
        
        var self = try initFromString(allocator, message);
        return self;
    }

    fn initFromString(allocator: Allocator, string: []const u8) !Self {
        var table = try PieceTable.initFromString(allocator, string);
        var contents = try table.toString(allocator);

        return Self{
            .allocator = allocator, 
            .piece_table = table,
            .contents = contents,
            .read_only = false,
        };
    }

    fn initFromFile(allocator: Allocator, file: std.fs.File) !Self {
        var table = try PieceTable.initFromFile(allocator, file);
        var contents = try table.toString(allocator);

        return Self{
            .allocator = allocator, 
            .piece_table = table,
            .contents = contents,
            .read_only = false,
        };
    }

    fn deinit(self: *Self) void {
        self.allocator.free(self.contents);
        self.piece_table.deinit();
    }
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();

    var args = try Args.init(allocator);
    defer args.deinit();

    var cwd = std.fs.cwd();

    var frame = std.ArrayList(u8).init(allocator);
    defer frame.deinit();

    var screen = try Screen.init(frame.writer());
    defer screen.deinit() catch {};

    var buffer: Buffer = undefined;
    if (args.file_path != null) {
        var file = try cwd.openFile(args.file_path.?, .{ .read = true });
        buffer = try Buffer.initFromFile(allocator, file);
    } else {
        buffer = try Buffer.welcome(allocator, screen);
    }

    while (true) {
        try terminal.hideCursor(frame.writer());
        try terminal.refreshScreen(frame.writer());
        try drawBuffer(frame.writer(), screen, buffer);
        try terminal.showCursor(frame.writer());

        const stdout = std.io.getStdOut();
        _ = try stdout.write(frame.items);

        frame.clearRetainingCapacity();

        if (try processInput(&screen)) {
            break;
        }
    }
}
