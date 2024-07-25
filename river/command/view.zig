const std = @import("std");

const server = &@import("../main.zig").server;
const util = @import("../util.zig");

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

pub fn listViews(_: *Seat, _: []const [:0]const u8, out: *?[]const u8) Error!void {
    var buffer = std.ArrayList(u8).init(util.gpa);
    const writer = buffer.writer();

    var list = std.ArrayList(struct { id: []const u8, title: []const u8 }).init(util.gpa);

    var it = server.root.views.iterator(.forward);
    var maxIdSize: usize = 10;
    var maxTitleSize: usize = 10;
    while (it.next()) |view| {
        var id = std.mem.span(view.getAppId()) orelse "";
        var title = std.mem.span(view.getTitle()) orelse "";

        try list.append(.{ .id = id, .title = title });
        if (id.len > maxIdSize) maxIdSize = id.len;
        if (title.len > maxTitleSize) maxTitleSize = title.len;
    }

    maxIdSize += 1;
    maxTitleSize += 1;

    try std.fmt.formatBuf("app-id", .{ .width = maxIdSize, .alignment = .Left }, writer);
    try std.fmt.formatBuf("title", .{ .width = maxTitleSize, .alignment = .Left }, writer);
    for (list.items) |ele| {
        try writer.print("\n", .{});
        try std.fmt.formatBuf(ele.id, .{ .width = maxIdSize, .alignment = .Left }, writer);
        try std.fmt.formatBuf(ele.title, .{ .width = maxTitleSize, .alignment = .Left }, writer);
    }

    out.* = buffer.toOwnedSlice();
}
