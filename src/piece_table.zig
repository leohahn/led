const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const utf8CountCodepoints = std.unicode.utf8CountCodepoints;
const log = @import("log.zig");

const Position = struct {
    line: i32,
    col: i32,
    offset: u32,
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
    codepoint_count: u32,
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

const ColumnCount = union(enum) {
    count: struct {
        columns: i32,
        codepoints_until_line: u32,
    },
    unfinished_count: struct {
        columns: i32,
        codepoints_until_line: u32,
    },
};

fn countColumnsInLine(string: []const u8, line: i32) !ColumnCount {
    var current_line: i32 = 0;
    var column_count: i32 = 0;

    var it = std.unicode.Utf8Iterator{
        .i = 0,
        .bytes = string,
    };

    var line_ended = false;
    var codepoints_until_line: u32 = 0;

    while (it.nextCodepoint()) |codepoint| {
        if (current_line < line) {
            codepoints_until_line += 1;

            if (codepoint == @as(u21, '\n')) {
                current_line += 1;
                column_count = 0;
            } else {
                column_count += 1;
            }
            continue;
        }

        assert(current_line == line);

        if (codepoint == @as(u21, '\n')) {
            line_ended = true;
            break;
        }

        column_count += 1;
    }

    if (current_line < line) {
        return error.InvalidLine;
    }

    if (line_ended) {
        return ColumnCount{
            .count = .{
                .columns = column_count,
                .codepoints_until_line = codepoints_until_line,
            },
        };
    }

    return ColumnCount{
        .unfinished_count = .{
            .columns = column_count,
            .codepoints_until_line = codepoints_until_line,
        },
    };
}

fn findLineInString(s: []const u8, line: i32) ?u32 {
    var current_line: i32 = 0;
    var current_line_offset: u32 = 0;
    var current_str = s;

    while (current_line < line) {
        const maybe_offset = std.mem.indexOfPos(u8, current_str, current_line_offset, "\n");

        if (maybe_offset == null) {
            break;
        }

        const offset = maybe_offset.? + 1;

        if (offset >= current_str.len) {
            return null;
        }

        current_line += 1;
        current_line_offset = @intCast(u32, offset);
    }

    if (current_line != line) {
        return null;
    }

    return current_line_offset;
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

        var codepoint_count = try utf8CountCodepoints(original_buffer);

        var pieces = try std.ArrayListUnmanaged(Piece).initCapacity(allocator, 8);
        try pieces.append(allocator, Piece{
            .start = 0,
            .len = @intCast(u32, original_buffer.len),
            .buffer = Buffer.original,
            .line_count = countLinesInString(original_buffer),
            .codepoint_count = @intCast(u32, codepoint_count),
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
            const buf_len = utf8CountCodepoints(piece.getBuffer(self.buffers)) catch unreachable;
            length += @intCast(u32, buf_len);
        }
        return length;
    }

    // Given the desired line, finds the correct piece index. Returns null if it does not exist.
    fn findPieceWithLine(self: *const Self, line: i32) ?PiecePosition {
        assert(line >= 0);

        var maybe_piece_index: ?u32 = null;
        var accumulated_line: i32 = 0;

        for (self.pieces.items) |piece, index| {
            const new_accumulated_line: i32 = accumulated_line + piece.line_count;
            if (new_accumulated_line < line) {
                accumulated_line = new_accumulated_line;
                continue;
            }

            maybe_piece_index = @intCast(u32, index);
            break;
        }

        const piece_index = maybe_piece_index orelse return null;
        const piece_buffer = self.pieces.items[piece_index].getBuffer(self.buffers);

        const piece_offset = findLineInString(piece_buffer, line - accumulated_line);

        if (piece_offset == null) {
            if (piece_index + 1 >= self.pieces.items.len) {
                return null;
            }

            return PiecePosition{
                .inside_piece = .{
                    .index = piece_index + 1,
                    .offset = 0,
                },
            };
        }

        return PiecePosition{
            .inside_piece = .{
                .index = piece_index,
                .offset = piece_offset.?,
            },
        };
    }

    pub fn toString(self: *const Self, allocator: Allocator, start_line: i32) ![]const u8 {
        var str_buf = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 20);
        const maybe_piece_position = self.findPieceWithLine(start_line);
        const piece_position = maybe_piece_position orelse return str_buf.toOwnedSlice(allocator);

        switch (piece_position) {
            .end_of_buffer => {
                // do nothing
            },
            .inside_piece => |inside_piece| {
                log.info("T3");
                for (self.pieces.items[inside_piece.index..]) |piece, i| {
                    log.debugf("WILL GET PIECE BUFFER FOR {d}", .{i});
                    const piece_buffer = piece.getBuffer(self.buffers);
                    if (i == 0) {
                        const s = piece_buffer[inside_piece.offset..];
                        log.infof("s: {s}", .{s});
                        try str_buf.appendSlice(allocator, piece_buffer[inside_piece.offset..]);
                    } else {
                        const s = piece_buffer;
                        log.infof("s: {s}", .{s});
                        try str_buf.appendSlice(allocator, piece_buffer);
                    }
                }
            },
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
                const piece = self.pieces.items[inside_piece.index];
                const piece_buffer = piece.getBuffer(self.buffers);

                if (inside_piece.offset == 0) {
                    // The position is in the beginning of an existing piece, therefore we only have
                    // to add the new piece before the current one.
                    try self.pieces.insert(self.allocator, inside_piece.index, inserted_piece);
                    return;
                }

                const before_slice = piece_buffer[0..inside_piece.offset];
                const before_codepoint_count = try utf8CountCodepoints(before_slice);

                const piece_before = Piece{
                    .start = piece.start,
                    .len = @intCast(u32, before_slice.len),
                    .buffer = piece.buffer,
                    .line_count = countLinesInString(before_slice),
                    .codepoint_count = @intCast(u32, before_codepoint_count),
                };

                const after_slice = piece_buffer[inside_piece.offset..];
                const after_codepoint_count = try utf8CountCodepoints(after_slice);

                const piece_after = Piece{
                    .start = piece_before.start + piece_before.len,
                    .len = @intCast(u32, after_slice.len),
                    .buffer = piece.buffer,
                    .line_count = countLinesInString(after_slice),
                    .codepoint_count = @intCast(u32, after_codepoint_count),
                };

                _ = self.pieces.orderedRemove(inside_piece.index);
                try self.pieces.insert(self.allocator, inside_piece.index, piece_after);
                try self.pieces.insert(self.allocator, inside_piece.index, inserted_piece);
                try self.pieces.insert(self.allocator, inside_piece.index, piece_before);

                log.info("A8");
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

    pub fn clampPosition(self: *const Self, desired_line: i32, desired_col: i32) ?Position {
        if (desired_line < 0 or desired_col < 0) {
            return null;
        }

        assert(desired_col >= 0);

        var maybe_piece_index: ?u32 = null;
        var accumulated_line: i32 = 0;
        var accumulated_offset: u32 = 0;

        for (self.pieces.items) |piece, index| {
            const new_accumulated_line: i32 = accumulated_line + piece.line_count;
            if (new_accumulated_line >= desired_line) {
                maybe_piece_index = @intCast(u32, index);
                break;
            }
            accumulated_line = new_accumulated_line;
            accumulated_offset += piece.codepoint_count;
        }

        const piece_index = maybe_piece_index orelse return null;

        var accumulated_col: i32 = 0;

        outer: for (self.pieces.items[piece_index..]) |piece, index| {
            const piece_buffer = piece.getBuffer(self.buffers);

            var column_count: ColumnCount = undefined;

            if (index == 0) {
                column_count = countColumnsInLine(
                    piece_buffer,
                    desired_line - accumulated_line,
                ) catch unreachable;
            } else {
                column_count = countColumnsInLine(piece_buffer, 0) catch unreachable;
            }

            switch (column_count) {
                .count => |count| {
                    accumulated_col += count.columns;
                    accumulated_offset += count.codepoints_until_line;
                    break :outer;
                },
                .unfinished_count => |count| {
                    accumulated_col += count.columns;
                    accumulated_offset += count.codepoints_until_line;
                },
            }
        }

        // The above loop calculates the count.
        // We need to subtract one since cols are 0 based.
        if (accumulated_col > 0) {
            accumulated_col -= 1;
        }

        if (accumulated_col >= desired_col) {
            return Position{
                .line = desired_line,
                .col = desired_col,
                .offset = accumulated_offset + @intCast(u32, desired_col),
            };
        }

        return Position{
            .line = desired_line,
            .col = accumulated_col,
            .offset = accumulated_offset + @intCast(u32, accumulated_col),
        };
    }

    fn addToAppendBuffer(self: *Self, slice: []const u8) !Piece {
        const start = @intCast(u32, self.buffers.append.items.len);
        const slice_len = @intCast(u32, slice.len);
        try self.buffers.append.appendSlice(self.allocator, slice);

        const codepoint_count = try utf8CountCodepoints(slice);
        const inserted_piece = Piece{
            .buffer = Buffer.append,
            .start = start,
            .len = slice_len,
            .line_count = countLinesInString(self.buffers.append.items[start .. start + slice_len]),
            .codepoint_count = @intCast(u32, codepoint_count),
        };
        return inserted_piece;
    }

    fn findPosition(self: *const Self, rune_position: u32) ?PiecePosition {
        var piece_index: ?u32 = null;
        var piece_offset: u32 = 0;

        var accumulated_byte_count: u32 = 0;
        var accumulated_rune_count: u32 = 0;

        for (self.pieces.items) |piece, index| {
            const buffer = piece.getBuffer(self.buffers);
            const buffer_rune_count = @intCast(u32, utf8CountCodepoints(buffer) catch unreachable);

            accumulated_rune_count += buffer_rune_count;
            accumulated_byte_count += @intCast(u32, buffer.len);

            if (accumulated_rune_count <= rune_position) {
                continue;
            }

            const offset = findBytePositionFromRune(
                rune_position - (accumulated_rune_count - buffer_rune_count),
                buffer,
            );

            if (offset == null) {
                unreachable;
            }

            piece_index = @intCast(u32, index);
            piece_offset = offset.?;
            break;
        }

        if (piece_index == null) {
            if (accumulated_rune_count == rune_position) {
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

//=======================================================================
// Tests
//=======================================================================

fn readFileToString(allocator: Allocator, file: std.fs.File) ![]const u8 {
    const max_bytes = 100 * 1024 * 1024; // 100 MBs
    const pos = try file.getPos();
    try file.seekTo(0);
    const buffer = try file.readToEndAlloc(allocator, max_bytes);
    try file.seekTo(pos);
    return buffer;
}

fn assertPieceTableContents(pt: *const PieceTable, expected: []const u8) !void {
    const got = try pt.toString(std.testing.allocator, 0);
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

test "can insert into the middle: case 1" {
    var pt = try PieceTable.initFromString(std.testing.allocator, "abcdefghij\n");
    defer pt.deinit();

    try assertPieceTableContents(&pt, "abcdefghij\n");

    try pt.insert(2, "|");
    try pt.insert(2, "|");

    try assertPieceTableContents(&pt, "ab||cdefghij\n");
}

test "can insert into the beginning multiple times" {
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

    const got_file_str = try pt.toString(std.testing.allocator, 0);
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

test "countColumnsInLine" {
    const expectEqual = std.testing.expectEqual;
    const expectError = std.testing.expectError;

    const text = "\nthe big dog\njumped over the lazy\n\ndog\n\n";

    try expectEqual(
        ColumnCount{ .count = .{ .columns = 0, .codepoints_until_line = 0 } }, 
        try countColumnsInLine(text, 0));
    try expectEqual(
        ColumnCount{ .count = .{ .columns = 11, .codepoints_until_line = 1 } }, 
        try countColumnsInLine(text, 1));
    try expectEqual(
        ColumnCount{ .count = .{ .columns = 20, .codepoints_until_line = 13 } }, 
        try countColumnsInLine(text, 2));
    try expectEqual(
        ColumnCount{ .count = .{ .columns = 3, .codepoints_until_line = 35 } }, 
        try countColumnsInLine(text, 4));
    try expectEqual(
        ColumnCount{ .count = .{ .columns = 0, .codepoints_until_line = 39 } }, 
        try countColumnsInLine(text, 5));
    try expectEqual(
        ColumnCount{ .unfinished_count = .{ .columns = 0, .codepoints_until_line = 40 } }, 
        try countColumnsInLine(text, 6));
    try expectError(error.InvalidLine, countColumnsInLine(text, 7));

    const text2 = "a dog";
    try expectEqual(
        ColumnCount{ .unfinished_count = .{ .columns = 5, .codepoints_until_line = 0 } }, 
        try countColumnsInLine(text2, 0));

    const text3 = "the cat";
    try expectEqual(
        ColumnCount{ .unfinished_count = .{ .columns = 7, .codepoints_until_line = 0 } }, 
        try countColumnsInLine(text3, 0));
}

test "clampPosition" {
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
        const pos = pt.clampPosition(-1, 0);
        try expectEqual(@as(?Position, null), pos);
    }
    {
        const pos = pt.clampPosition(0, 0) orelse unreachable;
        try expectEqual(Position{ .line = 0, .col = 0, .offset = 0 }, pos);
    }
    {
        const pos = pt.clampPosition(0, 32) orelse unreachable;
        try expectEqual(Position{ .line = 0, .col = 31, .offset = 31 }, pos);
    }
    {
        const pos = pt.clampPosition(1, 0) orelse unreachable;
        try expectEqual(Position{ .line = 1, .col = 0, .offset = 33 }, pos);
    }
    {
        const pos = pt.clampPosition(2, 4) orelse unreachable;
        try expectEqual(Position{ .line = 2, .col = 0, .offset = 59 }, pos);
    }
}

test "clampPosition with inserts" {
    const expectEqual = std.testing.expectEqual;

    const str = "the cat";

    var pt = try PieceTable.initFromString(std.testing.allocator, str);
    defer pt.deinit();

    try pt.insert(0, "a");
    try assertPieceTableContents(&pt, "athe cat");

    {
        const pos = pt.clampPosition(0, 7) orelse unreachable;
        try expectEqual(Position{ .line = 0, .col = 7, .offset = 7 }, pos);
    }

    try pt.insert(0, "a");
    try assertPieceTableContents(&pt, "aathe cat");

    {
        const pos = pt.clampPosition(0, 7) orelse unreachable;
        try expectEqual(Position{ .line = 0, .col = 7, .offset = 7 }, pos);
    }
    {
        const pos = pt.clampPosition(0, 8) orelse unreachable;
        try expectEqual(Position{ .line = 0, .col = 8, .offset = 8 }, pos);
    }
    {
        const pos = pt.clampPosition(0, 9) orelse unreachable;
        try expectEqual(Position{ .line = 0, .col = 8, .offset = 8 }, pos);
    }
}

test "toString" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    const allocator = std.testing.allocator;

    var cwd = std.fs.cwd();
    var file = try cwd.openFile("fixtures/main.zig", .{ .read = true });
    defer file.close();

    const str = "random\nstring buffer.\naaaa\n\n";

    var pt = try PieceTable.initFromString(allocator, str);
    defer pt.deinit();

    {
        const s = try pt.toString(allocator, 0);
        defer allocator.free(s);
        try expectEqualStrings("random\nstring buffer.\naaaa\n\n", s);
    }
    {
        const s = try pt.toString(allocator, 1);
        defer allocator.free(s);
        try expectEqualStrings("string buffer.\naaaa\n\n", s);
    }
    {
        const s = try pt.toString(allocator, 2);
        defer allocator.free(s);
        try expectEqualStrings("aaaa\n\n", s);
    }
    {
        const s = try pt.toString(allocator, 3);
        defer allocator.free(s);
        try expectEqualStrings("\n", s);
    }
    {
        const s = try pt.toString(allocator, 4);
        defer if (s.len > 0) allocator.free(s);
        try expectEqualStrings("", s);
    }
}
