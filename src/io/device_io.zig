const std = @import("std");

pub const DeviceIO = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (ptr: *anyopaque, buf: []u8) ReadError!usize,
        write: *const fn (ptr: *anyopaque, data: []const u8) WriteError!void,
        pollfd: *const fn (ptr: *anyopaque) std.posix.pollfd,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub const ReadError = error{ Again, Disconnected, Io };
    pub const WriteError = error{ Disconnected, Io };

    pub fn read(self: DeviceIO, buf: []u8) ReadError!usize {
        return self.vtable.read(self.ptr, buf);
    }

    pub fn write(self: DeviceIO, data: []const u8) WriteError!void {
        return self.vtable.write(self.ptr, data);
    }

    pub fn pollfd(self: DeviceIO) std.posix.pollfd {
        return self.vtable.pollfd(self.ptr);
    }

    pub fn close(self: DeviceIO) void {
        self.vtable.close(self.ptr);
    }
};
