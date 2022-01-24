const std = @import("std");
const Allocator = std.mem.Allocator;
const ref = @import("./ref.zig");
const PieceTable = @import("./piece_table.zig").PieceTable;
const window = @import("./window.zig");

pub const Buffer = struct {
    allocator: Allocator,
    th: ref.TableHandle,
    contents: []const u8,
    read_only: bool,
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
