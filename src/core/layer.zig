const std = @import("std");

// Minimal LayerConfig for T2; T1 will define the full struct in config/mapping.zig
// and layer.zig will import it instead.
pub const LayerConfig = struct {
    name: []const u8,
    trigger: []const u8 = "",
    activation: ?[]const u8 = null,
    tap: ?[]const u8 = null,
    hold_timeout: ?u32 = null,
};

pub const TapHoldState = struct {
    layer_name: []const u8,
    layer_activated: bool = false,
};

pub const LayerState = struct {
    tap_hold: ?TapHoldState = null,
    toggled: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) LayerState {
        return .{ .toggled = std.StringHashMap(void).init(allocator) };
    }

    pub fn deinit(self: *LayerState) void {
        self.toggled.deinit();
    }

    /// Returns the active LayerConfig by priority:
    /// 1. Hold ACTIVE (tap_hold != null and layer_activated == true)
    /// 2. First toggled layer in declaration order (ADR-004)
    /// 3. null (base layer)
    pub fn getActive(
        self: *const LayerState,
        configs: []const LayerConfig,
    ) ?*const LayerConfig {
        if (self.tap_hold) |*th| {
            if (th.layer_activated) {
                for (configs) |*cfg| {
                    if (std.mem.eql(u8, cfg.name, th.layer_name)) return cfg;
                }
            }
        }
        for (configs) |*cfg| {
            if (self.toggled.contains(cfg.name)) return cfg;
        }
        return null;
    }
};

// --- tests ---

const testing = std.testing;

test "getActive: no active layer returns null" {
    var ls = LayerState.init(testing.allocator);
    defer ls.deinit();

    const configs = [_]LayerConfig{
        .{ .name = "aim" },
        .{ .name = "fn" },
    };
    try testing.expect(ls.getActive(&configs) == null);
}

test "getActive: hold ACTIVE returns matching layer" {
    var ls = LayerState.init(testing.allocator);
    defer ls.deinit();
    ls.tap_hold = .{ .layer_name = "aim", .layer_activated = true };

    const configs = [_]LayerConfig{
        .{ .name = "aim" },
        .{ .name = "fn" },
    };
    const active = ls.getActive(&configs);
    try testing.expect(active != null);
    try testing.expectEqualStrings("aim", active.?.name);
}

test "getActive: hold PENDING (not activated) does not activate layer" {
    var ls = LayerState.init(testing.allocator);
    defer ls.deinit();
    ls.tap_hold = .{ .layer_name = "aim", .layer_activated = false };

    const configs = [_]LayerConfig{.{ .name = "aim" }};
    try testing.expect(ls.getActive(&configs) == null);
}

test "getActive: toggle on returns matching layer" {
    var ls = LayerState.init(testing.allocator);
    defer ls.deinit();
    try ls.toggled.put("fn", {});

    const configs = [_]LayerConfig{
        .{ .name = "aim" },
        .{ .name = "fn" },
    };
    const active = ls.getActive(&configs);
    try testing.expect(active != null);
    try testing.expectEqualStrings("fn", active.?.name);
}

test "getActive: hold ACTIVE takes priority over toggled" {
    var ls = LayerState.init(testing.allocator);
    defer ls.deinit();
    ls.tap_hold = .{ .layer_name = "aim", .layer_activated = true };
    try ls.toggled.put("fn", {});

    const configs = [_]LayerConfig{
        .{ .name = "aim" },
        .{ .name = "fn" },
    };
    const active = ls.getActive(&configs);
    try testing.expect(active != null);
    try testing.expectEqualStrings("aim", active.?.name);
}

test "getActive: multiple toggled layers — declaration order wins (ADR-004)" {
    var ls = LayerState.init(testing.allocator);
    defer ls.deinit();
    try ls.toggled.put("aim", {});
    try ls.toggled.put("fn", {});

    // aim declared first → higher priority
    const configs = [_]LayerConfig{
        .{ .name = "aim" },
        .{ .name = "fn" },
    };
    const active = ls.getActive(&configs);
    try testing.expect(active != null);
    try testing.expectEqualStrings("aim", active.?.name);
}

test "getActive: multiple toggled layers — fn declared first wins when aim is absent" {
    var ls = LayerState.init(testing.allocator);
    defer ls.deinit();
    try ls.toggled.put("fn", {});

    const configs = [_]LayerConfig{
        .{ .name = "aim" },
        .{ .name = "fn" },
    };
    const active = ls.getActive(&configs);
    try testing.expect(active != null);
    try testing.expectEqualStrings("fn", active.?.name);
}

test "getActive: configs length boundary — toggled name not in configs returns null" {
    var ls = LayerState.init(testing.allocator);
    defer ls.deinit();
    try ls.toggled.put("unknown", {});

    const configs = [_]LayerConfig{.{ .name = "aim" }};
    try testing.expect(ls.getActive(&configs) == null);
}

test "getActive: empty configs always returns null" {
    var ls = LayerState.init(testing.allocator);
    defer ls.deinit();
    ls.tap_hold = .{ .layer_name = "aim", .layer_activated = true };
    try ls.toggled.put("fn", {});

    try testing.expect(ls.getActive(&.{}) == null);
}
