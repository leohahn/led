const std = @import("std");
const Allocator = std.mem.Allocator;
const ref = @import("./ref.zig");
const PieceTable = @import("./piece_table.zig").PieceTable;

pub const BufferProperties = struct {
    markers_col: i32,
    line_number_col: i32,
    text_col: i32,
};

pub const Cursor = struct {
    line: i32,
    col: i32,
    render_col: i32,
    table_offset: u32,
};

pub const Buffer = struct {
    allocator: Allocator,
    th: ref.TableHandle,
    contents: []const u8,
    read_only: bool,
    cursor: Cursor,
    start_line: i32,
    properties: BufferProperties,

    const Self = @This();

    pub fn init(allocator: Allocator, th: ref.TableHandle, table: *const PieceTable) !Self {
        var contents = try table.toString(allocator, 0);

        const text_col = 5;

        return Self{
            .allocator = allocator,
            .th = th,
            .contents = contents,
            .read_only = false,
            .start_line = 0,
            .properties = BufferProperties{
                .markers_col = 0,
                .line_number_col = 1,
                .text_col = text_col,
            },
            .cursor = .{
                .line = 0,
                .col = text_col,
                .render_col = text_col,
                .table_offset = 0,
            },
        };
    }

    pub fn updateContents(self: *Self, table: *PieceTable) !void {
        self.allocator.free(self.contents);
        self.contents = try table.toString(self.allocator, self.start_line);
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.contents);
    }
};

