const std = @import("std");

var g_file: std.fs.File = undefined;

pub fn init() !void {
    const cwd = std.fs.cwd();
    g_file = try cwd.createFile("LOG.txt", .{.truncate = true});
}

pub fn deinit() void {
    g_file.close();
}

pub fn debug(string: []const u8) void {
    debugf("{s}", .{string});
}

pub fn info(string: []const u8) void {
    infof("{s}", .{string});
}

pub fn err(string: []const u8) void {
    errf("{s}", .{string});
}

pub fn debugf(comptime fmt: []const u8, args: anytype) void {
    _ = g_file.writer().print("[DEBU] " ++ fmt ++ "\n", args) catch unreachable;
}

pub fn infof(comptime fmt: []const u8, args: anytype) void {
    _ = g_file.writer().print("[INFO] " ++ fmt ++ "\n", args) catch unreachable;
}

pub fn errf(comptime fmt: []const u8, args: anytype) void {
    _ = g_file.writer().print("[ERRO] " ++ fmt ++ "\n", args) catch unreachable;
}
