const std = @import("std");

const state = @import("../core/state.zig");
const uinput = @import("../io/uinput.zig");

pub const GamepadState = state.GamepadState;
pub const GamepadStateDelta = state.GamepadStateDelta;

pub const MockOutput = struct {
    allocator: std.mem.Allocator,
    emitted: std.ArrayList(GamepadState),
    diffs: std.ArrayList(GamepadStateDelta),
    prev: GamepadState = .{},

    pub fn init(allocator: std.mem.Allocator) MockOutput {
        return .{ .allocator = allocator, .emitted = .{}, .diffs = .{} };
    }

    pub fn deinit(self: *MockOutput) void {
        self.emitted.deinit(self.allocator);
        self.diffs.deinit(self.allocator);
    }

    pub fn outputDevice(self: *MockOutput) uinput.OutputDevice {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = uinput.OutputDevice.VTable{
        .emit = mockEmit,
        .poll_ff = mockPollFf,
        .close = mockClose,
    };

    fn mockEmit(ptr: *anyopaque, s: GamepadState) anyerror!void {
        const self: *MockOutput = @ptrCast(@alignCast(ptr));
        try self.diffs.append(self.allocator, s.diff(self.prev));
        try self.emitted.append(self.allocator, s);
        self.prev = s;
    }

    fn mockPollFf(_: *anyopaque) anyerror!?uinput.FfEvent {
        return null;
    }

    fn mockClose(_: *anyopaque) void {}
};
