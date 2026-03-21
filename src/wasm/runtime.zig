// WasmPlugin vtable — backend-agnostic interface for WASM plugin lifecycle.
//
// Real wasm3 integration requires linking the wasm3 C library.
// This file provides the vtable definition and a MockPlugin for testing.
// Production wasm3 backend: marked TODO(wasm3), needs manual verification.

const std = @import("std");
const HostContext = @import("host.zig").HostContext;
const GamepadStateDelta = @import("../core/state.zig").GamepadStateDelta;

pub const LoadError = error{
    PluginLoadFailed,
    InvalidModule,
    OutOfMemory,
};

// Result of process_report: optional delta override.
pub const ProcessResult = union(enum) {
    // Plugin produced override data; delta fields reflect it.
    override: GamepadStateDelta,
    // No override; caller should fall back to built-in TOML parsing.
    passthrough,
    // Plugin signalled error; drop this frame.
    drop,
};

pub const WasmPlugin = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Load .wasm bytes, register host functions, instantiate.
        // Returns error if module is malformed or required imports are missing.
        load: *const fn (ptr: *anyopaque, wasm_bytes: []const u8, ctx: *HostContext) LoadError!void,
        // Call init_device() export (if present). Returns false if export is absent.
        initDevice: *const fn (ptr: *anyopaque) bool,
        // Call process_calibration(buf_ptr, buf_len) export (if present).
        processCalibration: *const fn (ptr: *anyopaque, buf: []const u8) void,
        // Call process_report export. Only used when wasm.overrides.process_report = true.
        processReport: *const fn (ptr: *anyopaque, raw: []const u8, out: []u8) ProcessResult,
        // Release all wasm3 resources.
        unload: *const fn (ptr: *anyopaque) void,
        // Free the plugin struct itself.
        destroy: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn load(self: WasmPlugin, wasm_bytes: []const u8, ctx: *HostContext) LoadError!void {
        return self.vtable.load(self.ptr, wasm_bytes, ctx);
    }

    pub fn initDevice(self: WasmPlugin) bool {
        return self.vtable.initDevice(self.ptr);
    }

    pub fn processCalibration(self: WasmPlugin, buf: []const u8) void {
        self.vtable.processCalibration(self.ptr, buf);
    }

    pub fn processReport(self: WasmPlugin, raw: []const u8, out: []u8) ProcessResult {
        return self.vtable.processReport(self.ptr, raw, out);
    }

    pub fn unload(self: WasmPlugin) void {
        self.vtable.unload(self.ptr);
    }

    pub fn destroy(self: WasmPlugin, allocator: std.mem.Allocator) void {
        self.vtable.destroy(self.ptr, allocator);
    }
};

// --- MockPlugin ---
// Used for tests and as a stand-in when wasm3 is not linked.

pub const MockPlugin = struct {
    init_device_called: bool = false,
    process_calibration_called: bool = false,
    process_report_called: bool = false,
    // Configurable test behaviour
    init_device_return: bool = true,
    process_report_result: ProcessResult = .passthrough,
    load_error: ?LoadError = null,
    load_called: bool = false,
    unload_called: bool = false,

    pub fn wasmPlugin(self: *MockPlugin) WasmPlugin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = WasmPlugin.VTable{
        .load = mockLoad,
        .initDevice = mockInitDevice,
        .processCalibration = mockProcessCalibration,
        .processReport = mockProcessReport,
        .unload = mockUnload,
        .destroy = mockDestroy,
    };

    fn mockLoad(ptr: *anyopaque, _: []const u8, _: *HostContext) LoadError!void {
        const self: *MockPlugin = @ptrCast(@alignCast(ptr));
        self.load_called = true;
        if (self.load_error) |e| return e;
    }

    fn mockInitDevice(ptr: *anyopaque) bool {
        const self: *MockPlugin = @ptrCast(@alignCast(ptr));
        self.init_device_called = true;
        return self.init_device_return;
    }

    fn mockProcessCalibration(ptr: *anyopaque, _: []const u8) void {
        const self: *MockPlugin = @ptrCast(@alignCast(ptr));
        self.process_calibration_called = true;
    }

    fn mockProcessReport(ptr: *anyopaque, _: []const u8, _: []u8) ProcessResult {
        const self: *MockPlugin = @ptrCast(@alignCast(ptr));
        self.process_report_called = true;
        return self.process_report_result;
    }

    fn mockUnload(ptr: *anyopaque) void {
        const self: *MockPlugin = @ptrCast(@alignCast(ptr));
        self.unload_called = true;
    }

    fn mockDestroy(_: *anyopaque, _: std.mem.Allocator) void {}
};

// --- tests ---

const testing = std.testing;

test "WasmPlugin vtable: load called and load_called flag set" {
    var mock = MockPlugin{};
    const plugin = mock.wasmPlugin();
    var ctx = HostContext.init(testing.allocator);
    defer ctx.deinit();
    try plugin.load(&[_]u8{ 0x00, 0x61, 0x73, 0x6d }, &ctx);
    try testing.expect(mock.load_called);
}

test "WasmPlugin vtable: load error propagates" {
    var mock = MockPlugin{ .load_error = LoadError.InvalidModule };
    const plugin = mock.wasmPlugin();
    var ctx = HostContext.init(testing.allocator);
    defer ctx.deinit();
    try testing.expectError(LoadError.InvalidModule, plugin.load(&[_]u8{}, &ctx));
}

test "WasmPlugin vtable: initDevice returns configured value" {
    var mock = MockPlugin{ .init_device_return = false };
    const plugin = mock.wasmPlugin();
    try testing.expect(!plugin.initDevice());
    try testing.expect(mock.init_device_called);
}

test "WasmPlugin vtable: processCalibration sets flag" {
    var mock = MockPlugin{};
    const plugin = mock.wasmPlugin();
    plugin.processCalibration(&[_]u8{ 0x01, 0x02 });
    try testing.expect(mock.process_calibration_called);
}

test "WasmPlugin vtable: processReport returns configured result" {
    var mock = MockPlugin{ .process_report_result = .drop };
    const plugin = mock.wasmPlugin();
    var out: [64]u8 = undefined;
    const result = plugin.processReport(&[_]u8{0x01}, &out);
    try testing.expect(mock.process_report_called);
    try testing.expectEqual(ProcessResult.drop, result);
}

test "WasmPlugin vtable: unload sets flag" {
    var mock = MockPlugin{};
    const plugin = mock.wasmPlugin();
    plugin.unload();
    try testing.expect(mock.unload_called);
}

test "WasmPlugin vtable: processReport passthrough result" {
    var mock = MockPlugin{ .process_report_result = .passthrough };
    const plugin = mock.wasmPlugin();
    var out: [64]u8 = undefined;
    const result = plugin.processReport(&[_]u8{0xAB}, &out);
    try testing.expectEqual(ProcessResult.passthrough, result);
}

test "WasmPlugin vtable: processReport override result" {
    const delta = GamepadStateDelta{ .ax = 100 };
    var mock = MockPlugin{ .process_report_result = .{ .override = delta } };
    const plugin = mock.wasmPlugin();
    var out: [64]u8 = undefined;
    const result = plugin.processReport(&[_]u8{0xFF}, &out);
    switch (result) {
        .override => |d| try testing.expectEqual(@as(?i16, 100), d.ax),
        else => return error.WrongResultTag,
    }
}
