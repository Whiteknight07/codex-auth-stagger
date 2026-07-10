const std = @import("std");
const runtime = @import("../core/runtime.zig");
const registry_common = @import("../registry/common.zig");

pub const Lock = struct {
    file: std.Io.File,

    pub const AcquireResult = union(enum) {
        acquired: Lock,
        busy,
    };

    pub fn acquire(allocator: std.mem.Allocator, codex_home: []const u8) !AcquireResult {
        try registry_common.ensureAccountsDir(allocator, codex_home);
        const path = try std.fs.path.join(allocator, &.{ codex_home, "accounts", "stagger.lock" });
        defer allocator.free(path);

        const file = std.Io.Dir.cwd().createFile(runtime.io(), path, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = registry_common.private_file_permissions,
        }) catch |err| switch (err) {
            error.WouldBlock => return .busy,
            else => return err,
        };
        errdefer file.close(runtime.io());
        try registry_common.hardenSensitiveFile(path);
        return .{ .acquired = .{ .file = file } };
    }

    pub fn release(self: *Lock) void {
        self.file.unlock(runtime.io());
        self.file.close(runtime.io());
        self.* = undefined;
    }
};
