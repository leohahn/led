const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("./buffer.zig").Buffer;
const PieceTable = @import("./piece_table.zig").PieceTable;
const ref = @import("./ref.zig");

pub const EditorResources = struct {
    allocator: Allocator,
    buffers: std.ArrayListUnmanaged(Buffer),
    tables: std.ArrayListUnmanaged(PieceTable),

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        const buffers = try std.ArrayListUnmanaged(Buffer).initCapacity(allocator, 10);
        const tables = try std.ArrayListUnmanaged(PieceTable).initCapacity(allocator, 10);
        return Self{
            .allocator = allocator,
            .buffers = buffers,
            .tables = tables,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffers.deinit(self.allocator);

        for (self.tables.items) |*table| {
            table.deinit();
        }
        self.tables.deinit(self.allocator);
    }

    pub fn createTableFromFile(self: *Self, file: std.fs.File) !ref.TableHandle {
        var pt = try PieceTable.initFromFile(self.allocator, file);
        try self.tables.append(self.allocator, pt);
        return ref.TableHandle{ .val = @intCast(u32, self.tables.items.len) - 1 };
    }

    pub fn createTableFromString(self: *Self, string: []const u8) !ref.TableHandle {
        var pt = try PieceTable.initFromString(self.allocator, string);
        try self.tables.append(self.allocator, pt);
        return ref.TableHandle{
            .val = @intCast(u32, self.tables.items.len) - 1,
        };
    }

    pub fn createBuffer(self: *Self, table_handle: ref.TableHandle) !ref.BufferHandle {
        const buffer = Buffer.init(table_handle);
        try self.buffers.append(self.allocator, buffer);
        return ref.BufferHandle{ .val = @intCast(u32, self.buffers.items.len) - 1 };
    }

    pub fn getTable(self: *const Self, th: ref.TableHandle) *PieceTable {
        return &self.tables.items[th.val];
    }

    pub fn getBuffer(self: *const Self, bh: ref.BufferHandle) *Buffer {
        return &self.buffers.items[bh.val];
    }
};
