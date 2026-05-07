const std = @import("std");

pub const PassthroughMode = enum {
    never,
    always,
    honor_timeout,
};

pub fn parseMode(name: ?[]const u8) PassthroughMode {
    const s = name orelse return .never;
    return std.meta.stringToEnum(PassthroughMode, s) orelse .never;
}

pub fn shouldSuppress(mode: PassthroughMode, layer_active: bool) bool {
    return switch (mode) {
        .never => true,
        .always => false,
        .honor_timeout => layer_active,
    };
}

const testing = std.testing;

test "passthrough: parseMode null → never" {
    try testing.expectEqual(PassthroughMode.never, parseMode(null));
}

test "passthrough: shouldSuppress always → false regardless of layer state" {
    try testing.expect(!shouldSuppress(.always, false));
    try testing.expect(!shouldSuppress(.always, true));
}
