const std = @import("std");
const analyse = @import("analyse");

pub const DeviceInfo = struct {
    name: []const u8,
    vid: u16,
    pid: u16,
    interface_id: u8,
};

pub fn emitToml(result: analyse.AnalysisResult, info: DeviceInfo, allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.print(
        \\[device]
        \\name = "{s}"
        \\vid = 0x{x:0>4}
        \\pid = 0x{x:0>4}
        \\
        \\[[device.interface]]
        \\id = {d}
        \\class = "hid"
        \\
        \\[[report]]
        \\name = "main"
        \\interface = {d}
        \\size = {d}
        \\
    ,
        .{ info.name, info.vid, info.pid, info.interface_id, info.interface_id, result.report_size },
    );

    // match section if we have magic bytes
    if (result.magic.len > 0) {
        try writer.writeAll("[report.match]\n");
        try writer.print("offset = {d}\n", .{result.magic[0].offset});
        try writer.writeAll("expect = [");
        for (result.magic, 0..) |m, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("0x{x:0>2}", .{m.value});
        }
        try writer.writeAll("]\n\n");
    }

    // fields section for axes
    if (result.axes.len > 0) {
        try writer.writeAll("[report.fields]\n");
        for (result.axes, 0..) |ax, i| {
            switch (ax.axis_type) {
                .i16le => try writer.print(
                    "axis_{d} = {{ offset = {d}, type = \"i16le\" }}\n",
                    .{ i, ax.offset },
                ),
                .u8_axis => try writer.print(
                    "axis_{d} = {{ offset = {d}, type = \"u8\" }}\n",
                    .{ i, ax.offset },
                ),
            }
        }
        try writer.writeAll("\n");
    }

    // button_group section
    if (result.buttons.len > 0) {
        // group consecutive high-confidence bits by byte
        const first = result.buttons[0];
        try writer.writeAll("[report.button_group]\n");
        try writer.print("source = {{ offset = {d}, size = 1 }}\n", .{first.byte_offset});
        try writer.writeAll("map = {");
        var first_entry = true;
        for (result.buttons) |btn| {
            if (!btn.high_confidence) continue;
            if (!first_entry) try writer.writeAll(", ");
            try writer.print(" btn_{d}_{d} = {d}", .{ btn.byte_offset, btn.bit, btn.bit });
            first_entry = false;
        }
        try writer.writeAll(" }\n\n");
    }

    // unknown bytes comment
    const size: usize = result.report_size;
    var covered = try allocator.alloc(bool, size);
    defer allocator.free(covered);
    @memset(covered, false);

    for (result.magic) |m| {
        if (m.offset < size) covered[m.offset] = true;
    }
    for (result.axes) |ax| {
        if (ax.offset < size) covered[ax.offset] = true;
        if (ax.axis_type == .i16le and ax.offset + 1 < size) covered[ax.offset + 1] = true;
    }
    for (result.buttons) |btn| {
        if (btn.byte_offset < size) covered[btn.byte_offset] = true;
    }

    for (0..size) |b| {
        if (!covered[b]) try writer.print("# unknown: offset {d}\n", .{b});
    }
}
