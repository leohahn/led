const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Position = struct {
    line: i32,
    col: i32,
};

const Buffer = enum {
    original,
    append,
};

const Buffers = struct {
    original: []const u8,
    append: std.ArrayListUnmanaged(u8),
};

const Piece = struct {
    const Self = @This();

    start: u32,
    len: u32,
    buffer: Buffer,

    line_count: i32,

    fn getBuffer(self: *const Self, buffers: Buffers) []const u8 {
        return switch (self.buffer) {
            .original => buffers.original[self.start .. self.start + self.len],
            .append => buffers.append.items[self.start .. self.start + self.len],
        };
    }
};

const PiecePosition = union(enum) {
    end_of_buffer,
    inside_piece: struct {
        index: u32,
        offset: u32,
    },
};

fn findBytePositionFromRune(rune_position: u32, piece_buffer: []const u8) ?u32 {
    var rune_i: u32 = 0;
    var it = std.unicode.Utf8Iterator{
        .bytes = piece_buffer,
        .i = 0,
    };
    while (rune_i != rune_position) : (rune_i += 1) {
        if (it.nextCodepoint() == null) {
            return null;
        }
    }
    return @intCast(u32, it.i);
}

fn countLinesInString(str: []const u8) i32 {
    var count: i32 = 0;
    for (str) |c| {
        if (c == '\n') {
            count += 1;
        }
    }
    return count;
}

fn clampColumnInLine(string: []const u8, line: i32, col: i32) i32 {
    var current_line: i32 = 0;
    var current_col: i32 = 0;

    var it = std.unicode.Utf8Iterator{
        .i = 0,
        .bytes = string,
    };

    while (true) {
        const codepoint_slice = it.peek(1);
        if (codepoint_slice.len == 0) {
            break;
        }
        const current_codepoint = std.unicode.utf8Decode(codepoint_slice) catch unreachable;

        if (current_line < line) {
            if (current_codepoint == @as(u21, '\n')) {
                current_line += 1;
                current_col = 0;
            } else {
                current_col += 1;
            }
            _ = it.nextCodepoint() orelse break;
            continue;
        }

        if (current_codepoint == @as(u21, '\n')) {
            if (current_col > 1) {
                current_col -= 1;
            }
            break;
        }

        if (current_col == col) {
            break;
        }

        current_col += 1;
        _ = it.nextCodepoint() orelse break;
    }

    assert(current_line == line);
    return current_col;
}

pub const PieceTable = struct {
    const Self = @This();

    allocator: Allocator,
    buffers: Buffers,
    pieces: std.ArrayListUnmanaged(Piece),

    pub fn initFromFile(allocator: Allocator, file: std.fs.File) !Self {
        const file_size = try file.getEndPos();
        var original_buffer = try file.readToEndAlloc(allocator, file_size);

        return initFromOriginalBuffer(allocator, original_buffer);
    }

    pub fn initFromString(allocator: Allocator, buf: []const u8) !Self {
        var owned_buf = try allocator.alloc(u8, buf.len);
        std.mem.copy(u8, owned_buf, buf);

        return initFromOriginalBuffer(allocator, owned_buf);
    }

    fn initFromOriginalBuffer(allocator: Allocator, original_buffer: []const u8) !Self {
        if (!std.unicode.utf8ValidateSlice(original_buffer)) {
            return error.InvalidUtf8Slice;
        }

        var pieces = try std.ArrayListUnmanaged(Piece).initCapacity(allocator, 8);
        try pieces.append(allocator, Piece{
            .start = 0,
            .len = @intCast(u32, original_buffer.len),
            .buffer = Buffer.original,
            .line_count = countLinesInString(original_buffer),
        });

        return Self{
            .allocator = allocator,
            .buffers = .{
                .original = original_buffer,
                .append = .{},
            },
            .pieces = pieces,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buffers.original);
        self.buffers.append.deinit(self.allocator);
        self.pieces.deinit(self.allocator);
    }

    pub fn len(self: *Self) u32 {
        var length: u32 = 0;
        for (self.pieces.items) |piece| {
            const buf_len = std.unicode.utf8CountCodepoints(piece.getBuffer(self.buffers)) catch unreachable;
            length += @intCast(u32, buf_len);
        }
        return length;
    }

    pub fn toString(self: *const Self, allocator: Allocator) ![]const u8 {
        var str_buf = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 20);

        for (self.pieces.items) |piece| {
            const piece_buffer = piece.getBuffer(self.buffers);
            try str_buf.appendSlice(allocator, piece_buffer);
        }

        return str_buf.toOwnedSlice(allocator);
    }

    pub fn insert(self: *Self, position: u32, slice: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(slice)) {
            return error.InvalidUtf8Slice;
        }

        const piece_position = self.findPosition(position) orelse return error.InvalidPosition;

        var inserted_piece: Piece = try self.addToAppendBuffer(slice);

        switch (piece_position) {
            .end_of_buffer => {
                try self.pieces.insert(self.allocator, self.pieces.items.len, inserted_piece);
            },
            .inside_piece => |inside_piece| {
                const slice_len = @intCast(u32, try std.unicode.utf8CountCodepoints(slice));
                const piece = self.pieces.items[inside_piece.index];
                if (inside_piece.offset == 0) {
                    // The position is in the beginning of an existing piece, therefore we only have
                    // to add the new piece before the current one.
                    try self.pieces.insert(self.allocator, inside_piece.index, inserted_piece);
                    return;
                }

                const piece_buffer = piece.getBuffer(self.buffers);

                const piece_before = Piece{
                    .start = 0,
                    .len = inside_piece.offset,
                    .buffer = piece.buffer,
                    .line_count = countLinesInString(piece_buffer[0..inside_piece.offset]),
                };
                const piece_after = Piece{
                    .start = inside_piece.offset,
                    .len = slice_len - inside_piece.offset,
                    .buffer = piece.buffer,
                    .line_count = countLinesInString(
                        piece_buffer[inside_piece.offset .. slice_len - inside_piece.offset],
                    ),
                };

                _ = self.pieces.orderedRemove(inside_piece.index);
                try self.pieces.insert(self.allocator, inside_piece.index, piece_after);
                try self.pieces.insert(self.allocator, inside_piece.index, inserted_piece);
                try self.pieces.insert(self.allocator, inside_piece.index, piece_before);
            },
        }
    }

    pub fn itemAt(self: *const Self, rune_position: u32) ?u21 {
        const piece_position = self.findPosition(rune_position) orelse return null;

        switch (piece_position) {
            .inside_piece => |inside_piece| {
                const piece = self.pieces.items[inside_piece.index];
                const buffer = piece.getBuffer(self.buffers);

                return utf8At(buffer, inside_piece.offset);
            },
            .end_of_buffer => return null,
        }
    }

    fn moveToDesiredLineFromPosition(self: *const Self, desired_line: i32, col: i32) ?Position {
        if (desired_line < 0) {
            return null;
        }

        assert(col >= 0);

        var maybe_piece_index: ?usize = null;
        var accumulated_line: i32 = 0;

        for (self.pieces.items) |piece, index| {
            const new_accumulated_line: i32 = accumulated_line + piece.line_count;
            if (new_accumulated_line > desired_line) {
                maybe_piece_index = index; 
                break;
            }
            accumulated_line = new_accumulated_line;
        }

        const piece_index = maybe_piece_index orelse return null;
        const piece_buffer = self.pieces.items[piece_index].getBuffer(self.buffers);

        const new_col = clampColumnInLine(piece_buffer, desired_line - accumulated_line, col);

        return Position{
            .line = desired_line,
            .col = new_col,
        };
    }

    pub fn lineBelow(self: *const Self, line: i32, col: i32) ?Position {
        const desired_line = line + 1;
        return self.moveToDesiredLineFromPosition(desired_line, col);
    }

    pub fn lineAbove(self: *const Self, line: i32, col: i32) ?Position {
        const desired_line = line - 1;
        return self.moveToDesiredLineFromPosition(desired_line, col);
    }

    fn addToAppendBuffer(self: *Self, slice: []const u8) !Piece {
        const start = @intCast(u32, self.buffers.append.items.len);
        const slice_len = @intCast(u32, slice.len);
        try self.buffers.append.appendSlice(self.allocator, slice);
        const inserted_piece = Piece{
            .buffer = Buffer.append,
            .start = start,
            .len = slice_len,
            .line_count = countLinesInString(self.buffers.append.items[start .. start + slice_len]),
        };
        return inserted_piece;
    }

    fn findPosition(self: *const Self, rune_position: u32) ?PiecePosition {
        var piece_index: ?u32 = null;
        var piece_offset: u32 = 0;

        var accumulated_byte_offset: u32 = 0;
        var accumulated_rune_offset: u32 = 0;

        for (self.pieces.items) |piece, index| {
            const buffer = piece.getBuffer(self.buffers);
            const buffer_rune_count = @intCast(u32, std.unicode.utf8CountCodepoints(buffer) catch unreachable);

            accumulated_rune_offset += buffer_rune_count;
            accumulated_byte_offset += @intCast(u32, buffer.len);

            if (accumulated_rune_offset <= rune_position) {
                continue;
            }

            const offset = findBytePositionFromRune(
                rune_position - (accumulated_rune_offset - buffer_rune_count),
                buffer,
            );

            if (offset == null) {
                unreachable;
            }

            piece_index = @intCast(u32, index);
            piece_offset = (accumulated_byte_offset - @intCast(u32, buffer.len)) + offset.?;

            break;
        }

        if (piece_index == null) {
            if (accumulated_rune_offset == rune_position) {
                return PiecePosition.end_of_buffer;
            }
            return null;
        }

        return PiecePosition{
            .inside_piece = .{
                .index = piece_index.?,
                .offset = piece_offset,
            },
        };
    }
};

fn utf8At(slice: []const u8, offset: u32) ?u21 {
    var sequence_length = std.unicode.utf8ByteSequenceLength(slice[offset]) catch unreachable;
    var sequence = slice[offset .. offset + sequence_length];

    const codepoint = std.unicode.utf8Decode(sequence) catch unreachable;
    return codepoint;
}

fn readFileToString(allocator: Allocator, file: std.fs.File) ![]const u8 {
    const max_bytes = 100 * 1024 * 1024; // 100 MBs
    const pos = try file.getPos();
    try file.seekTo(0);
    const buffer = try file.readToEndAlloc(allocator, max_bytes);
    try file.seekTo(pos);
    return buffer;
}

fn assertPieceTableContents(pt: *const PieceTable, expected: []const u8) !void {
    const got = try pt.toString(std.testing.allocator);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(expected, got);
}

test "can insert into the beginning of a piece table" {
    var pt = try PieceTable.initFromString(std.testing.allocator,
        \\The dog is a nice animal.
        \\The cat is also cool.
    );
    defer pt.deinit();

    try assertPieceTableContents(&pt, "The dog is a nice animal.\nThe cat is also cool.");

    try pt.insert(0, "NEW");

    try std.testing.expectEqualStrings("NEW", pt.pieces.items[0].getBuffer(pt.buffers));
    try std.testing.expectEqualStrings("The dog is a nice animal.\nThe cat is also cool.", pt.pieces.items[1].getBuffer(pt.buffers));

    try assertPieceTableContents(&pt, "NEWThe dog is a nice animal.\nThe cat is also cool.");
}

test "can insert into the end of a piece table" {
    var pt = try PieceTable.initFromString(std.testing.allocator,
        \\The dog is a nice animal.
        \\The cat is also cool.
    );
    defer pt.deinit();

    try assertPieceTableContents(&pt, "The dog is a nice animal.\nThe cat is also cool.");

    try pt.insert(pt.len(), "NEW");

    try std.testing.expectEqualStrings("The dog is a nice animal.\nThe cat is also cool.", pt.pieces.items[0].getBuffer(pt.buffers));
    try std.testing.expectEqualStrings("NEW", pt.pieces.items[1].getBuffer(pt.buffers));

    try assertPieceTableContents(&pt, "The dog is a nice animal.\nThe cat is also cool.NEW");
}

test "can insert into the beginning" {
    var pt = try PieceTable.initFromString(std.testing.allocator,
        \\The dog is a nice animal.
        \\The cat is also cool.
    );
    defer pt.deinit();

    try assertPieceTableContents(&pt, "The dog is a nice animal.\nThe cat is also cool.");

    try pt.insert(0, "a");
    try pt.insert(0, "a");
    try pt.insert(0, "a");
    try pt.insert(0, "a");
    try pt.insert(0, "a");
    try pt.insert(0, "a");
    try pt.insert(0, "a");

    try assertPieceTableContents(&pt, "aaaaaaaThe dog is a nice animal.\nThe cat is also cool.");
}

test "can create a piece table and use itemAt" {
    var cwd = std.fs.cwd();
    var file = try cwd.openFile("fixtures/main.zig", .{ .read = true });
    defer file.close();

    var pt = try PieceTable.initFromFile(std.testing.allocator, file);
    defer pt.deinit();

    try std.testing.expectEqual(@as(u32, 408), pt.len());

    var item0 = pt.itemAt(0);
    try std.testing.expect(item0 != null);
    try std.testing.expectEqual(@as(u21, 'c'), item0.?);

    var item395 = pt.itemAt(395);
    try std.testing.expect(item395 != null);
    try std.testing.expectEqual(@as(u21, '😀'), item395.?);

    var item407 = pt.itemAt(407);
    try std.testing.expect(item407 != null);
    try std.testing.expectEqual(@as(u21, '\n'), item407.?);

    var item406 = pt.itemAt(406);
    try std.testing.expect(item406 != null);
    try std.testing.expectEqual(@as(u21, '}'), item406.?);

    var item408 = pt.itemAt(408);
    try std.testing.expect(item408 == null);

    var item409 = pt.itemAt(409);
    try std.testing.expect(item409 == null);

    const file_str = try readFileToString(std.testing.allocator, file);
    defer std.testing.allocator.free(file_str);

    const got_file_str = try pt.toString(std.testing.allocator);
    defer std.testing.allocator.free(got_file_str);

    try std.testing.expectEqualStrings(got_file_str, file_str);
}

test "utf8At" {
    const a: ?u21 = @intCast(u21, 'a');
    const smiley: ?u21 = @intCast(u21, '😀');
    try std.testing.expectEqual(smiley, utf8At("😀abcde 😀ghijkl😀", 0));
    try std.testing.expectEqual(smiley, utf8At("😀abcde 😀ghijkl😀", 10));
    try std.testing.expectEqual(smiley, utf8At("😀abcde 😀ghijkl😀", 20));
    try std.testing.expectEqual(a, utf8At("😀abcde 😀ghijkl😀", 4));
}

test "clampColumnInLine" {
    const expectEqual = std.testing.expectEqual;

    const text = 
        \\
        \\the big dog
        \\jumped over the lazy
        \\
        \\dog
        \\
    ;
    try expectEqual(@as(i32, 0), clampColumnInLine(text, 0, 0));
    try expectEqual(@as(i32, 0), clampColumnInLine(text, 0, 1));
    try expectEqual(@as(i32, 0), clampColumnInLine(text, 0, 2));
    try expectEqual(@as(i32, 0), clampColumnInLine(text, 0, 3));

    try expectEqual(@as(i32, 0), clampColumnInLine(text, 1, 0));
    try expectEqual(@as(i32, 1), clampColumnInLine(text, 1, 1));
    try expectEqual(@as(i32, 2), clampColumnInLine(text, 1, 2));
    try expectEqual(@as(i32, 10), clampColumnInLine(text, 1, 10));
    try expectEqual(@as(i32, 10), clampColumnInLine(text, 1, 11));
}

test "lineAbove" {
    const expectEqual = std.testing.expectEqual;

    const str = 
        \\the cat jumps over the lazy dog.
        \\I am going to disneyland.
        \\
        \\Longer line than above.
    ;

    var pt = try PieceTable.initFromString(std.testing.allocator, str);
    defer pt.deinit();

    {
        const pos = pt.lineAbove(0, 0) orelse unreachable;
        try expectEqual(pos, .{ .line = 0, .col = 0 });
    } 
    {
        const pos = pt.lineAbove(1, 0) orelse unreachable;
        try expectEqual(pos, .{ .line = 0, .col = 0 });
    }
    {
        const pos = pt.lineAbove(2, 0) orelse unreachable;
        try expectEqual(pos, .{ .line = 1, .col = 0 });
    }
    {
        const pos = pt.lineAbove(3, 4) orelse unreachable;
        try expectEqual(pos, .{ .line = 2, .col = 0 });
    }
}
