const std = @import("std");
const Allocator = std.mem.Allocator;
const ref = @import("./ref.zig");
const PieceTable = @import("./piece_table.zig").PieceTable;
const window = @import("./window.zig");

pub const Line = struct { 
    val: i32,

    const Self = @This();
    pub fn toWindowLine(self: Self, offset: window.Line) window.Line {
        return .{ .val = self.val + offset.val };
    }

    pub fn sub(self: Self, other: Self) Self {
        return .{ .val = self.val - other.val };
    }
};

pub const Col = struct { 
    val: i32,

    const Self = @This();
    pub fn toWindowCol(self: Self, offset: window.Col) window.Col {
        return .{ .val = self.val + offset.val };
    }
};

pub const Cursor = struct {
    line: Line,
    col: Col,
    render_col: Col,
    table_offset: u32,
};

pub const Buffer = struct {
    allocator: Allocator,
    th: ref.TableHandle,
    contents: []const u8,
    read_only: bool,
    cursor: Cursor,
    start_line: i32,

    const Self = @This();

    pub fn init(allocator: Allocator, th: ref.TableHandle, table: *const PieceTable) !Self {
        var contents = try table.toString(allocator, 0);

        return Self{
            .allocator = allocator,
            .th = th,
            .contents = contents,
            .read_only = false,
            .start_line = 0,
            .cursor = .{
                .line = .{ .val = 0 },
                .col = .{ .val = 0 },
                .render_col = .{ .val = 0 },
                .table_offset = 0,
            },
        };
    }

    pub fn updateContents(self: *Self, table: *const PieceTable) !void {
        self.allocator.free(self.contents);
        self.contents = try table.toString(self.allocator, self.start_line);
    }

    pub fn scrollLines(self: *Self, lines: i32, table: *const PieceTable) !void {
        self.start_line += lines; 
        try self.updateContents(table);
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.contents);
    }
};
