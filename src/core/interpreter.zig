const state = @import("state.zig");

pub const GamepadStateDelta = state.GamepadStateDelta;

pub fn processReport(interface_id: u8, raw: []const u8) ?GamepadStateDelta {
    _ = interface_id;
    _ = raw;
    return null;
}
