const std = @import("std");
const c = @import("c.zig");

const Log = @import("log.zig").Log;
const Output = @import("output.zig").Output;
const Seat = @import("seat.zig").Seat;
const View = @import("view.zig").View;
const ViewStack = @import("view_stack.zig").ViewStack;

pub const Arg = union {
    int: i32,
    uint: u32,
    float: f64,
    str: []const u8,
    none: void,
};

pub const Command = fn (seat: *Seat, arg: Arg) void;

/// Exit the compositor, terminating the wayland session.
pub fn exitCompositor(seat: *Seat, arg: Arg) void {
    c.wl_display_terminate(seat.input_manager.server.wl_display);
}

/// Focus either the next or the previous visible view, depending on the bool
/// passed.
fn focusNextPrevView(seat: *Seat, next: bool) void {
    const output = seat.focused_output;
    if (seat.focused_view) |current_focus| {
        // If there is a currently focused view, focus the next visible view in the stack.
        const focused_node = @fieldParentPtr(ViewStack(View).Node, "view", current_focus);
        var it = if (next)
            ViewStack(View).iterator(focused_node, output.current_focused_tags)
        else
            ViewStack(View).reverseIterator(focused_node, output.current_focused_tags);

        // Skip past the focused node
        _ = it.next();
        // Focus the next visible node if there is one
        if (it.next()) |node| {
            seat.focus(&node.view);
            return;
        }
    }

    // There is either no currently focused view or the last visible view in the
    // stack is focused and we need to wrap.
    var it = if (next)
        ViewStack(View).iterator(output.views.first, output.current_focused_tags)
    else
        ViewStack(View).reverseIterator(output.views.last, output.current_focused_tags);
    seat.focus(if (it.next()) |node| &node.view else null);
}

/// Focus the next visible view in the stack, wrapping if needed. Does
/// nothing if there is only one view in the stack.
pub fn focusNextView(seat: *Seat, arg: Arg) void {
    focusNextPrevView(seat, true);
}

/// Focus the previous view in the stack, wrapping if needed. Does nothing
/// if there is only one view in the stack.
pub fn focusPrevView(seat: *Seat, arg: Arg) void {
    focusNextPrevView(seat, false);
}

/// Focus either the next or the previous output, depending on the bool passed.
fn focusNextPrevOutput(seat: *Seat, next: bool) void {
    const root = &seat.input_manager.server.root;
    // If the noop output is focused, there are no other outputs to switch to
    if (seat.focused_output == &root.noop_output) {
        std.debug.assert(root.outputs.len == 0);
        return;
    }

    const focused_node = @fieldParentPtr(std.TailQueue(Output).Node, "data", seat.focused_output);
    seat.focused_output = if (if (next) focused_node.next else focused_node.prev) |output_node|
    // Focus the next/prev output in the list if there is one
        &output_node.data
    else if (next) &root.outputs.first.?.data else &root.outputs.last.?.data;

    seat.focus(null);
}

/// Focus the next output, wrapping if needed. Does nothing if there is
/// only one output.
pub fn focusNextOutput(seat: *Seat, arg: Arg) void {
    focusNextPrevOutput(seat, true);
}

/// Focus the previous output, wrapping if needed. Does nothing if there is
/// only one output.
pub fn focusPrevOutput(seat: *Seat, arg: Arg) void {
    focusNextPrevOutput(seat, false);
}

/// Modify the number of master views
pub fn modifyMasterCount(seat: *Seat, arg: Arg) void {
    const delta = arg.int;
    const output = seat.focused_output;
    output.master_count = @intCast(
        u32,
        std.math.max(0, @intCast(i32, output.master_count) + delta),
    );
    seat.input_manager.server.root.arrange();
}

/// Modify the percent of the width of the screen that the master views occupy.
pub fn modifyMasterFactor(seat: *Seat, arg: Arg) void {
    const delta = arg.float;
    const output = seat.focused_output;
    const new_master_factor = std.math.min(
        std.math.max(output.master_factor + delta, 0.05),
        0.95,
    );
    if (new_master_factor != output.master_factor) {
        output.master_factor = new_master_factor;
        seat.input_manager.server.root.arrange();
    }
}

/// Bump the focused view to the top of the stack.
/// TODO: if the top of the stack is focused, bump the next visible view.
pub fn zoom(seat: *Seat, arg: Arg) void {
    if (seat.focused_view) |current_focus| {
        const output = seat.focused_output;
        const node = @fieldParentPtr(ViewStack(View).Node, "view", current_focus);
        if (node != output.views.first) {
            output.views.remove(node);
            output.views.push(node);
            seat.input_manager.server.root.arrange();
        }
    }
}

/// Switch focus to the passed tags.
pub fn focusTags(seat: *Seat, arg: Arg) void {
    const tags = arg.uint;
    seat.focused_output.pending_focused_tags = tags;
    seat.input_manager.server.root.arrange();
}

/// Toggle focus of the passsed tags.
pub fn toggleTags(seat: *Seat, arg: Arg) void {
    const tags = arg.uint;
    const output = seat.focused_output;
    const new_focused_tags = output.current_focused_tags ^ tags;
    if (new_focused_tags != 0) {
        output.pending_focused_tags = new_focused_tags;
        seat.input_manager.server.root.arrange();
    }
}

/// Set the tags of the focused view.
pub fn setFocusedViewTags(seat: *Seat, arg: Arg) void {
    const tags = arg.uint;
    if (seat.focused_view) |view| {
        if (view.current_tags != tags) {
            view.pending_tags = tags;
            seat.input_manager.server.root.arrange();
        }
    }
}

/// Toggle the passed tags of the focused view
pub fn toggleFocusedViewTags(seat: *Seat, arg: Arg) void {
    const tags = arg.uint;
    if (seat.focused_view) |view| {
        const new_tags = view.current_tags ^ tags;
        if (new_tags != 0) {
            view.pending_tags = new_tags;
            seat.input_manager.server.root.arrange();
        }
    }
}

/// Spawn a program.
pub fn spawn(seat: *Seat, arg: Arg) void {
    const cmd = arg.str;

    const argv = [_][]const u8{ "/bin/sh", "-c", cmd };
    const child = std.ChildProcess.init(&argv, std.heap.c_allocator) catch |err| {
        Log.Error.log("Failed to execute {}: {}", .{ cmd, err });
        return;
    };
    std.ChildProcess.spawn(child) catch |err| {
        Log.Error.log("Failed to execute {}: {}", .{ cmd, err });
        return;
    };
}

/// Close the focused view, if any.
pub fn close(seat: *Seat, arg: Arg) void {
    if (seat.focused_view) |view| {
        view.close();
    }
}