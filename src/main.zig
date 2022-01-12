const std = @import("std");
const piece_table = @import("./piece_table.zig");
const terminal = @import("./terminal.zig");
const log = @import("./log.zig");
const assert = std.debug.assert;

const VERSION = "0.1.0";

const Allocator = std.mem.Allocator;
const PieceTable = piece_table.PieceTable;

const DisplayLine = struct { val: i32 };
const DisplayCol = struct { val: i32 };

const Window = struct {
    start_col: i32,
    start_line: i32,
    line_count: i32,
    col_count: i32,
};

const Screen = struct {
    window: Window,
    raw_mode: terminal.RawMode,

    const Self = @This();

    fn init(writer: anytype) !Self {
        const raw_mode = try terminal.RawMode.enable();
        try terminal.useAlternateScreenBuffer(writer);
        const size = try terminal.getWindowSize();

        return Self{
            .raw_mode = raw_mode,
            .window = Window{
                .start_col = 0,
                .start_line = 0,
                .line_count = size.lines,
                .col_count = size.cols,
            },
        };
    }

    fn deinit(self: *const Self) !void {
        try terminal.leaveAlternateScreenBuffer();
        try self.raw_mode.disable();
    }
};

fn processInput(screen: *Screen, resources: *const EditorResources, bh: BufferHandle) !bool {
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
            buffer.cursorDown(table, screen.window);
        },
        .k, .up => {
            buffer.cursorUp(table, screen.window);
        },
        .h, .left => {
            buffer.cursorLeft(table);
        },
        .l, .right => {
            buffer.cursorRight(table);
        },
        .page_up => {
            var times = screen.window.line_count;
            while (times > 0) : (times -= 1) {
                buffer.cursorUp(table, screen.window);
            }
        },
        .page_down => {
            var times = screen.window.line_count;
            while (times > 0) : (times -= 1) {
                buffer.cursorDown(table, screen.window);
            }
        },
        .home => {
            var times = screen.window.col_count;
            while (times > 0) : (times -= 1) {
                buffer.cursorLeft(table);
            }
        },
        .end => {
            var times = screen.window.col_count;
            while (times > 0) : (times -= 1) {
                buffer.cursorRight(table);
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

fn drawWindow(writer: anytype, window: Window, resources: *const EditorResources, bh: BufferHandle) !void {
    try terminal.moveCursorToPosition(writer, .{ .line = window.start_line, .col = window.start_col });

    const buffer = resources.getBuffer(bh);
    assert(findCharInString(buffer.contents, '\r') == null);

    var line: i32 = window.start_line;
    var remaining_string = buffer.contents;

    while (line < window.start_line + window.line_count) : (line += 1) {
        if (remaining_string.len == 0) {
            try terminal.moveCursorToPosition(writer, .{ .line = line, .col = buffer.properties.markers_col });
            _ = try writer.write("~");
            continue;
        }

        {
            // Draw the line numbers
            try terminal.moveCursorToPosition(writer, .{ 
                .line = line, .col = buffer.properties.line_number_col,
            });
            _ = try writer.print("{d: <5}", .{@intCast(u32, line + 1)});
        }

        try terminal.moveCursorToPosition(writer, .{ .line = line, .col = buffer.properties.text_col });

        const index = findCharInString(remaining_string, '\n') orelse {
            _ = try writer.write(remaining_string);
            remaining_string = "";
            continue;
        };

        _ = try writer.write(remaining_string[0..index]);

        remaining_string = remaining_string[index + 1 .. remaining_string.len];
    }

    try terminal.moveCursorToPosition(writer, .{
        .line = buffer.cursor.line,
        .col = buffer.cursor.col,
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

const BufferHandle = struct { val: u32 = 0 };
const TableHandle = struct { val: u32 = 0 };

const Cursor = struct {
    line: i32,
    col: i32,
    table_offset: u32,
};

fn welcomeBuffer(allocator: Allocator, screen: Screen, resources: *EditorResources) !BufferHandle {
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

const BufferProperties = struct {
    markers_col: i32,
    line_number_col: i32,
    text_col: i32,
};

const Buffer = struct {
    allocator: Allocator,
    th: TableHandle,
    contents: []const u8,
    read_only: bool,
    cursor: Cursor,
    properties: BufferProperties,

    const Self = @This();

    fn init(allocator: Allocator, th: TableHandle, resources: *const EditorResources) !Self {
        var table = resources.getTable(th);
        var contents = try table.toString(allocator);

        const text_col = 5;

        return Self{
            .allocator = allocator,
            .th = th,
            .contents = contents,
            .read_only = false,
            .properties = BufferProperties{
                .markers_col = 0,
                .line_number_col = 1,
                .text_col = text_col,
            },
            .cursor = .{
                .line = 0,
                .col = text_col,
                .table_offset = 0,
            },
        };
    }

    fn updateContents(self: *Self, table: *PieceTable) !void {
        self.allocator.free(self.contents);
        self.contents = try table.toString(self.allocator);
    }

    fn deinit(self: *Self) void {
        self.allocator.free(self.contents);
    }

    fn cursorDown(self: *Self, table: *const PieceTable, window: Window) void {
        const mapped_line: i32 = self.cursor.line - window.start_line;
        const mapped_col: i32 = self.cursor.col - (window.start_col + self.properties.text_col);

        const maybe_pos = table.lineBelow(mapped_line, mapped_col);
        const pos = maybe_pos orelse return;

        self.cursor.line = pos.line + window.start_line;
        self.cursor.col = pos.col + window.start_col + self.properties.text_col;
    }

    fn cursorUp(self: *Self, table: *const PieceTable, window: Window) void {
        const mapped_line: i32 = self.cursor.line - window.start_line;
        const mapped_col: i32 = self.cursor.col - (window.start_col + self.properties.text_col);

        const maybe_pos = table.lineAbove(mapped_line, mapped_col);
        const pos = maybe_pos orelse return;

        self.cursor.line = pos.line + window.start_line;
        self.cursor.col = pos.col + window.start_col + self.properties.text_col;
    }

    fn cursorLeft(self: *Self, table: *const PieceTable) void {
        if (self.cursor.table_offset == 0) {
            return;
        }

        const item = table.itemAt(self.cursor.table_offset - 1);
        if (item == null) {
            return;
        }

        if (item.? == @as(u21, '\n')) {
            return;
        }

        self.cursor.table_offset -= 1;
        self.cursor.col -= 1;
    }

    fn cursorRight(self: *Self, table: *const PieceTable) void {
        const item = table.itemAt(self.cursor.table_offset + 1);
        if (item == null) {
            return;
        }

        if (item.? == @as(u21, '\n')) {
            return;
        }

        self.cursor.table_offset += 1;
        self.cursor.col += 1;
    }
};

const EditorResources = struct {
    allocator: Allocator,
    buffers: std.ArrayListUnmanaged(Buffer),
    tables: std.ArrayListUnmanaged(PieceTable),

    const Self = @This();

    fn init(allocator: Allocator) !Self {
        const buffers = try std.ArrayListUnmanaged(Buffer).initCapacity(allocator, 10);
        const tables = try std.ArrayListUnmanaged(PieceTable).initCapacity(allocator, 10);
        return Self{
            .allocator = allocator,
            .buffers = buffers,
            .tables = tables,
        };
    }

    fn deinit(self: *Self) void {
        for (self.buffers.items) |*buffer| {
            buffer.deinit();
        }
        self.buffers.deinit(self.allocator);

        for (self.tables.items) |*table| {
            table.deinit();
        }
        self.tables.deinit(self.allocator);
    }

    fn createTableFromFile(self: *Self, file: std.fs.File) !TableHandle {
        var pt = try PieceTable.initFromFile(self.allocator, file);
        try self.tables.append(self.allocator, pt);
        return TableHandle{ .val = @intCast(u32, self.tables.items.len) - 1 };
    }

    fn createTableFromString(self: *Self, string: []const u8) !TableHandle {
        var pt = try PieceTable.initFromString(self.allocator, string);
        try self.tables.append(self.allocator, pt);
        return TableHandle{
            .val = @intCast(u32, self.tables.items.len) - 1,
        };
    }

    fn createBuffer(self: *Self, table_handle: TableHandle) !BufferHandle {
        const buffer = try Buffer.init(self.allocator, table_handle, self);
        try self.buffers.append(self.allocator, buffer);
        return BufferHandle{ .val = @intCast(u32, self.buffers.items.len) - 1 };
    }

    fn getTable(self: *const Self, th: TableHandle) *PieceTable {
        return &self.tables.items[th.val];
    }

    fn getBuffer(self: *const Self, bh: BufferHandle) *Buffer {
        return &self.buffers.items[bh.val];
    }
};

fn run(allocator: Allocator, args: Args) anyerror!void {
    var cwd = std.fs.cwd();

    var resources = try EditorResources.init(allocator);
    defer resources.deinit();

    var frame = std.ArrayList(u8).init(allocator);
    defer frame.deinit();

    var screen = try Screen.init(frame.writer());
    defer screen.deinit() catch {};

    var bh: BufferHandle = undefined;
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
