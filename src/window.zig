const terminal = @import("./terminal.zig");

pub const Attributes = packed struct {
    horizontal_border: bool = false,
};

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

pub const ContentsLine = struct {
    val: i32,

    const Self = @This();
    pub fn toWindowLine(self: Self, offset: Line) Line {
        return .{ .val = self.val + offset.val };
    }

    pub fn sub(self: Self, other: Self) Self {
        return .{ .val = self.val - other.val };
    }
};

pub const ContentsCol = struct {
    val: i32,

    const Self = @This();
    pub fn toWindowCol(self: Self, offset: Col) Col {
        return .{ .val = self.val + offset.val };
    }
};

pub const Cursor = struct {
    line: ContentsLine,
    col: ContentsCol,
    render_col: ContentsCol,
    table_offset: u32,
};

pub const Properties = struct {
    line_number_col: Col,
    markers_col: Col,

    buffer_line: Line,
    buffer_col: Col,

    status_line: ?Line,
};

pub const TerminalBoundary = struct {
    start_col: terminal.Col,
    start_line: terminal.Line,
    line_count: i32,
    col_count: i32,
};

var next_window_id: i32 = 1;

pub fn genId() i32 {
    const id = next_window_id;
    next_window_id += 1;
    return id;
}

pub const Window = struct {
    id: i32,
    properties: Properties,
    boundary: TerminalBoundary,
    attributes: Attributes,
    cursor: Cursor,

    const Self = @This();

    pub fn lastTerminalLine(self: *const Self) terminal.Line {
        return .{
            .val = self.boundary.start_line.val + self.boundary.line_count - 1,
        };
    }

    pub fn isStatusLine(self: *const Self, line: terminal.Line) bool {
        const wl = Line{ .val = line.val - self.boundary.start_line.val };
        const status_line = self.properties.status_line orelse return false;
        return wl.val == status_line.val;
    }
};
