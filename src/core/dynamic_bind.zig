const std = @import("std");
const ButtonId = @import("state.zig").ButtonId;

pub const BindAction = enum {
    bound,
    unbound,
    replaced,
    rejected_self,
};

/// One-shot event the mapper emits to OutputEvents whenever the chord
/// detector triggers a state-machine action. Consumers (event_loop,
/// supervisor) dispatch to rumble / journalctl / control socket / dump log.
pub const DynamicBindEvent = struct {
    action: BindAction,
    layer_name: []const u8,
    button: ButtonId,
};

/// Tactile feedback for a dynamic-bind action. The mapper sets this on
/// `OutputEvents.feedback_rumble` when an action fires; the event loop
/// emits a rumble HID frame and schedules a stop after `duration_ms`.
pub const FeedbackRumble = struct {
    strong: u16,
    weak: u16,
    duration_ms: u16,
};

/// Maps a BindAction to its tactile pulse. Distinct shapes so the user can
/// tell bind/unbind/replace/reject apart by feel without looking at a screen.
pub fn rumbleForAction(action: BindAction) FeedbackRumble {
    return switch (action) {
        .bound => .{ .strong = 0xC000, .weak = 0, .duration_ms = 80 },
        .replaced => .{ .strong = 0xC000, .weak = 0, .duration_ms = 80 },
        .unbound => .{ .strong = 0x6000, .weak = 0, .duration_ms = 140 },
        .rejected_self => .{ .strong = 0, .weak = 0xA000, .duration_ms = 90 },
    };
}

pub const DynamicBindState = struct {
    runtime: ?ButtonId = null,

    pub fn init() DynamicBindState {
        return .{};
    }

    pub fn getRuntimeTrigger(self: *const DynamicBindState) ?ButtonId {
        return self.runtime;
    }

    pub fn processChordEvent(self: *DynamicBindState, button: ButtonId, was_self_bind: bool) BindAction {
        if (was_self_bind) return .rejected_self;
        if (self.runtime) |current| {
            if (current == button) {
                self.runtime = null;
                return .unbound;
            }
            self.runtime = button;
            return .replaced;
        }
        self.runtime = button;
        return .bound;
    }

    pub fn clear(self: *DynamicBindState) void {
        self.runtime = null;
    }
};

const testing = std.testing;

test "dynamic_bind: empty state → bind to RT sets runtime trigger" {
    var state = DynamicBindState.init();
    try testing.expectEqual(@as(?ButtonId, null), state.getRuntimeTrigger());

    const action = state.processChordEvent(.RT, false);
    try testing.expectEqual(BindAction.bound, action);
    try testing.expectEqual(@as(?ButtonId, .RT), state.getRuntimeTrigger());
}

test "dynamic_bind: bind same button again → unbound (toggle off)" {
    var state = DynamicBindState.init();
    _ = state.processChordEvent(.RT, false);

    const action = state.processChordEvent(.RT, false);
    try testing.expectEqual(BindAction.unbound, action);
    try testing.expectEqual(@as(?ButtonId, null), state.getRuntimeTrigger());
}

test "dynamic_bind: bind different button → replaced (auto-clear old)" {
    var state = DynamicBindState.init();
    _ = state.processChordEvent(.RT, false);

    const action = state.processChordEvent(.LT, false);
    try testing.expectEqual(BindAction.replaced, action);
    try testing.expectEqual(@as(?ButtonId, .LT), state.getRuntimeTrigger());
}

test "dynamic_bind: was_self_bind=true → rejected, state unchanged" {
    var state = DynamicBindState.init();
    _ = state.processChordEvent(.RT, false);

    // Caller indicates this would have been a self-bind (modifier or static
    // trigger) — state machine must reject and leave the existing binding.
    const action = state.processChordEvent(.LM, true);
    try testing.expectEqual(BindAction.rejected_self, action);
    try testing.expectEqual(@as(?ButtonId, .RT), state.getRuntimeTrigger());
}

test "dynamic_bind: was_self_bind=true on empty state → rejected, still empty" {
    var state = DynamicBindState.init();

    const action = state.processChordEvent(.LM, true);
    try testing.expectEqual(BindAction.rejected_self, action);
    try testing.expectEqual(@as(?ButtonId, null), state.getRuntimeTrigger());
}

test "dynamic_bind: clear from bound state → empty" {
    var state = DynamicBindState.init();
    _ = state.processChordEvent(.RT, false);

    state.clear();
    try testing.expectEqual(@as(?ButtonId, null), state.getRuntimeTrigger());
}

test "dynamic_bind: clear on empty state → still empty (idempotent)" {
    var state = DynamicBindState.init();
    state.clear();
    try testing.expectEqual(@as(?ButtonId, null), state.getRuntimeTrigger());
}
