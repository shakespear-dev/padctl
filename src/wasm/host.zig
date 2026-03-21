// Host function context passed to all WASM host callbacks.
// These are the 6 functions imported by plugins under module "env".

const std = @import("std");

pub const HostContext = struct {
    allocator: std.mem.Allocator,
    // per-plugin persistent key-value store (set_state / get_state)
    state_map: std.StringHashMap([]const u8),
    // opaque pointer to device I/O; used by device_read / device_write callbacks
    device_ptr: ?*anyopaque = null,
    device_read_fn: ?*const fn (*anyopaque, report_id: i32, buf: []u8) i32 = null,
    device_write_fn: ?*const fn (*anyopaque, buf: []const u8) i32 = null,
    // opaque pointer to DeviceConfig; used by get_config callback
    config_ptr: ?*const anyopaque = null,
    get_config_fn: ?*const fn (*const anyopaque, key: []const u8, out: []u8) i32 = null,

    pub fn init(allocator: std.mem.Allocator) HostContext {
        return .{
            .allocator = allocator,
            .state_map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *HostContext) void {
        var it = self.state_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.state_map.deinit();
    }

    // --- host function implementations ---

    pub fn deviceRead(self: *HostContext, report_id: i32, buf: []u8) i32 {
        const f = self.device_read_fn orelse return -1;
        const ptr = self.device_ptr orelse return -1;
        return f(ptr, report_id, buf);
    }

    pub fn deviceWrite(self: *HostContext, buf: []const u8) i32 {
        const f = self.device_write_fn orelse return -1;
        const ptr = self.device_ptr orelse return -1;
        return f(ptr, buf);
    }

    pub fn log(_: *HostContext, level: i32, msg: []const u8) void {
        const truncated = if (msg.len > 256) msg[0..256] else msg;
        if (level == 0) {
            std.log.debug("[wasm] {s}", .{truncated});
        } else {
            std.log.err("[wasm] {s}", .{truncated});
        }
    }

    pub fn getConfig(self: *HostContext, key: []const u8, out: []u8) i32 {
        const f = self.get_config_fn orelse return -1;
        const ptr = self.config_ptr orelse return -1;
        return f(ptr, key, out);
    }

    pub fn setState(self: *HostContext, key: []const u8, val: []const u8) void {
        const gop = self.state_map.getOrPut(key) catch return;
        const owned_val = self.allocator.dupe(u8, val) catch {
            if (!gop.found_existing) _ = self.state_map.remove(key);
            return;
        };
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        } else {
            const owned_key = self.allocator.dupe(u8, key) catch {
                _ = self.state_map.remove(key);
                self.allocator.free(owned_val);
                return;
            };
            gop.key_ptr.* = owned_key;
        }
        gop.value_ptr.* = owned_val;
    }

    pub fn getState(self: *HostContext, key: []const u8) ?[]const u8 {
        return self.state_map.get(key);
    }
};

// --- tests ---

const testing = std.testing;

test "HostContext: setState / getState round-trip" {
    var ctx = HostContext.init(testing.allocator);
    defer ctx.deinit();
    ctx.setState("k", "v");
    const got = ctx.getState("k") orelse return error.Missing;
    try testing.expectEqualStrings("v", got);
}

test "HostContext: setState overwrites previous value" {
    var ctx = HostContext.init(testing.allocator);
    defer ctx.deinit();
    ctx.setState("k", "v1");
    ctx.setState("k", "v2");
    const got = ctx.getState("k") orelse return error.Missing;
    try testing.expectEqualStrings("v2", got);
}

test "HostContext: deviceRead returns -1 when no callbacks set" {
    var ctx = HostContext.init(testing.allocator);
    defer ctx.deinit();
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(i32, -1), ctx.deviceRead(0, &buf));
}

test "HostContext: deviceWrite returns -1 when no callbacks set" {
    var ctx = HostContext.init(testing.allocator);
    defer ctx.deinit();
    try testing.expectEqual(@as(i32, -1), ctx.deviceWrite(&[_]u8{0x01}));
}

test "HostContext: getConfig returns -1 when no callbacks set" {
    var ctx = HostContext.init(testing.allocator);
    defer ctx.deinit();
    var buf: [16]u8 = undefined;
    try testing.expectEqual(@as(i32, -1), ctx.getConfig("key", &buf));
}

test "HostContext: deviceRead delegates to callback" {
    const Cb = struct {
        fn read(ptr: *anyopaque, report_id: i32, buf: []u8) i32 {
            _ = ptr;
            buf[0] = @intCast(report_id & 0xff);
            return 1;
        }
    };
    var dummy: u8 = 0;
    var ctx = HostContext.init(testing.allocator);
    defer ctx.deinit();
    ctx.device_ptr = &dummy;
    ctx.device_read_fn = Cb.read;
    var buf: [4]u8 = undefined;
    const n = ctx.deviceRead(0x42, &buf);
    try testing.expectEqual(@as(i32, 1), n);
    try testing.expectEqual(@as(u8, 0x42), buf[0]);
}

test "HostContext: getConfig delegates to callback" {
    const Cb = struct {
        fn get(_: *const anyopaque, key: []const u8, out: []u8) i32 {
            if (std.mem.eql(u8, key, "x.offset")) {
                out[0] = '4';
                return 1;
            }
            return 0;
        }
    };
    var dummy: u8 = 0;
    var ctx = HostContext.init(testing.allocator);
    defer ctx.deinit();
    ctx.config_ptr = &dummy;
    ctx.get_config_fn = Cb.get;
    var buf: [8]u8 = undefined;
    const n = ctx.getConfig("x.offset", &buf);
    try testing.expectEqual(@as(i32, 1), n);
    try testing.expectEqual(@as(u8, '4'), buf[0]);
}
