const std = @import("std");
const http = @import("../api/http.zig");

const timeout_ms: u64 = 15_000;
const output_limit_bytes: usize = 1024;

pub const Runner = *const fn (context: ?*anyopaque, argv: []const []const u8) anyerror!void;

pub fn run(context: ?*anyopaque, runner: Runner) !void {
    const argv = [_][]const u8{
        "codex", "exec", "--model", "gpt-5.6-luna", "--ephemeral", "--ignore-user-config", "--ignore-rules", "-c", "approval_policy=\"never\"", "--sandbox", "read-only", "--skip-git-repo-check", "Reply exactly hi. Do not use tools.",
    };
    try runner(context, &argv);
}

pub fn runProduction(_: ?*anyopaque, argv: []const []const u8) !void {
    var result = http.runChildCaptureWithOutputLimit(std.heap.page_allocator, argv, timeout_ms, null, output_limit_bytes) catch |err| switch (err) {
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
