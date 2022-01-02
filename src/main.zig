const std = @import("std");
const piece_table = @import("./piece_table.zig");
const terminal = @import("./terminal.zig");

const VERSION = "0.1.0";

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
    const Self = @This();

    lines: i32,
    cols: i32,

    cursor_position: CursorPosition,

    raw_mode: terminal.RawMode,

    fn init(writer: anytype) !Self {
        const raw_mode = try terminal.RawMode.enable();
        try terminal.useAlternateScreenBuffer(writer);

        const size = try terminal.getWindowSize();

        return Self {
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
        _ = self;
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
        .j => {
            screen.cursor_position = screen.cursor_position.down(screen);
        },
        .k => {
            screen.cursor_position = screen.cursor_position.up();
        },
        .h => {
            screen.cursor_position = screen.cursor_position.left();
        },
        .l => {
            screen.cursor_position = screen.cursor_position.right(screen);
        },
        else => {},
    }

    return false;
}

fn drawBufferContents(writer: anytype, screen: Screen) !void {
    try terminal.moveCursorToPosition(writer, .{
        .line = 0,
        .col = 0,
    });

    var y: usize = 0;
    while (y < screen.lines) : (y += 1) {
        if (y == @divFloor(screen.lines, 3)) {
            var buf = [1]u8{0} ** 80;
            const welcome_message = try std.fmt.bufPrint(&buf, "Hed editor -- version {s}", .{VERSION});

            var padding: i32 = @divFloor(@intCast(i32, screen.cols) - @intCast(i32, welcome_message.len), 2);

            _ = try writer.write("~");
            padding -= 1;

            while (padding > 0) : (padding -= 1) {
                _ = try writer.write(" ");
            }
            _ = try writer.write(welcome_message);
        } else {
            _ = try writer.write("~");
        }

        if (y < screen.lines - 1) {
            _ = try writer.write("\r\n");
        }
    }

    try terminal.moveCursorToPosition(writer, .{
        .line = screen.cursor_position.line,
        .col = screen.cursor_position.col,
    });
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var cwd = std.fs.cwd();
    var file = try cwd.openFile("src/main.zig", .{ .read = true });

    var table = try PieceTable.initFromFile(gpa.allocator(), file);
    defer table.deinit();

    const table_contents = try table.toString(gpa.allocator());
    defer gpa.allocator().free(table_contents);

    var frame = std.ArrayList(u8).init(gpa.allocator());
    defer frame.deinit();

    var screen = try Screen.init(frame.writer());
    defer screen.deinit() catch {};

    while (true) {
        try terminal.hideCursor(frame.writer());
        try terminal.refreshScreen(frame.writer());
        try drawBufferContents(frame.writer(), screen);
        try terminal.showCursor(frame.writer());

        const stdout = std.io.getStdOut();
        _ = try stdout.write(frame.items);

        frame.clearRetainingCapacity();

        if (try processInput(&screen)) {
            break;
        }
    }
}
