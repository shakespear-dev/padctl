const state = @import("../core/state.zig");

pub const OutputDevice = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        emit: *const fn (ptr: *anyopaque, s: state.GamepadState) void,
        poll_ff: *const fn (ptr: *anyopaque) void,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn emit(self: OutputDevice, s: state.GamepadState) void {
        self.vtable.emit(self.ptr, s);
    }

    pub fn pollFf(self: OutputDevice) void {
        self.vtable.poll_ff(self.ptr);
    }

    pub fn close(self: OutputDevice) void {
        self.vtable.close(self.ptr);
    }
};

pub const UinputDevice = struct {
    pub fn outputDevice(self: *UinputDevice) OutputDevice {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = OutputDevice.VTable{
        .emit = emit,
        .poll_ff = pollFf,
        .close = close,
    };

    fn emit(ptr: *anyopaque, s: state.GamepadState) void {
        _ = ptr;
        _ = s;
    }

    fn pollFf(ptr: *anyopaque) void {
        _ = ptr;
    }

    fn close(ptr: *anyopaque) void {
        _ = ptr;
    }
};
