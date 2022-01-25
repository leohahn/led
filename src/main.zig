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
    line_count: i32,
    col_count: i32,
    window: Window,
    console_window: ?Window,
    raw_mode: terminal.RawMode,
    windows_to_buffers: std.AutoHashMap(i32, ref.BufferHandle),

    const Self = @This();

    fn init(allocator: Allocator, writer: anytype) !Self {
        const raw_mode = try terminal.RawMode.enable();
        try terminal.useAlternateScreenBuffer(writer);
        const size = try terminal.getWindowSize();

        const boundary = window.TerminalBoundary{
            .start_col = .{ .val = 0 },
            .start_line = .{ .val = 0 },
            .line_count = size.lines,
            .col_count = size.cols,
        };

        var properties = window.Properties{
            .markers_col = .{ .val = 0 },
            .line_number_col = .{ .val = 1 },
            .buffer_col = .{ .val = 5 },
            .buffer_line = .{ .val = 0 },
            .status_line = null,
        };
        properties.status_line = window.Line{ .val = size.lines - 1 };

        const win = Window{
            .id = 0,
            .attributes = .{},
            .boundary = boundary,
            .properties = properties,
            .cursor = .{
                .line = .{ .val = 0 },
                .col = .{ .val = 0 },
                .render_col = .{ .val = 0 },
                .table_offset = 0,
            },
        };

        var windows_to_buffers = std.AutoHashMap(i32, ref.BufferHandle).init(allocator);

        return Self{
            .windows_to_buffers = windows_to_buffers,
            .line_count = size.lines,
            .col_count = size.cols,
            .raw_mode = raw_mode,
            .window = win,
            .console_window = null,
        };
    }

    fn attachBufferToWindow(self: *Self, bh: ref.BufferHandle, window_id: i32) !void {
        try self.windows_to_buffers.putNoClobber(window_id, bh);
    }

    fn deinit(self: *Self) !void {
        try terminal.leaveAlternateScreenBuffer();
        try self.raw_mode.disable();
        self.windows_to_buffers.deinit();
    }

    fn getActiveWindow(self: *Self) *Window {
        if (self.console_window != null) {
            return &self.console_window.?;
        }
        return &self.window;
    }

    fn getConsoleWindowHeight(self: *const Self) i32 {
        return @floatToInt(i32, @intToFloat(f32, self.line_count) * 0.3);
    }

    fn closeConsoleWindow(self: *Self) void {
        self.window.boundary.line_count += 1;
        self.window.attributes.horizontal_border = false;
        self.console_window = null;
    }

    fn openConsoleWindow(self: *Self) !void {
        self.window.boundary.line_count -= 1;
        // self.window.boundary.line_count -= height;
        self.window.attributes.horizontal_border = true;

        self.console_window = Window{
            .id = window.genId(),
            .boundary = window.TerminalBoundary{
                .start_col = .{ .val = 0 },
                .start_line = .{
                    .val = self.window.boundary.start_line.val + self.window.boundary.line_count,
                },
                .line_count = self.line_count - self.window.boundary.line_count,
                .col_count = self.col_count,
            },
            .properties = window.Properties{
                .markers_col = .{ .val = 0 },
                .line_number_col = .{ .val = 1 },
                .buffer_col = .{ .val = 5 },
                .buffer_line = .{ .val = 0 },
                .status_line = null,
            },
            .attributes = .{},
            .cursor = .{
                .line = .{ .val = 0 },
                .col = .{ .val = 0 },
                .render_col = .{ .val = 0 },
                .table_offset = 0,
            },
        };

        // try self.attachBufferToWindow(bh, self.console_window.?.id);
    }
};

fn cursorDown(win: *Window, table: *const PieceTable) void {
    const maybe_pos = table.clampPosition(win.cursor.line.val + 1, win.cursor.col.val);
    const pos = maybe_pos orelse return;

    win.cursor.line = .{ .val = pos.line };
    win.cursor.render_col = .{ .val = pos.col };
    win.cursor.table_offset = pos.offset;
}

fn cursorUp(win: *Window, table: *const PieceTable) void {
    const maybe_pos = table.clampPosition(win.cursor.line.val - 1, win.cursor.col.val);
    const pos = maybe_pos orelse return;

    win.cursor.line = .{ .val = pos.line };
    win.cursor.render_col = .{ .val = pos.col };
    win.cursor.table_offset = pos.offset;
}

fn cursorLeft(win: *Window, table: *const PieceTable) void {
    const maybe_pos = table.clampPosition(win.cursor.line.val, win.cursor.col.val - 1);
    const pos = maybe_pos orelse return;

    win.cursor.line = .{ .val = pos.line };
    win.cursor.render_col = .{ .val = pos.col };
    win.cursor.col = win.cursor.render_col;
    win.cursor.table_offset = pos.offset;
}

fn cursorRight(win: *Window, table: *const PieceTable) void {
    const maybe_pos = table.clampPosition(win.cursor.line.val, win.cursor.col.val + 1);
    const pos = maybe_pos orelse return;

    win.cursor.line = .{ .val = pos.line };
    win.cursor.render_col = .{ .val = pos.col };
    win.cursor.col = win.cursor.render_col;
    win.cursor.table_offset = pos.offset;
}

const VimMode = enum {
    normal,
    insert,
};

const Command = union(enum) {
    cursor_down,
    cursor_up,
    cursor_left,
    cursor_right,
    quit,
    half_screen_up,
    half_screen_down,
    goto_end_of_line,
    goto_start_of_line,
    insert: u8,
    remove_here,
    open_console_window,
    close_console_window,
    noop,
};

const VimEmulator = struct {
    mode: VimMode,

    const Self = @This();

    fn processKey(self: *Self, key_event: terminal.KeyEvent) Command {
        _ = self;
        // switch (self.mode) {
        //     .normal => {},
        //     .insert => {},
        // }

        switch (key_event) {
            .char => |c| {
                if (c == 'q') {
                    return .quit;
                }
                if (c == 'j') {
                    return .cursor_down;
                }
                if (c == 'k') {
                    return .cursor_up;
                }
                if (c == 'h') {
                    return .cursor_left;
                }
                if (c == 'l') {
                    return .cursor_right;
                }
                if (c == ':') {
                    return .open_console_window;
                }
                return Command{
                    .insert = c,
                };
            },
            .down => {
                return .cursor_down;
            },
            .up => {
                return .cursor_up;
            },
            .left => {
                return .cursor_left;
            },
            .right => {
                return .cursor_right;
            },
            .page_up => {
                return .half_screen_up;
            },
            .page_down => {
                return .half_screen_down;
            },
            .home => {
                return .goto_start_of_line;
            },
            .end => {
                return .goto_end_of_line;
            },
            .backspace => {
                return .remove_here;
            },
            .enter => {
                return Command{
                    .insert = '\n',
                };
            },
            .esc => {
                return .close_console_window;
            },
            else => {
                return .noop;
            },
        }
    }
};

fn processCommand(
    screen: *Screen,
    command: Command,
    resources: *const EditorResources,
    bh: ref.BufferHandle,
) !bool {
    var buffer = resources.getBuffer(bh);
    var table = resources.getTable(buffer.th);
    var win = screen.getActiveWindow();

    switch (command) {
        .cursor_down => {
            cursorDown(win, table);
        },
        .cursor_up => {
            cursorUp(win, table);
        },
        .cursor_left => {
            cursorLeft(win, table);
        },
        .cursor_right => {
            cursorRight(win, table);
        },
        .quit => {
            return true;
        },
        .half_screen_up => {
            var times = screen.window.boundary.line_count;
            while (times > 0) : (times -= 1) {
                cursorUp(win, table);
            }
        },
        .half_screen_down => {
            var times = screen.window.boundary.line_count;
            while (times > 0) : (times -= 1) {
                cursorDown(win, table);
            }
        },
        .goto_end_of_line => {
            var times = screen.window.boundary.col_count;
            while (times > 0) : (times -= 1) {
                cursorRight(win, table);
            }
        },
        .goto_start_of_line => {
            var times = screen.window.boundary.col_count;
            while (times > 0) : (times -= 1) {
                cursorLeft(win, table);
            }
        },
        .insert => |c| {
            log.infof("inserting into offset {d}", .{win.cursor.table_offset});
            var buf = [1]u8{c};
            try table.insert(win.cursor.table_offset, &buf);
            cursorRight(win, table);
        },
        .remove_here => {
            try table.remove(win.cursor.table_offset, win.cursor.table_offset);
            cursorLeft(win, table);
        },
        .open_console_window => {
            try screen.openConsoleWindow();
        },
        .close_console_window => {
            screen.closeConsoleWindow();
        },
        .noop => {
            // do nothing.
        },
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

fn drawWindow(
    allocator: Allocator,
    writer: anytype,
    win: Window,
    resources: *const EditorResources,
    windows_to_buffers: *const std.AutoHashMap(i32, ref.BufferHandle),
) !void {
    try terminal.moveCursorToPosition(writer, .{
        .line = win.boundary.start_line,
        .col = win.boundary.start_col,
    });

    const bh = windows_to_buffers.get(win.id) orelse {
        return error.UnknownBufferForWindow;
    };

    var buffer = resources.getBuffer(bh);

    const table = resources.getTable(buffer.th);

    var contents = try table.toString(allocator, buffer.start_line);
    defer allocator.free(contents);

    assert(findCharInString(contents, '\r') == null);

    const last_terminal_line = win.lastTerminalLine();

    // The numbers of line that we need to skip in order to be able to see the cursor on the screen.
    const lines_to_skip: i32 = blk: {
        const cursor_line = win.cursor.line
            .toWindowLine(win.properties.buffer_line);

        const cursor_window_line = cursor_line.val - buffer.start_line;

        if (cursor_window_line > last_terminal_line.val) {
            break :blk cursor_window_line - last_terminal_line.val;
        }

        if (cursor_window_line < 0) {
            break :blk cursor_window_line;
        }

        break :blk 0;
    };

    if (lines_to_skip != 0) {
        try buffer.scrollLines(lines_to_skip);
    }

    var line: terminal.Line = win.boundary.start_line;
    var remaining_string = contents;
    var display_line = buffer.start_line + 1;

    while (line.val <= last_terminal_line.val) : ({
        line = .{ .val = line.val + 1 };
        display_line += 1;
    }) {
        if ((line.val == last_terminal_line.val) and win.attributes.horizontal_border) {
            try terminal.moveCursorToPosition(writer, .{
                .line = line,
                .col = win.properties.markers_col.toTerminalCol(win.boundary.start_col),
            });

            var col: i32 = 0;
            while (col < win.boundary.col_count) : (col += 1) {
                _ = try writer.write("─");
            }
            continue;
        }

        if (win.isStatusLine(line)) {
            try terminal.moveCursorToPosition(writer, .{
                .line = line,
                .col = win.properties.markers_col.toTerminalCol(win.boundary.start_col),
            });
            _ = try writer.print("{d}:{d}", .{ win.cursor.line.val, win.cursor.col.val });
            continue;
        }

        if (remaining_string.len == 0) {
            try terminal.moveCursorToPosition(writer, .{
                .line = line,
                .col = win.properties.markers_col.toTerminalCol(win.boundary.start_col),
            });
            _ = try writer.write("~");
            continue;
        }

        {
            // Draw the line numbers
            try terminal.moveCursorToPosition(writer, .{
                .line = line,
                .col = win.properties.line_number_col.toTerminalCol(win.boundary.start_col),
            });
            _ = try writer.print("{d: <5}", .{@intCast(u32, display_line)});
        }

        try terminal.moveCursorToPosition(writer, .{
            .line = line,
            .col = win.properties.buffer_col.toTerminalCol(win.boundary.start_col),
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
        .line = win.cursor.line
            .sub(.{ .val = buffer.start_line })
            .toWindowLine(win.properties.buffer_line)
            .toTerminalLine(win.boundary.start_line),
        .col = win.cursor.render_col
            .toWindowCol(win.properties.buffer_col)
            .toTerminalCol(win.boundary.start_col),
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
    const padding_len = @divFloor(screen.window.boundary.col_count - max_col_len, 2);

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
    var resources = try EditorResources.init(allocator);
    defer resources.deinit();

    var frame = std.ArrayList(u8).init(allocator);
    defer frame.deinit();

    var screen = try Screen.init(allocator, frame.writer());
    defer screen.deinit() catch {};

    var bh: ref.BufferHandle = undefined;
    if (args.file_path != null) {
        var cwd = std.fs.cwd();
        var file = try cwd.openFile(args.file_path.?, .{ .read = true });
        var table_handle = try resources.createTableFromFile(file);
        bh = try resources.createBuffer(table_handle);
    } else {
        bh = try welcomeBuffer(allocator, screen, &resources);
    }

    try screen.attachBufferToWindow(bh, screen.window.id);

    var emulator = VimEmulator{
        .mode = VimMode.normal,
    };

    while (true) {
        try terminal.hideCursor(frame.writer());
        try terminal.refreshScreen(frame.writer());
        try drawWindow(allocator, frame.writer(), screen.window, &resources, &screen.windows_to_buffers);
        if (screen.console_window != null) {
            try drawWindow(allocator, frame.writer(), screen.console_window.?, &resources, &screen.windows_to_buffers);
        }
        try terminal.showCursor(frame.writer());

        const stdout = std.io.getStdOut();
        _ = try stdout.write(frame.items);
        frame.clearRetainingCapacity();

        const maybe_key = try terminal.readInputEvent();
        const key = maybe_key orelse {
            continue;
        };

        const command = emulator.processKey(key);

        const shouldQuit = try processCommand(&screen, command, &resources, bh);

        if (shouldQuit) {
            break;
        }
    }
}

pub fn main() anyerror!void {
    try log.init();
    defer log.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{
        // NOTE(lhahn): debug values.
        .safety = true,
        .retain_metadata = true,
        .never_unmap = true,
    }){};
    defer _ = gpa.deinit();

    var allocator = gpa.allocator();

    var args = try Args.init(allocator);
    defer args.deinit();

    run(allocator, args) catch |err| {
        log.errf("run failed: {s}", .{err});
    };
}
