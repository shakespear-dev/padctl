const std = @import("std");
const posix = std.posix;

const DeviceInstance = @import("device_instance.zig").DeviceInstance;
const config_device = @import("config/device.zig");
const HidrawDevice = @import("io/hidraw.zig").HidrawDevice;
const readPhysicalPath = @import("io/hidraw.zig").readPhysicalPath;

pub const InstanceEntry = struct {
    phys: []const u8,
    inst: DeviceInstance,
    thread: std.Thread,
};

pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(InstanceEntry),
    // ParseResults whose DeviceConfig is referenced by at least one entry.
    configs: std.ArrayList(*config_device.ParseResult),

    pub fn init(allocator: std.mem.Allocator) Supervisor {
        return .{ .allocator = allocator, .entries = .{}, .configs = .{} };
    }

    pub fn deinit(self: *Supervisor) void {
        for (self.entries.items) |*e| {
            self.allocator.free(e.phys);
            e.inst.deinit();
        }
        self.entries.deinit(self.allocator);
        for (self.configs.items) |c| {
            c.deinit();
            self.allocator.destroy(c);
        }
        self.configs.deinit(self.allocator);
    }

    /// Glob *.toml in dir, discover devices, dedup by physical path, spawn threads.
    pub fn startFromDir(self: *Supervisor, dir_path: []const u8) !void {
        return self.startFromDirWithRoot(dir_path, "/dev");
    }

    pub fn startFromDirWithRoot(self: *Supervisor, dir_path: []const u8, dev_root: []const u8) !void {
        var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
        defer dir.close();

        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;

            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const toml_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name });

            const parsed = config_device.parseFile(self.allocator, toml_path) catch |err| {
                std.log.warn("skip {s}: {}", .{ entry.name, err });
                continue;
            };
            const cfg_ptr = try self.allocator.create(config_device.ParseResult);
            cfg_ptr.* = parsed;

            const vid: u16 = @intCast(cfg_ptr.value.device.vid);
            const pid: u16 = @intCast(cfg_ptr.value.device.pid);

            const paths = HidrawDevice.discoverAllWithRoot(self.allocator, vid, pid, dev_root) catch |err| {
                std.log.warn("discoverAll for {s}: {}", .{ entry.name, err });
                cfg_ptr.deinit();
                self.allocator.destroy(cfg_ptr);
                continue;
            };
            defer {
                for (paths) |p| self.allocator.free(p);
                self.allocator.free(paths);
            }

            if (paths.len == 0) {
                cfg_ptr.deinit();
                self.allocator.destroy(cfg_ptr);
                continue;
            }

            var spawned: usize = 0;
            for (paths) |hidraw_path| {
                const phys = readPhysicalPath(self.allocator, hidraw_path) catch |err| {
                    std.log.warn("readPhysicalPath {s}: {}", .{ hidraw_path, err });
                    continue;
                };

                const gop = try seen.getOrPut(phys);
                if (gop.found_existing) {
                    self.allocator.free(phys);
                    continue;
                }

                var inst = DeviceInstance.init(self.allocator, &cfg_ptr.value) catch |err| {
                    std.log.warn("DeviceInstance.init for {s}: {}", .{ hidraw_path, err });
                    seen.removeByPtr(gop.key_ptr);
                    self.allocator.free(phys);
                    continue;
                };
                errdefer inst.deinit();

                const thread = try std.Thread.spawn(.{}, DeviceInstance.run, .{&inst});
                try self.entries.append(self.allocator, .{ .phys = phys, .inst = inst, .thread = thread });
                spawned += 1;
            }

            if (spawned > 0) {
                try self.configs.append(self.allocator, cfg_ptr);
            } else {
                cfg_ptr.deinit();
                self.allocator.destroy(cfg_ptr);
            }
        }
    }

    pub fn stopAll(self: *Supervisor) void {
        for (self.entries.items) |*e| e.inst.stop();
    }

    pub fn joinAll(self: *Supervisor) void {
        for (self.entries.items) |*e| e.thread.join();
    }
};

// --- tests ---

const testing = std.testing;

const minimal_device_toml =
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

test "Supervisor: empty config dir → zero instances" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var sup = Supervisor.init(allocator);
    defer sup.deinit();

    try sup.startFromDirWithRoot(tmp_path, "/nonexistent_dev_root_xyz");
    try testing.expectEqual(@as(usize, 0), sup.entries.items.len);
}

test "Supervisor: dir with no toml files → zero instances" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try tmp.dir.writeFile(.{ .sub_path = "readme.txt", .data = "hello" });

    var sup = Supervisor.init(allocator);
    defer sup.deinit();

    try sup.startFromDirWithRoot(tmp_path, "/nonexistent_dev_root_xyz");
    try testing.expectEqual(@as(usize, 0), sup.entries.items.len);
}

test "Supervisor: two toml files, no matching hidraw → zero instances" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try tmp.dir.writeFile(.{ .sub_path = "a.toml", .data = minimal_device_toml });
    try tmp.dir.writeFile(.{ .sub_path = "b.toml", .data = minimal_device_toml });

    var sup = Supervisor.init(allocator);
    defer sup.deinit();

    try sup.startFromDirWithRoot(tmp_path, "/nonexistent_dev_root_xyz");
    try testing.expectEqual(@as(usize, 0), sup.entries.items.len);
}
