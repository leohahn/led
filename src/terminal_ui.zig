const std = @import("std");
const curses = @cImport({
    @cInclude("ncurses.h");
});

pub fn draw_contents(string: []const u8) void {
    curses.initscr();

    std.log.info("DRAW CONTENTS:\n{s}\n", .{string});
}
