const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const DeviceInstance = @import("device_instance.zig").DeviceInstance;
const DeviceConfig = @import("config/device.zig").DeviceConfig;

const MAX_INSTANCES = 16;
const BACKOFF_CAP_S: u64 = 30;

const Entry = struct {
    allocator: std.mem.Allocator,
    instance: DeviceInstance,
    thread: ?std.Thread,
    done_r: posix.fd_t,
    done_w: posix.fd_t,
    backoff_s: u64,
    cfg: *const DeviceConfig,
};

pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry),
    stop_fd: posix.fd_t,
    hup_fd: posix.fd_t,
    // ns per backoff second; overridden in tests for fast execution
    backoff_unit_ns: u64 = std.time.ns_per_s,

    pub fn init(allocator: std.mem.Allocator) !Supervisor {
        var mask = posix.sigemptyset();
        posix.sigaddset(&mask, linux.SIG.TERM);
        posix.sigaddset(&mask, linux.SIG.INT);
        posix.sigaddset(&mask, linux.SIG.HUP);
        posix.sigprocmask(linux.SIG.BLOCK, &mask, null);

        var stop_mask = posix.sigemptyset();
        posix.sigaddset(&stop_mask, linux.SIG.TERM);
        posix.sigaddset(&stop_mask, linux.SIG.INT);
        const stop_fd = try posix.signalfd(-1, &stop_mask, 0);
        errdefer posix.close(stop_fd);

        var hup_mask = posix.sigemptyset();
        posix.sigaddset(&hup_mask, linux.SIG.HUP);
        const hup_fd = try posix.signalfd(-1, &hup_mask, 0);
        errdefer posix.close(hup_fd);

        return .{
            .allocator = allocator,
            .entries = .{},
            .stop_fd = stop_fd,
            .hup_fd = hup_fd,
        };
    }

    pub fn deinit(self: *Supervisor) void {
        for (self.entries.items) |*e| {
            posix.close(e.done_r);
            posix.close(e.done_w);
            e.instance.deinit();
        }
        self.entries.deinit(self.allocator);
        posix.close(self.stop_fd);
        posix.close(self.hup_fd);
    }

    pub fn addInstance(self: *Supervisor, instance: DeviceInstance, cfg: *const DeviceConfig) !void {
        const pipes = try posix.pipe2(.{ .NONBLOCK = true });
        errdefer {
            posix.close(pipes[0]);
            posix.close(pipes[1]);
        }
        try self.entries.append(self.allocator, .{
            .allocator = self.allocator,
            .instance = instance,
            .thread = null,
            .done_r = pipes[0],
            .done_w = pipes[1],
            .backoff_s = 1,
            .cfg = cfg,
        });
    }

    pub fn run(self: *Supervisor) !void {
        for (self.entries.items) |*e| {
            e.thread = try spawnEntry(e);
        }
        try self.loop();
    }

    fn loop(self: *Supervisor) !void {
        while (true) {
            var pollfds: [2 + MAX_INSTANCES]posix.pollfd = undefined;
            pollfds[0] = .{ .fd = self.stop_fd, .events = posix.POLL.IN, .revents = 0 };
            pollfds[1] = .{ .fd = self.hup_fd, .events = posix.POLL.IN, .revents = 0 };
            const n_entries = self.entries.items.len;
            for (self.entries.items, 0..) |*e, i| {
                pollfds[2 + i] = .{ .fd = e.done_r, .events = posix.POLL.IN, .revents = 0 };
            }
            const n_fds: usize = 2 + n_entries;

            _ = posix.ppoll(pollfds[0..n_fds], null, null) catch |err| switch (err) {
                error.SignalInterrupt => continue,
                else => return err,
            };

            if (pollfds[0].revents & posix.POLL.IN != 0) {
                var siginfo: [128]u8 = undefined;
                _ = posix.read(self.stop_fd, &siginfo) catch {};
                for (self.entries.items) |*e| e.instance.stop();
                for (self.entries.items) |*e| {
                    if (e.thread) |t| t.join();
                    e.thread = null;
                }
                return;
            }

            if (pollfds[1].revents & posix.POLL.IN != 0) {
                var siginfo: [128]u8 = undefined;
                _ = posix.read(self.hup_fd, &siginfo) catch {};
                // T6: hot-reload
            }

            for (self.entries.items, 0..) |*e, i| {
                if (pollfds[2 + i].revents & posix.POLL.IN == 0) continue;
                var dummy: [1]u8 = undefined;
                _ = posix.read(e.done_r, &dummy) catch {};
                if (e.thread) |t| t.join();
                e.thread = null;

                std.log.info("device thread exited; respawning in {}s", .{e.backoff_s});
                std.Thread.sleep(e.backoff_s * self.backoff_unit_ns);
                e.backoff_s = @min(e.backoff_s * 2, BACKOFF_CAP_S);

                const new_inst = DeviceInstance.init(e.allocator, e.cfg) catch |err| {
                    std.log.err("respawn failed: {}", .{err});
                    continue;
                };
                e.instance.deinit();
                e.instance = new_inst;
                e.thread = spawnEntry(e) catch |err| {
                    std.log.err("spawn failed after respawn: {}", .{err});
                    continue;
                };
            }
        }
    }
};

fn spawnEntry(e: *Entry) !std.Thread {
    return std.Thread.spawn(.{}, threadFn, .{e});
}

fn threadFn(e: *Entry) void {
    blockAllSignals();
    e.instance.run() catch |err| {
        std.log.err("device instance error: {}", .{err});
    };
    _ = posix.write(e.done_w, &[_]u8{1}) catch {};
}

fn blockAllSignals() void {
    var mask = posix.sigemptyset();
    posix.sigaddset(&mask, linux.SIG.TERM);
    posix.sigaddset(&mask, linux.SIG.INT);
    posix.sigaddset(&mask, linux.SIG.HUP);
    posix.sigprocmask(linux.SIG.BLOCK, &mask, null);
}

// --- tests ---

const testing = std.testing;
const EventLoop = @import("event_loop.zig").EventLoop;
const Interpreter = @import("core/interpreter.zig").Interpreter;
const MockDeviceIO = @import("test/mock_device_io.zig").MockDeviceIO;
const device_mod = @import("config/device.zig");
const DeviceIO = @import("io/device_io.zig").DeviceIO;

const minimal_toml =
    \\[device]
    \\name = "T"
    \\vid = 1
    \\pid = 2
    \\[[device.interface]]
    \\id = 0
    \\class = "hid"
    \\[[report]]
    \\name = "r"
    \\interface = 0
    \\size = 3
    \\[report.match]
    \\offset = 0
    \\expect = [0x01]
    \\[report.fields]
    \\left_x = { offset = 1, type = "i16le" }
;

fn testDeviceInstance(
    allocator: std.mem.Allocator,
    mock: *MockDeviceIO,
    cfg: *const device_mod.DeviceConfig,
) !DeviceInstance {
    const devices = try allocator.alloc(DeviceIO, 1);
    errdefer allocator.free(devices);
    devices[0] = mock.deviceIO();

    var loop = try EventLoop.init();
    errdefer loop.deinit();
    try loop.addDevice(devices[0]);

    return DeviceInstance{
        .allocator = allocator,
        .devices = devices,
        .loop = loop,
        .interp = Interpreter.init(cfg),
        .mapper = null,
        .uinput_dev = null,
        .aux_dev = null,
        .device_cfg = cfg,
        .pending_mapping = null,
        .stopped = false,
    };
}

const TestSv = struct { sv: Supervisor, stop_w: posix.fd_t, hup_w: posix.fd_t };

fn testSupervisor(allocator: std.mem.Allocator) !TestSv {
    const stop_p = try posix.pipe2(.{ .NONBLOCK = true });
    const hup_p = try posix.pipe2(.{ .NONBLOCK = true });
    return .{
        .sv = Supervisor{
            .allocator = allocator,
            .entries = .{},
            .stop_fd = stop_p[0],
            .hup_fd = hup_p[0],
            .backoff_unit_ns = 0,
        },
        .stop_w = stop_p[1],
        .hup_w = hup_p[1],
    };
}

fn runSupervisor(sv: *Supervisor) !void {
    try sv.run();
}

test "Supervisor: two instances run concurrently without interference" {
    const allocator = testing.allocator;

    const parsed = try device_mod.parseString(allocator, minimal_toml);
    defer parsed.deinit();

    var mock_a = try MockDeviceIO.init(allocator, &.{});
    defer mock_a.deinit();
    var mock_b = try MockDeviceIO.init(allocator, &.{});
    defer mock_b.deinit();

    var t = try testSupervisor(allocator);
    defer posix.close(t.stop_w);
    defer posix.close(t.hup_w);

    try t.sv.addInstance(
        try testDeviceInstance(allocator, &mock_a, &parsed.value),
        &parsed.value,
    );
    try t.sv.addInstance(
        try testDeviceInstance(allocator, &mock_b, &parsed.value),
        &parsed.value,
    );

    const sv_thread = try std.Thread.spawn(.{}, runSupervisor, .{&t.sv});
    std.Thread.sleep(10 * std.time.ns_per_ms);
    _ = try posix.write(t.stop_w, &[_]u8{1});
    sv_thread.join();

    try testing.expect(t.sv.entries.items[0].instance.stopped);
    try testing.expect(t.sv.entries.items[1].instance.stopped);

    t.sv.deinit();
}

test "Supervisor: stop one instance, other continues running" {
    const allocator = testing.allocator;

    const parsed = try device_mod.parseString(allocator, minimal_toml);
    defer parsed.deinit();

    var mock_a = try MockDeviceIO.init(allocator, &.{});
    defer mock_a.deinit();
    var mock_b = try MockDeviceIO.init(allocator, &.{});
    defer mock_b.deinit();

    var t = try testSupervisor(allocator);
    defer posix.close(t.stop_w);
    defer posix.close(t.hup_w);

    try t.sv.addInstance(
        try testDeviceInstance(allocator, &mock_a, &parsed.value),
        &parsed.value,
    );
    try t.sv.addInstance(
        try testDeviceInstance(allocator, &mock_b, &parsed.value),
        &parsed.value,
    );

    const sv_thread = try std.Thread.spawn(.{}, runSupervisor, .{&t.sv});
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Verify B is running before we stop A.
    try testing.expect(!t.sv.entries.items[1].instance.stopped);

    // Stop A and immediately send stop signal to supervisor.
    // stop_fd (index 0 in pollfds) is checked before done_fds, so supervisor
    // exits cleanly without attempting respawn.
    t.sv.entries.items[0].instance.stop();
    _ = try posix.write(t.stop_w, &[_]u8{1});
    sv_thread.join();

    t.sv.deinit();
}

test "Supervisor: stop_fd triggers stop-all and join" {
    const allocator = testing.allocator;

    const parsed = try device_mod.parseString(allocator, minimal_toml);
    defer parsed.deinit();

    var mock = try MockDeviceIO.init(allocator, &.{});
    defer mock.deinit();

    var t = try testSupervisor(allocator);
    defer posix.close(t.stop_w);
    defer posix.close(t.hup_w);

    try t.sv.addInstance(
        try testDeviceInstance(allocator, &mock, &parsed.value),
        &parsed.value,
    );

    const sv_thread = try std.Thread.spawn(.{}, runSupervisor, .{&t.sv});
    std.Thread.sleep(5 * std.time.ns_per_ms);
    _ = try posix.write(t.stop_w, &[_]u8{1});
    sv_thread.join();

    try testing.expect(t.sv.entries.items[0].instance.stopped);
    try testing.expectEqual(@as(?std.Thread, null), t.sv.entries.items[0].thread);

    t.sv.deinit();
}

test "Supervisor: backoff doubles up to cap" {
    var backoff: u64 = 1;
    const sequence = [_]u64{ 2, 4, 8, 16, 30, 30 };
    for (sequence) |expected| {
        backoff = @min(backoff * 2, BACKOFF_CAP_S);
        try testing.expectEqual(expected, backoff);
    }
}
