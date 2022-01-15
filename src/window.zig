const terminal = @import("./terminal.zig");

pub const Line = struct {
    val: i32,

    const Self = @This();
    pub fn toTerminalLine(self: Self, offset: terminal.Line) terminal.Line {
        return .{
            .val = self.val + offset.val,
        };
    }
};

pub const Col = struct {
    val: i32,

    const Self = @This();
    pub fn toTerminalCol(self: Self, offset: terminal.Col) terminal.Col {
        return .{
            .val = self.val + offset.val,
        };
    }
};

pub const Properties = struct {
    line_number_col: Col,
    markers_col: Col,

    buffer_line: Line,
    buffer_col: Col,

    status_line: Line,
};

pub const TerminalBoundary = struct {
    start_col: terminal.Col,
    start_line: terminal.Line,
    line_count: i32,
    col_count: i32,
};

pub const Window = struct {
    properties: Properties,
    boundary: TerminalBoundary,

    const Self = @This();

    pub fn lastTerminalLine(self: *const Self) terminal.Line {
        return .{
            .val = self.boundary.start_line.val + self.boundary.line_count - 1,
        };
    }

    pub fn isStatusLine(self: *const Self, line: terminal.Line) bool {
        const wl = Line{ .val = line.val - self.boundary.start_line.val };
        return wl.val == self.properties.status_line.val;
    }
};
