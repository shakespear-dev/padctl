const std = @import("std");
const posix = std.posix;
const socket_client = @import("socket_client.zig");

pub fn run(socket_path: []const u8) u8 {
    const fd = socket_client.connectToSocket(socket_path) catch {
        _ = posix.write(posix.STDERR_FILENO, "error: cannot connect to padctl daemon\n") catch 0;
        return 1;
    };
    defer posix.close(fd);

    var buf: [4096]u8 = undefined;
    const resp = socket_client.sendCommand(fd, "DEVICES\n", &buf) catch {
        _ = posix.write(posix.STDERR_FILENO, "error: no response from daemon\n") catch 0;
        return 1;
    };

    _ = posix.write(posix.STDOUT_FILENO, resp) catch 0;
    if (resp.len == 0 or resp[resp.len - 1] != '\n') {
        _ = posix.write(posix.STDOUT_FILENO, "\n") catch 0;
    }

    return if (std.mem.startsWith(u8, resp, "ERROR")) 1 else 0;
}

// --- tests ---

const testing = std.testing;

test "run: connection failure returns 1" {
    const rc = run("/tmp/padctl-nonexistent-test.sock");
    try testing.expectEqual(@as(u8, 1), rc);
}
