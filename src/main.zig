const std = @import("std");
const piece_table = @import("./piece_table.zig");
const terminal_ui = @import("./terminal_ui.zig");

const PieceTable = piece_table.PieceTable;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var cwd = std.fs.cwd();
    var file = try cwd.openFile("src/main.zig", .{ .read = true });

    var table = try PieceTable.initFromFile(gpa.allocator(), file);
    defer table.deinit();

    const table_contents = try table.toString(gpa.allocator());
    defer gpa.allocator().free(table_contents);

    terminal_ui.draw_contents(table_contents);
}
