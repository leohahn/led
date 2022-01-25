const std = @import("std");
const Allocator = std.mem.Allocator;
const ref = @import("./ref.zig");
const PieceTable = @import("./piece_table.zig").PieceTable;
const window = @import("./window.zig");

pub const Buffer = struct {
    th: ref.TableHandle,
    start_line: i32,

    const Self = @This();

    pub fn init(th: ref.TableHandle) Self {
        return Self{
            .th = th,
            .start_line = 0,
        };
    }

    pub fn scrollLines(self: *Self, lines: i32) !void {
        self.start_line += lines;
    }
};
