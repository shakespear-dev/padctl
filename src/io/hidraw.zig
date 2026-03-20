const std = @import("std");
const io = @import("device_io.zig");

pub const DeviceIO = io.DeviceIO;

pub const HidrawDevice = struct {
    fd: std.posix.fd_t,

    pub fn deviceIO(self: *HidrawDevice) DeviceIO {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = DeviceIO.VTable{
        .read = read,
        .write = write,
        .pollfd = pollfd,
        .close = close,
    };

    fn read(ptr: *anyopaque, buf: []u8) DeviceIO.ReadError!usize {
        _ = ptr;
        _ = buf;
        return DeviceIO.ReadError.Again;
    }

    fn write(ptr: *anyopaque, data: []const u8) DeviceIO.WriteError!void {
        _ = ptr;
        _ = data;
    }

    fn pollfd(ptr: *anyopaque) std.posix.pollfd {
        const self: *HidrawDevice = @ptrCast(@alignCast(ptr));
        return .{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 };
    }

    fn close(ptr: *anyopaque) void {
        const self: *HidrawDevice = @ptrCast(@alignCast(ptr));
        std.posix.close(self.fd);
    }
};
