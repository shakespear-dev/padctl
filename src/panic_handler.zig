//! Panic-time cleanup + crash-vs-clean-exit telemetry.
//!
//! Two things this module owns:
//!
//!   1. A fixed-size, lock-free device registry. Each entry stores an
//!      hidraw fd and the pre-built stop-frame bytes for that device. On
//!      panic the handler walks the registry and writes the stop frame to
//!      every still-registered device so a crash mid-rumble does not leave
//!      the controller's motor running. This is best-effort — if the
//!      controller's firmware has already entered a state where it ignores
//!      zero-magnitude frames, the next non-zero rumble re-seeds it. But
//!      the common case (host crashed before a stop frame went out,
//!      firmware otherwise healthy) gets cleared here.
//!
//!   2. A clean-exit sentinel file. The daemon creates the file at
//!      startup and deletes it on graceful shutdown. If the file is still
//!      present at the next startup, the previous process exited dirty —
//!      either via panic, SIGKILL, OOM, or a power loss. We log
//!      `prior_exit=clean|dirty` as a single info line so future
//!      log-grepping (e.g. on a user's machine reporting stuck-rumble)
//!      can correlate gameplay incidents with crashes.
//!
//! Why both: even if the panic handler always fires its stop frame, the
//! sentinel still distinguishes "crashed inside our handler" from "killed
//! by the OOM killer before the handler ran" and from
//! "user typed `systemctl stop`". Each of those has a different ETA-on-
//! firmware-investigation implication.

const std = @import("std");
const posix = std.posix;
const padctl_log = @import("log.zig");

/// Maximum number of devices the registry can track. Sized for the worst
/// vader5-style multi-interface case (4 interfaces × 2 simultaneous units)
/// with headroom. Increasing is cheap; the array is stack-statically sized.
pub const MAX_REGISTERED: usize = 8;

/// Maximum HID OUT report size we pre-store as a stop frame. 64 bytes
/// covers every device in `devices/` today (longest is dualsense at 65,
/// but that template is BT-input-only — the USB stop is shorter). If a
/// future device needs more, bump this.
pub const MAX_FRAME: usize = 64;

/// Per-device tag length cap. Used only for the panic-log line, so the
/// string can be truncated without functional impact.
pub const MAX_TAG: usize = 31;

/// Filename of the sentinel within the resolved state directory.
const SENTINEL_FILENAME = "/dirty_marker";

/// One device slot. fd == -1 means the slot is empty. Mutation is via
/// atomic operations on `fd` so the panic handler (which may run from any
/// thread, possibly while the registry is being modified) sees a
/// consistent snapshot. `frame`/`frame_len`/`tag`/`tag_len` are written
/// BEFORE `fd` is published with a release store; the panic handler
/// loads `fd` with acquire and then reads the rest, mirroring the
/// publication pattern.
const Slot = struct {
    fd: i32 = -1,
    frame_len: u8 = 0,
    frame: [MAX_FRAME]u8 = [_]u8{0} ** MAX_FRAME,
    tag_len: u8 = 0,
    tag: [MAX_TAG]u8 = [_]u8{0} ** MAX_TAG,
};

var slots: [MAX_REGISTERED]Slot = [_]Slot{.{}} ** MAX_REGISTERED;

/// Re-entry guard. The panic handler swaps this from 0 to 1; if a second
/// panic fires while we are mid-cleanup, that thread skips cleanup and
/// goes straight to abort to avoid double-iterating slots whose fds may
/// already have been closed by the OS.
var panic_in_progress: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

/// Resolved sentinel path. Set once at startup via `setSentinelPath`.
/// Length 0 means "not set" — sentinel API becomes a no-op in that case
/// (e.g. tests that don't bother wiring it up).
var sentinel_path_buf: [256]u8 = undefined;
var sentinel_path_len: usize = 0;

pub const PriorExit = enum {
    /// Sentinel was not configured or could not be checked. No signal.
    unknown,
    /// Sentinel was absent at startup → previous process either deleted
    /// it on graceful shutdown or this is the first run on this host.
    clean,
    /// Sentinel was present at startup → previous process did not reach
    /// `markCleanExit`. Either crashed, SIGKILL'd, or power-cut.
    dirty,
};

/// Register a device with the panic-time stop emitter. Returns the slot
/// index on success (pass to `unregisterDevice` on detach), or null when
/// the registry is full or arguments are out of bounds.
///
/// `stop_frame` is the pre-built byte sequence (template-filled,
/// checksum-applied, magnitudes zeroed) that will be written verbatim to
/// `fd` on panic. Building it at attach time and copying the bytes here
/// means the panic handler does no allocation, no template lookup, and
/// no mutex acquisition.
pub fn registerDevice(fd: i32, stop_frame: []const u8, tag: []const u8) ?usize {
    if (fd < 0) return null;
    if (stop_frame.len == 0 or stop_frame.len > MAX_FRAME) return null;

    var i: usize = 0;
    while (i < MAX_REGISTERED) : (i += 1) {
        // Reserve the slot with a CAS from -1 → -2 ("being written").
        // While -2, other registrants will skip this slot, and the panic
        // handler's `fd >= 0` check excludes it from emission. We promote
        // to the real fd only after frame/tag bytes are in place.
        const got = @cmpxchgStrong(i32, &slots[i].fd, -1, -2, .acquire, .monotonic);
        if (got == null) {
            @memcpy(slots[i].frame[0..stop_frame.len], stop_frame);
            slots[i].frame_len = @intCast(stop_frame.len);
            const tlen = @min(tag.len, MAX_TAG);
            @memcpy(slots[i].tag[0..tlen], tag[0..tlen]);
            slots[i].tag_len = @intCast(tlen);
            // Release-store the real fd so loads in the panic handler see
            // the populated frame/tag bytes.
            @atomicStore(i32, &slots[i].fd, fd, .release);
            return i;
        }
    }
    return null;
}

/// Release a registry slot. Safe to call with an out-of-range index
/// (no-op) so callers can use `?usize` without conditionals.
pub fn unregisterDevice(slot_idx: ?usize) void {
    const i = slot_idx orelse return;
    if (i >= MAX_REGISTERED) return;
    @atomicStore(i32, &slots[i].fd, -1, .release);
}

/// Returns the number of currently-registered slots. Diagnostic only;
/// not load-bearing for cleanup correctness.
pub fn registeredCount() usize {
    var n: usize = 0;
    for (0..MAX_REGISTERED) |i| {
        if (@atomicLoad(i32, &slots[i].fd, .acquire) >= 0) n += 1;
    }
    return n;
}

/// Resets the registry. Test-only.
pub fn resetForTests() void {
    for (0..MAX_REGISTERED) |i| {
        @atomicStore(i32, &slots[i].fd, -1, .release);
        slots[i].frame_len = 0;
        slots[i].tag_len = 0;
    }
    panic_in_progress.store(0, .release);
}

/// Configure the sentinel path. Call once at startup with the resolved
/// state directory (the caller is expected to have created it already —
/// `padctl_log.initPath` does this). After this, `checkAndArmSentinel`
/// and `markCleanExit` are usable.
pub fn setSentinelPath(state_dir: []const u8) void {
    if (state_dir.len == 0) return;
    if (state_dir.len + SENTINEL_FILENAME.len >= sentinel_path_buf.len) return;
    @memcpy(sentinel_path_buf[0..state_dir.len], state_dir);
    @memcpy(sentinel_path_buf[state_dir.len..][0..SENTINEL_FILENAME.len], SENTINEL_FILENAME);
    sentinel_path_len = state_dir.len + SENTINEL_FILENAME.len;
}

/// Test helper: override the sentinel path with a caller-owned string.
/// Test-only; production code uses `setSentinelPath`.
pub fn setSentinelPathRaw(full_path: []const u8) void {
    if (full_path.len == 0 or full_path.len >= sentinel_path_buf.len) {
        sentinel_path_len = 0;
        return;
    }
    @memcpy(sentinel_path_buf[0..full_path.len], full_path);
    sentinel_path_len = full_path.len;
}

/// Check whether the previous daemon exited cleanly, then create (or
/// recreate) the marker file so this run can detect its own dirty exit
/// next time.
///
/// Logic:
///   - If marker file is present at entry: previous run did not reach
///     `markCleanExit` → return `.dirty`.
///   - If absent: either first run on this host or previous run exited
///     cleanly → return `.clean`.
///   - Either way, (re)create the marker so the next-run check works.
pub fn checkAndArmSentinel() PriorExit {
    if (sentinel_path_len == 0) return .unknown;
    const path = sentinel_path_buf[0..sentinel_path_len];

    const existed = blk: {
        const f = std.fs.openFileAbsolute(path, .{}) catch break :blk false;
        f.close();
        break :blk true;
    };

    // (Re)create the marker. CREAT|TRUNC so the file lands at zero size
    // if it didn't exist, or gets truncated if it did. Failure to write
    // the marker is non-fatal; we just lose telemetry on the next run.
    const f = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch {
        return if (existed) .dirty else .clean;
    };
    f.close();

    return if (existed) .dirty else .clean;
}

/// Delete the marker. Call from the daemon's graceful-shutdown path
/// (after `serveLoop` returns) so the next startup sees `.clean`.
pub fn markCleanExit() void {
    if (sentinel_path_len == 0) return;
    const path = sentinel_path_buf[0..sentinel_path_len];
    std.fs.deleteFileAbsolute(path) catch {};
}

/// Panic handler. Wired up via `pub const Panic = FullPanic(handlePanic)`
/// in `main.zig`. Runs on whichever thread tripped the panic — typically
/// a device thread mid-`apply` or the supervisor thread mid-`serveLoop`.
pub fn handlePanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    // Re-entry guard. If we're already panicking (e.g. because the cleanup
    // itself panicked), skip cleanup and go straight to abort.
    if (panic_in_progress.swap(1, .acq_rel) != 0) {
        std.debug.defaultPanic(msg, first_trace_addr);
    }

    writePanicHeader(msg);
    emitStopToAllDevices();

    // Defer to the default panic for the stack trace, coredump, and abort.
    // We deliberately DO NOT call `markCleanExit` — leaving the sentinel in
    // place is what tells the next run "previous exit was dirty".
    std.debug.defaultPanic(msg, first_trace_addr);
}

fn writePanicHeader(msg: []const u8) void {
    var buf: [1024]u8 = undefined;
    const formatted = std.fmt.bufPrint(
        &buf,
        "[PANIC] padctl panic: {s} (registered_devices={d})\n",
        .{ msg, registeredCount() },
    ) catch "[PANIC] padctl panic (message-format-failed)\n";

    _ = posix.write(posix.STDERR_FILENO, formatted) catch {};

    const log_fd = padctl_log.getLogFd();
    if (log_fd >= 0) {
        _ = posix.write(log_fd, formatted) catch {};
    }
}

fn emitStopToAllDevices() void {
    for (0..MAX_REGISTERED) |i| {
        const fd = @atomicLoad(i32, &slots[i].fd, .acquire);
        if (fd < 0) continue;
        const len = slots[i].frame_len;
        if (len == 0 or len > MAX_FRAME) continue;
        _ = posix.write(fd, slots[i].frame[0..len]) catch {};
    }
}

// --- tests ---

const testing = std.testing;

test "panic_handler: register/unregister roundtrip" {
    resetForTests();
    defer resetForTests();

    const frame = [_]u8{ 0x5a, 0xa5, 0x12, 0x06, 0x00, 0x00, 0x00, 0x00, 0x18 };
    const slot = registerDevice(42, &frame, "test").?;
    try testing.expectEqual(@as(usize, 1), registeredCount());
    unregisterDevice(slot);
    try testing.expectEqual(@as(usize, 0), registeredCount());
}

test "panic_handler: registry rejects fd<0 and oversize frames" {
    resetForTests();
    defer resetForTests();

    try testing.expect(registerDevice(-1, "abc", "x") == null);
    try testing.expect(registerDevice(5, "", "x") == null);

    var huge: [MAX_FRAME + 1]u8 = undefined;
    @memset(&huge, 0);
    try testing.expect(registerDevice(5, &huge, "x") == null);

    try testing.expectEqual(@as(usize, 0), registeredCount());
}

test "panic_handler: registry fills then refuses overflow" {
    resetForTests();
    defer resetForTests();

    var slots_taken: [MAX_REGISTERED]?usize = .{null} ** MAX_REGISTERED;
    for (0..MAX_REGISTERED) |i| {
        slots_taken[i] = registerDevice(@intCast(100 + i), "abc", "tag");
        try testing.expect(slots_taken[i] != null);
    }
    try testing.expectEqual(MAX_REGISTERED, registeredCount());

    // 9th registration must fail.
    try testing.expect(registerDevice(99, "abc", "tag") == null);

    // Free one and re-register succeeds.
    unregisterDevice(slots_taken[3]);
    try testing.expect(registerDevice(99, "abc", "tag") != null);
}

test "panic_handler: unregister out-of-range and null are no-ops" {
    resetForTests();
    defer resetForTests();
    unregisterDevice(null);
    unregisterDevice(MAX_REGISTERED);
    unregisterDevice(MAX_REGISTERED + 100);
    try testing.expectEqual(@as(usize, 0), registeredCount());
}

test "panic_handler: emitStopToAllDevices writes registered frames" {
    resetForTests();
    defer resetForTests();

    // Use a pipe pair as a stand-in for the hidraw fd. The handler writes
    // bytes; we read them back and verify the contents.
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const stop_frame = [_]u8{ 0x5a, 0xa5, 0x12, 0x06, 0x00, 0x00, 0x00, 0x00, 0x18 };
    _ = registerDevice(fds[1], &stop_frame, "vader-test").?;

    emitStopToAllDevices();

    var read_buf: [32]u8 = undefined;
    const n = try posix.read(fds[0], &read_buf);
    try testing.expectEqual(stop_frame.len, n);
    try testing.expectEqualSlices(u8, &stop_frame, read_buf[0..n]);
}

test "panic_handler: emitStopToAllDevices skips empty slots" {
    resetForTests();
    defer resetForTests();

    // No registrations: must not crash, must not write anywhere.
    emitStopToAllDevices();
    try testing.expectEqual(@as(usize, 0), registeredCount());
}

test "panic_handler: sentinel — clean → dirty → clean cycle" {
    resetForTests();
    defer resetForTests();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    const sentinel = try std.fmt.allocPrint(testing.allocator, "{s}/dirty", .{root});
    defer testing.allocator.free(sentinel);
    setSentinelPathRaw(sentinel);
    defer {
        sentinel_path_len = 0;
        std.fs.deleteFileAbsolute(sentinel) catch {};
    }

    // First run: marker absent → clean. Marker now exists.
    try testing.expectEqual(PriorExit.clean, checkAndArmSentinel());

    // Second run without graceful shutdown: marker still present → dirty.
    try testing.expectEqual(PriorExit.dirty, checkAndArmSentinel());

    // Graceful shutdown clears the marker. Next check is clean again.
    markCleanExit();
    try testing.expectEqual(PriorExit.clean, checkAndArmSentinel());
}

test "panic_handler: sentinel — markCleanExit before any check is no-op" {
    resetForTests();
    defer resetForTests();
    setSentinelPathRaw("");
    // path_len == 0; this must not throw.
    markCleanExit();
    try testing.expectEqual(PriorExit.unknown, checkAndArmSentinel());
}
