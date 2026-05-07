const std = @import("std");

pub const Edge = enum {
    none,
    press,
    release,
};

pub const Direction = enum {
    above,
    below,
};

pub const Input = struct {
    prev: u8,
    current: u8,
    threshold: u8,
    direction: Direction,
    release_threshold: u8,
};

pub fn detect(in: Input) Edge {
    switch (in.direction) {
        .above => {
            // Press edge: was below threshold, now at or above threshold.
            if (in.prev < in.threshold and in.current >= in.threshold) return .press;
            // Release edge: was at or above release_threshold, now below it.
            // Hysteresis: prev between release_threshold and threshold counts
            // as "still active" — no release until value falls below release.
            if (in.prev >= in.release_threshold and in.current < in.release_threshold) return .release;
            return .none;
        },
        .below => {
            // "Below" semantics: a light press (value in (0, threshold))
            // activates the layer. Resting (value == 0) and hard pressing
            // (value >= threshold) leave it inactive.
            const was_inactive = in.prev == 0 or in.prev >= in.threshold;
            const is_active = in.current > 0 and in.current < in.threshold;
            if (was_inactive and is_active) return .press;

            // Release: was active, now either fully lifted (current == 0)
            // or pressed past release_threshold (hysteresis above the
            // active band).
            const was_active = in.prev > 0 and in.prev < in.threshold;
            const is_inactive = in.current == 0 or in.current >= in.release_threshold;
            if (was_active and is_inactive) return .release;
            return .none;
        },
    }
}

const testing = std.testing;

test "analog_edge: direction=above, value crosses threshold from below → press" {
    const e = detect(.{
        .prev = 100,
        .current = 210,
        .threshold = 200,
        .direction = .above,
        .release_threshold = 184,
    });
    try testing.expectEqual(Edge.press, e);
}

test "analog_edge: direction=above, value falls below release_threshold while active → release" {
    const e = detect(.{
        .prev = 210,
        .current = 180,
        .threshold = 200,
        .direction = .above,
        .release_threshold = 184,
    });
    try testing.expectEqual(Edge.release, e);
}

test "analog_edge: direction=above, hysteresis band — value oscillates between release and threshold → no edge" {
    // Previously active (>= threshold), now in hysteresis band [184, 200) →
    // must remain active, no release edge.
    const e1 = detect(.{
        .prev = 210,
        .current = 190,
        .threshold = 200,
        .direction = .above,
        .release_threshold = 184,
    });
    try testing.expectEqual(Edge.none, e1);

    // Previously inactive (< threshold), now in hysteresis band → must
    // remain inactive, no press edge.
    const e2 = detect(.{
        .prev = 100,
        .current = 190,
        .threshold = 200,
        .direction = .above,
        .release_threshold = 184,
    });
    try testing.expectEqual(Edge.none, e2);
}

test "analog_edge: direction=below, value drops below threshold from above → press" {
    // "Below" means: light press activates, hard press deactivates.
    // prev=210 was above, current=80 is below threshold=100 → press.
    const e = detect(.{
        .prev = 210,
        .current = 80,
        .threshold = 100,
        .direction = .below,
        .release_threshold = 116,
    });
    try testing.expectEqual(Edge.press, e);
}

test "analog_edge: direction=below, value rises above release_threshold while active → release" {
    const e = detect(.{
        .prev = 80,
        .current = 130,
        .threshold = 100,
        .direction = .below,
        .release_threshold = 116,
    });
    try testing.expectEqual(Edge.release, e);
}

test "analog_edge: direction=below, finger lifted (active → 0) → release" {
    // Going from active (in 0..threshold) to fully released (0) is a
    // natural release — layer must deactivate.
    const e = detect(.{
        .prev = 80,
        .current = 0,
        .threshold = 100,
        .direction = .below,
        .release_threshold = 116,
    });
    try testing.expectEqual(Edge.release, e);
}

test "analog_edge: direction=below, resting (prev=0, current=0) → no edge" {
    // Trigger never pressed at all → no spurious press/release.
    const e = detect(.{
        .prev = 0,
        .current = 0,
        .threshold = 100,
        .direction = .below,
        .release_threshold = 116,
    });
    try testing.expectEqual(Edge.none, e);
}
