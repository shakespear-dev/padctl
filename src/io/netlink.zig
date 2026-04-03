const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub fn openNetlinkUevent() !posix.fd_t {
    const fd = try posix.socket(linux.AF.NETLINK, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, linux.NETLINK.KOBJECT_UEVENT);
    errdefer posix.close(fd);
    // Group 2 = udev-processed events (device node ready); group 1 = raw kernel events.
    const addr2 = linux.sockaddr.nl{ .pid = 0, .groups = 2 };
    posix.bind(fd, @ptrCast(&addr2), @sizeOf(linux.sockaddr.nl)) catch {
        const addr1 = linux.sockaddr.nl{ .pid = 0, .groups = 1 };
        try posix.bind(fd, @ptrCast(&addr1), @sizeOf(linux.sockaddr.nl));
        std.log.warn("netlink: udev group unavailable, falling back to kernel group", .{});
    };
    return fd;
}

pub const UeventAction = enum { add, remove, other };

pub const Uevent = struct {
    action: UeventAction,
    devname: ?[]const u8,
    subsystem: ?[]const u8,
};

const libudev_magic = "libudev\x00";

/// Parse a uevent message buffer (group 1 or group 2/udev format).
/// Group 2 messages start with a 40-byte libudev header; properties_off (u32 LE at offset 16)
/// gives the byte offset to the null-delimited KEY=val section.
/// Group 1 format: "action@path\0KEY=val\0KEY=val\0..."
pub fn parseUevent(buf: []const u8) Uevent {
    var action: UeventAction = .other;
    var devname: ?[]const u8 = null;
    var subsystem: ?[]const u8 = null;

    const payload: []const u8 = if (std.mem.startsWith(u8, buf, libudev_magic) and buf.len >= 20) blk: {
        const off = std.mem.readInt(u32, buf[16..20], .little);
        break :blk if (off < buf.len) buf[off..] else return .{ .action = .other, .devname = null, .subsystem = null };
    } else buf;

    var it = std.mem.splitScalar(u8, payload, 0);

    // Group 1: first token is "action@path"; group 2: first token is also "action@path".
    if (it.next()) |header| {
        if (std.mem.startsWith(u8, header, "add@")) {
            action = .add;
        } else if (std.mem.startsWith(u8, header, "remove@")) {
            action = .remove;
        }
    }

    while (it.next()) |kv| {
        if (kv.len == 0) continue;
        if (std.mem.startsWith(u8, kv, "DEVNAME=")) {
            devname = kv["DEVNAME=".len..];
        } else if (std.mem.startsWith(u8, kv, "SUBSYSTEM=")) {
            subsystem = kv["SUBSYSTEM=".len..];
        }
    }

    return .{ .action = action, .devname = devname, .subsystem = subsystem };
}

/// Drain all pending uevent messages from fd, calling callback for each hidraw add/remove.
/// Stops when recv returns WouldBlock (EAGAIN).
pub fn drainNetlink(fd: posix.fd_t, ctx: anytype, comptime callback: fn (@TypeOf(ctx), UeventAction, []const u8) void) void {
    var buf: [2048]u8 = undefined;
    while (true) {
        const n = posix.recv(fd, &buf, 0) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return,
        };
        if (n == 0) return;
        const ev = parseUevent(buf[0..n]);
        if (ev.action == .other) continue;
        const sub = ev.subsystem orelse continue;
        if (!std.mem.eql(u8, sub, "hidraw")) continue;
        const name = ev.devname orelse continue;
        callback(ctx, ev.action, name);
    }
}

// --- tests ---

const testing = std.testing;

test "parseUevent: add hidraw" {
    const msg = "add@/devices/platform/hidraw/hidraw3\x00SUBSYSTEM=hidraw\x00DEVNAME=hidraw3\x00";
    const ev = parseUevent(msg);
    try testing.expectEqual(UeventAction.add, ev.action);
    try testing.expectEqualStrings("hidraw3", ev.devname.?);
    try testing.expectEqualStrings("hidraw", ev.subsystem.?);
}

test "parseUevent: remove hidraw" {
    const msg = "remove@/devices/platform/hidraw/hidraw3\x00SUBSYSTEM=hidraw\x00DEVNAME=hidraw3\x00";
    const ev = parseUevent(msg);
    try testing.expectEqual(UeventAction.remove, ev.action);
    try testing.expectEqualStrings("hidraw3", ev.devname.?);
}

test "parseUevent: non-hidraw subsystem" {
    const msg = "add@/devices/usb/usb1\x00SUBSYSTEM=usb\x00DEVNAME=usb1\x00";
    const ev = parseUevent(msg);
    try testing.expectEqual(UeventAction.add, ev.action);
    try testing.expectEqualStrings("usb", ev.subsystem.?);
}

test "parseUevent: other action" {
    const msg = "change@/devices/platform/hidraw/hidraw3\x00SUBSYSTEM=hidraw\x00DEVNAME=hidraw3\x00";
    const ev = parseUevent(msg);
    try testing.expectEqual(UeventAction.other, ev.action);
}

test "parseUevent: missing DEVNAME" {
    const msg = "add@/devices/platform/hidraw/hidraw3\x00SUBSYSTEM=hidraw\x00";
    const ev = parseUevent(msg);
    try testing.expectEqual(UeventAction.add, ev.action);
    try testing.expect(ev.devname == null);
    try testing.expectEqualStrings("hidraw", ev.subsystem.?);
}

test "parseUevent: group 2 libudev header" {
    // Minimal libudev header: 40 bytes, properties_off = 40.
    var msg: [40 + 80]u8 = undefined;
    @memset(&msg, 0);
    @memcpy(msg[0..8], "libudev\x00");
    // magic at bytes 8-11 (not validated by parseUevent)
    std.mem.writeInt(u32, msg[8..12], 0xfeedcafe, .little);
    // header_size at 12-15
    std.mem.writeInt(u32, msg[12..16], 40, .little);
    // properties_off at 16-19
    std.mem.writeInt(u32, msg[16..20], 40, .little);
    // properties_len at 20-23
    std.mem.writeInt(u32, msg[20..24], 64, .little);
    // payload at offset 40: "add@path\0SUBSYSTEM=hidraw\0DEVNAME=hidraw5\0"
    const payload = "add@/devices/platform/hidraw/hidraw5\x00SUBSYSTEM=hidraw\x00DEVNAME=hidraw5\x00";
    @memcpy(msg[40..][0..payload.len], payload);
    const ev = parseUevent(&msg);
    try testing.expectEqual(UeventAction.add, ev.action);
    try testing.expectEqualStrings("hidraw5", ev.devname.?);
    try testing.expectEqualStrings("hidraw", ev.subsystem.?);
}
