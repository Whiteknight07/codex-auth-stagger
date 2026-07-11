const std = @import("std");
const http = @import("../api/http.zig");
const runtime = @import("../core/runtime.zig");
const registry = @import("../registry/root.zig");

const timeout_ms: u64 = 15_000;
const output_limit_bytes: usize = 1024;
const random_bytes_count = 16;
const random_name_len = std.base64.url_safe_no_pad.Encoder.calcSize(random_bytes_count);

pub const Runner = *const fn (context: ?*anyopaque, working_directory: []const u8, argv: []const []const u8) anyerror!void;

pub fn run(allocator: std.mem.Allocator, codex_home: []const u8, context: ?*anyopaque, runner: Runner) !void {
    const working_directory = try createWorkingDirectory(allocator, codex_home);
    defer allocator.free(working_directory);
    errdefer std.Io.Dir.cwd().deleteTree(runtime.io(), working_directory) catch {};
    const argv = [_][]const u8{
        "codex", "exec", "--model", "gpt-5.6-luna", "--ephemeral", "--ignore-user-config", "--ignore-rules", "-c", "approval_policy=\"never\"", "--sandbox", "read-only", "--skip-git-repo-check", "OK only.",
    };
    try runner(context, working_directory, &argv);
    try std.Io.Dir.cwd().deleteTree(runtime.io(), working_directory);
}

fn createWorkingDirectory(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    const parent = try std.fs.path.join(allocator, &.{ codex_home, "accounts", "stagger-anchor" });
    defer allocator.free(parent);
    try registry.ensurePrivateDir(parent);

    var random_bytes: [random_bytes_count]u8 = undefined;
    var random_name: [random_name_len]u8 = undefined;
    for (0..16) |_| {
        runtime.io().random(&random_bytes);
        _ = std.base64.url_safe_no_pad.Encoder.encode(&random_name, &random_bytes);
        {
            const working_directory = try std.fs.path.join(allocator, &.{ parent, &random_name });
            errdefer allocator.free(working_directory);
            const status = try std.Io.Dir.cwd().createDirPathStatus(runtime.io(), working_directory, registry.private_dir_permissions);
            if (status == .created) {
                registry.hardenSensitiveDir(working_directory) catch |err| {
                    std.Io.Dir.cwd().deleteTree(runtime.io(), working_directory) catch {};
                    return err;
                };
                return working_directory;
            }
            allocator.free(working_directory);
        }
    }
    return error.StaggerAnchorDirectoryUnavailable;
}

pub fn runProduction(_: ?*anyopaque, working_directory: []const u8, argv: []const []const u8) !void {
    var result = http.runChildCaptureWithCwdAndOutputLimit(std.heap.page_allocator, argv, working_directory, timeout_ms, null, output_limit_bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.StaggerAnchorFailed,
    };
    defer result.deinit(std.heap.page_allocator);
    if (result.timed_out) return error.StaggerAnchorTimedOut;
    switch (result.term) {
        .exited => |code| if (code != 0) return error.StaggerAnchorFailed,
        else => return error.StaggerAnchorFailed,
    }
}
