const std = @import("std");
const scheduler = @import("codex_auth").stagger;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var environ = try init.minimal.environ.createMap(allocator);
    defer environ.deinit();

    const codex_home = environ.get("CODEX_HOME") orelse return error.EnvironmentVariableNotFound;
    const ready_path = environ.get("STAGGER_LOCK_READY_PATH") orelse return error.EnvironmentVariableNotFound;
    var held = switch (try scheduler.Lock.acquire(allocator, codex_home)) {
        .acquired => |lock| lock,
        .busy => return error.LockAlreadyHeld,
    };
    defer held.release();

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = ready_path, .data = "ready" });
    try std.Io.sleep(init.io, .fromSeconds(5), .awake);
}
