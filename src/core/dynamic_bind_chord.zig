const std = @import("std");
const ButtonId = @import("state.zig").ButtonId;

pub const Config = struct {
    modifier_mask: u64,
    hold_ns: u64,
    blocked_mask: u64 = 0,
};

pub const Result = struct {
    fired_button: ?ButtonId = null,
    was_self_bind: bool = false,
    suppress_mask: u64 = 0,
};

pub const Detector = struct {
    cfg: Config,
    modifier_first_held_ns: ?u64 = null,
    last_fired_id: ?ButtonId = null,

    pub fn init(cfg: Config) Detector {
        return .{ .cfg = cfg };
    }

    pub fn step(self: *Detector, buttons: u64, prev: u64, now_ns: u64) Result {
        const modifier_held = (buttons & self.cfg.modifier_mask) == self.cfg.modifier_mask;
        if (!modifier_held) {
            self.modifier_first_held_ns = null;
            self.last_fired_id = null;
            return .{};
        }
        if (self.modifier_first_held_ns == null) self.modifier_first_held_ns = now_ns;

        // Suppress every non-modifier button currently held while the
        // modifier is held — the chord is in flight and we don't want
        // bind-target presses to leak to the game.
        const suppress = buttons & ~self.cfg.modifier_mask;

        const elapsed = now_ns - self.modifier_first_held_ns.?;
        if (elapsed < self.cfg.hold_ns) return .{ .suppress_mask = suppress };

        const newly_pressed = buttons & ~prev & ~self.cfg.modifier_mask;
        if (newly_pressed == 0) return .{ .suppress_mask = suppress };

        const bit_pos: u6 = @intCast(@ctz(newly_pressed));
        const button: ButtonId = @enumFromInt(bit_pos);

        // Re-fire guard: same button must release modifier before firing again.
        if (self.last_fired_id) |last| {
            if (last == button) return .{ .suppress_mask = suppress };
        }
        self.last_fired_id = button;

        const button_bit = @as(u64, 1) << bit_pos;
        return .{
            .fired_button = button,
            .was_self_bind = (button_bit & self.cfg.blocked_mask) != 0,
            .suppress_mask = suppress,
        };
    }
};

const testing = std.testing;

fn bit(id: ButtonId) u64 {
    return @as(u64, 1) << @intFromEnum(id);
}

test "any-button chord: modifier held + RT pressed after debounce → fires RT" {
    var d = Detector.init(.{
        .modifier_mask = bit(.M1),
        .hold_ns = 80 * std.time.ns_per_ms,
        .blocked_mask = 0,
    });

    // Hold modifier at t=0
    _ = d.step(bit(.M1), 0, 0);
    // After 100ms (past 80ms debounce), press RT while modifier still held
    const r = d.step(bit(.M1) | bit(.RT), bit(.M1), 100 * std.time.ns_per_ms);
    try testing.expectEqual(@as(?ButtonId, .RT), r.fired_button);
    try testing.expect(!r.was_self_bind);
}

test "any-button chord: modifier+RT held → RT in suppress_mask (game doesn't see bind press)" {
    var d = Detector.init(.{
        .modifier_mask = bit(.M1),
        .hold_ns = 80 * std.time.ns_per_ms,
        .blocked_mask = 0,
    });

    // Hold modifier + RT simultaneously from t=0
    const r = d.step(bit(.M1) | bit(.RT), 0, 0);
    try testing.expect((r.suppress_mask & bit(.RT)) != 0);
    // Modifier itself is not in suppress_mask — it's the chord trigger,
    // not a binding target.
    try testing.expectEqual(@as(u64, 0), r.suppress_mask & bit(.M1));
}

test "any-button chord: blocked button (e.g. layer's static trigger) → was_self_bind=true" {
    var d = Detector.init(.{
        .modifier_mask = bit(.M1),
        .hold_ns = 80 * std.time.ns_per_ms,
        .blocked_mask = bit(.LM), // simulate aim layer's static trigger = LM
    });

    _ = d.step(bit(.M1), 0, 0);
    const r = d.step(bit(.M1) | bit(.LM), bit(.M1), 100 * std.time.ns_per_ms);
    try testing.expectEqual(@as(?ButtonId, .LM), r.fired_button);
    try testing.expect(r.was_self_bind);
}

test "any-button chord: re-fire guard — same button held → fires once" {
    var d = Detector.init(.{
        .modifier_mask = bit(.M1),
        .hold_ns = 80 * std.time.ns_per_ms,
        .blocked_mask = 0,
    });

    _ = d.step(bit(.M1), 0, 0);
    // First press of RT → fires
    const r1 = d.step(bit(.M1) | bit(.RT), bit(.M1), 100 * std.time.ns_per_ms);
    try testing.expectEqual(@as(?ButtonId, .RT), r1.fired_button);

    // RT released
    _ = d.step(bit(.M1), bit(.M1) | bit(.RT), 110 * std.time.ns_per_ms);
    // RT pressed again WITHOUT modifier release → must NOT fire
    const r2 = d.step(bit(.M1) | bit(.RT), bit(.M1), 120 * std.time.ns_per_ms);
    try testing.expectEqual(@as(?ButtonId, null), r2.fired_button);
}
