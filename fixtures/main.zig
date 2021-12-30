const std = @import("std");
const piece_table = @import("./piece_table.zig");
const PieceTable = piece_table.PieceTable;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var table = try PieceTable.initFromFile(gpa.allocator(), "/Users/leonardohahn/dev/hed/src/main.zig");
    defer table.deinit();

    std.log.info("All your codebase are belong to us: 😀.", .{});
}
