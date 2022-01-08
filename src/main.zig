const std = @import("std");
const piece_table = @import("./piece_table.zig");
const terminal = @import("./terminal.zig");
const assert = std.debug.assert;

const VERSION = "0.1.0";

const Allocator = std.mem.Allocator;
const PieceTable = piece_table.PieceTable;

const Screen = struct {
    lines: i32,
    cols: i32,
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
        std.log.info("timeout", .{});
        return false;
    }

    const buffer = resources.getBuffer(bh);

    switch (ev.?) {
        .q => {
            return true;
        },
        .j, .down => {
            buffer.cursorDown(screen);
        },
        .k, .up => {
            buffer.cursorUp();
        },
        .h, .left => {
            buffer.cursorLeft();
        },
        .l, .right => {
            buffer.cursorRight(screen);
        },
        .page_up => {
            var times = screen.lines;
            while (times > 0) : (times -= 1) {
                buffer.cursorUp();
            }
        },
        .page_down => {
            var times = screen.lines;
            while (times > 0) : (times -= 1) {
                buffer.cursorDown(screen);
            }
        },
        .home => {
            var times = screen.cols;
            while (times > 0) : (times -= 1) {
                buffer.cursorLeft();
            }
        },
        .end => {
            var times = screen.cols;
            while (times > 0) : (times -= 1) {
                buffer.cursorRight(screen);
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

fn drawBuffer(writer: anytype, screen: Screen, resources: *const EditorResources, bh: BufferHandle) !void {
    try terminal.moveCursorToPosition(writer, .{ .line = 0, .col = 0 });
    _ = screen;

    const buffer = resources.getBuffer(bh);

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
        remaining_string = remaining_string[index.? + 1 .. remaining_string.len];
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
};

fn welcomeBuffer(allocator: Allocator, screen: Screen, resources: *EditorResources) !BufferHandle {
    const max_col_len = 17;
    const padding_len = @divFloor(screen.cols - max_col_len, 2);

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

const Buffer = struct {
    allocator: Allocator,
    table_handle: TableHandle,
    contents: []const u8,
    read_only: bool,
    cursor: Cursor,

    const Self = @This();

    fn init(allocator: Allocator, table_handle: TableHandle, resources: *const EditorResources) !Self {
        var table = resources.getTable(table_handle);
        var contents = try table.toString(allocator);

        return Self{
            .allocator = allocator,
            .table_handle = table_handle,
            .contents = contents,
            .read_only = false,
            .cursor = .{
                .line = 0,
                .col = 1,
            },
        };
    }

    fn deinit(self: *Self) void {
        self.allocator.free(self.contents);
    }

    fn cursorDown(self: *Self, screen: *const Screen) void {
        self.cursor.line = std.math.min(self.cursor.line + 1, screen.lines - 1);
    }

    fn cursorUp(self: *Self) void {
        self.cursor.line = std.math.max(self.cursor.line - 1, 0);
    }

    fn cursorLeft(self: *Self) void {
        self.cursor.col = std.math.max(self.cursor.col - 1, 1);
    }

    fn cursorRight(self: *Self, screen: *const Screen) void {
        self.cursor.col = std.math.min(self.cursor.col + 1, screen.cols - 1);
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

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .retain_metadata = true,
        .never_unmap = true,
    }){};
    var allocator = gpa.allocator();

    var args = try Args.init(allocator);
    defer args.deinit();

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
        try drawBuffer(frame.writer(), screen, &resources, bh);
        try terminal.showCursor(frame.writer());

        const stdout = std.io.getStdOut();
        _ = try stdout.write(frame.items);

        frame.clearRetainingCapacity();

        if (try processInput(&screen, &resources, bh)) {
            break;
        }
    }
}
