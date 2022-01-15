const std = @import("std");
const PieceTable = @import("./piece_table.zig").PieceTable;
const editor_resources = @import("./editor_resources.zig");
const EditorResources = editor_resources.EditorResources;
const terminal = @import("./terminal.zig");
const log = @import("./log.zig");
const Buffer = @import("./buffer.zig").Buffer;
const assert = std.debug.assert;
const ref = @import("./ref.zig");
const Allocator = std.mem.Allocator;
const window = @import("./window.zig");
const Window = window.Window;

const VERSION = "0.1.0";

const Screen = struct {
    window: Window,
    raw_mode: terminal.RawMode,

    const Self = @This();

    fn init(writer: anytype) !Self {
        const raw_mode = try terminal.RawMode.enable();
        try terminal.useAlternateScreenBuffer(writer);
        const size = try terminal.getWindowSize();

        const buffer_line: window.Line = .{ .val = 0 };
        const buffer_col: window.Col = .{ .val = 5 };

        return Self{
            .raw_mode = raw_mode,
            .window = Window{
                .start_col = .{ .val = 0 },
                .start_line = .{ .val = 10 },
                .line_count = size.lines - 10,
                .col_count = size.cols,
                .properties = window.Properties{
                    .markers_col = .{ .val = 0 },
                    .line_number_col = .{ .val = 1 },
                    .buffer_col = buffer_col,
                    .buffer_line = buffer_line,
                },
            },
        };
    }

    fn deinit(self: *const Self) !void {
        try terminal.leaveAlternateScreenBuffer();
        try self.raw_mode.disable();
    }
};

fn cursorDown(buffer: *Buffer, table: *const PieceTable) void {
    const maybe_pos = table.clampPosition(buffer.cursor.line.val + 1, buffer.cursor.col.val);
    const pos = maybe_pos orelse return;

    buffer.cursor.line = .{ .val = pos.line };
    buffer.cursor.render_col = .{ .val = pos.col };

    // if (is_out_of_screen) {
    //     buffer.start_line += 1;
    // }
}

fn cursorUp(buffer: *Buffer, table: *const PieceTable) void {
    const maybe_pos = table.clampPosition(buffer.cursor.line.val - 1, buffer.cursor.col.val);
    const pos = maybe_pos orelse return;

    buffer.cursor.line = .{ .val = pos.line };
    buffer.cursor.render_col = .{ .val = pos.col };
}

fn cursorLeft(buffer: *Buffer, table: *const PieceTable) void {
    const maybe_pos = table.clampPosition(buffer.cursor.line.val, buffer.cursor.col.val - 1);
    const pos = maybe_pos orelse return;

    buffer.cursor.line = .{ .val = pos.line };
    buffer.cursor.render_col = .{ .val = pos.col };
    buffer.cursor.col = buffer.cursor.render_col;
}

fn cursorRight(buffer: *Buffer, table: *const PieceTable) void {
    const maybe_pos = table.clampPosition(buffer.cursor.line.val, buffer.cursor.col.val + 1);
    const pos = maybe_pos orelse return;

    buffer.cursor.line = .{ .val = pos.line };
    buffer.cursor.render_col = . { .val = pos.col };
    buffer.cursor.col = buffer.cursor.render_col;
}

fn processInput(screen: *Screen, resources: *const EditorResources, bh: ref.BufferHandle) !bool {
    const ev = try terminal.readInputEvent();
    if (ev == null) {
        return false;
    }

    var buffer = resources.getBuffer(bh);
    var table = resources.getTable(buffer.th);

    switch (ev.?) {
        .q => {
            return true;
        },
        .j, .down => {
            cursorDown(buffer, table);
        },
        .k, .up => {
            cursorUp(buffer, table);
        },
        .h, .left => {
            cursorLeft(buffer, table);
        },
        .l, .right => {
            cursorRight(buffer, table);
        },
        .page_up => {
            var times = screen.window.line_count;
            while (times > 0) : (times -= 1) {
                cursorUp(buffer, table);
            }
        },
        .page_down => {
            var times = screen.window.line_count;
            while (times > 0) : (times -= 1) {
                cursorDown(buffer, table);
            }
        },
        .home => {
            var times = screen.window.col_count;
            while (times > 0) : (times -= 1) {
                cursorLeft(buffer, table);
            }
        },
        .end => {
            var times = screen.window.col_count;
            while (times > 0) : (times -= 1) {
                cursorRight(buffer, table);
            }
        },
        .a => {
            try table.insert(buffer.cursor.table_offset, "a");
            try buffer.updateContents(table);
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

fn drawWindow(writer: anytype, win: Window, resources: *const EditorResources, bh: ref.BufferHandle) !void {
    try terminal.moveCursorToPosition(writer, .{ 
        .line = win.start_line, 
        .col = win.start_col,
    });

    const buffer = resources.getBuffer(bh);
    assert(findCharInString(buffer.contents, '\r') == null);

    var line: terminal.Line = win.start_line;
    var remaining_string = buffer.contents;

    const last_line: terminal.Line = .{ .val = win.start_line.val + win.line_count };

    while (line.val < last_line.val) : (line = .{ .val = line.val + 1 }) {
        if (remaining_string.len == 0) {
            try terminal.moveCursorToPosition(writer, .{
                .line = line,
                .col = win.properties.markers_col.toTerminalCol(win.start_col),
            });
            _ = try writer.write("~");
            continue;
        }

        {
            // Draw the line numbers
            try terminal.moveCursorToPosition(writer, .{
                .line = line,
                .col = win.properties.line_number_col.toTerminalCol(win.start_col),
            });
            _ = try writer.print("{d: <5}", .{@intCast(u32, line.val + 1)});
        }

        try terminal.moveCursorToPosition(writer, .{ 
            .line = line, 
            .col = win.properties.buffer_col.toTerminalCol(win.start_col),
        });

        const index = findCharInString(remaining_string, '\n') orelse {
            _ = try writer.write(remaining_string);
            remaining_string = "";
            continue;
        };

        _ = try writer.write(remaining_string[0..index]);

        remaining_string = remaining_string[index + 1 .. remaining_string.len];
    }

    try terminal.moveCursorToPosition(writer, .{
        .line = buffer.cursor.line
            .toWindowLine(win.properties.buffer_line)
            .toTerminalLine(win.start_line),
        .col = buffer.cursor.render_col
            .toWindowCol(win.properties.buffer_col)
            .toTerminalCol(win.start_col),
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

fn welcomeBuffer(allocator: Allocator, screen: Screen, resources: *EditorResources) !ref.BufferHandle {
    const max_col_len = 17;
    const padding_len = @divFloor(screen.window.col_count - max_col_len, 2);

    const padding = try createPaddingString(allocator, padding_len);
    defer allocator.free(padding);

    var buf = try allocator.alloc(u8, 2048);
    defer allocator.free(buf);

    const message = try std.fmt.bufPrint(buf,
        \\
        \\
        \\{s} _             _ 
        \\{s}| |    ___  __| |
        \\{s}| |   / _ \/ _` |
        \\{s}| |__|  __/ (_| |
        \\{s}|_____\___|\__,_|
        \\
        \\{s}  version {s}
    , .{ padding, padding, padding, padding, padding, padding, VERSION });

    const table_handle = try resources.createTableFromString(message);
    const buffer_handle = try resources.createBuffer(table_handle);
    return buffer_handle;
}

fn run(allocator: Allocator, args: Args) anyerror!void {
    var cwd = std.fs.cwd();

    var resources = try EditorResources.init(allocator);
    defer resources.deinit();

    var frame = std.ArrayList(u8).init(allocator);
    defer frame.deinit();

    var screen = try Screen.init(frame.writer());
    defer screen.deinit() catch {};

    var bh: ref.BufferHandle = undefined;
    if (args.file_path != null) {
        var file = try cwd.openFile(args.file_path.?, .{ .read = true });
        var table_handle = try resources.createTableFromFile(file);
        bh = try resources.createBuffer(table_handle);
    } else {
        bh = try welcomeBuffer(allocator, screen, &resources);
    }

    while (true) {
        try terminal.hideCursor(frame.writer());
        try terminal.refreshScreen(frame.writer());
        try drawWindow(frame.writer(), screen.window, &resources, bh);
        try terminal.showCursor(frame.writer());

        const stdout = std.io.getStdOut();
        _ = try stdout.write(frame.items);
        frame.clearRetainingCapacity();

        if (try processInput(&screen, &resources, bh)) {
            break;
        }
    }
}

pub fn main() anyerror!void {
    try log.init();
    defer log.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{
        // NOTE(lhahn): debug values.
        .retain_metadata = true,
        .never_unmap = true,
    }){};
    var allocator = gpa.allocator();

    var args = try Args.init(allocator);
    defer args.deinit();

    run(allocator, args) catch |err| {
        log.errf("run failed: {s}", .{err});
    };
}
