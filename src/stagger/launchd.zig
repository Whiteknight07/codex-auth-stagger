const std = @import("std");
const runtime = @import("../core/runtime.zig");
const registry = @import("../registry/root.zig");
const cli = @import("../cli/root.zig");

pub const label = "com.loongphy.codex-auth.stagger";

pub const Paths = struct {
    plist: []u8,
    stdout_log: []u8,
    stderr_log: []u8,

    pub fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.plist);
        allocator.free(self.stdout_log);
        allocator.free(self.stderr_log);
    }
};

pub const RenderOptions = struct {
    home: []const u8,
    codex_home: []const u8,
    path: []const u8,
    executable: []const u8,
};

pub const Command = enum {
    bootstrap,
    bootout,
    print,
};

pub const CommandPlan = struct {
    argv: []const []const u8,
    domain_target: []u8,

    pub fn deinit(self: CommandPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.domain_target);
        allocator.free(self.argv);
    }
};

pub fn printReportsServiceNotFound(stderr: []const u8) bool {
    const trimmed = std.mem.trim(u8, stderr, " \t\r\n");
    return std.mem.indexOf(u8, trimmed, "Could not find service") != null or
        std.mem.indexOf(u8, trimmed, "service not found") != null;
}

pub const CommandRunner = *const fn (context: ?*anyopaque, argv: []const []const u8) anyerror!void;

pub fn lifecycleWithRunner(allocator: std.mem.Allocator, action: cli.types.StaggerAction, home: []const u8, codex_home: []const u8, executable: []const u8, path: []const u8, uid: u32, context: ?*anyopaque, runner: CommandRunner) !void {
    const launch_paths = try paths(allocator, home);
    defer launch_paths.deinit(allocator);
    switch (action) {
        .enable => {
            const agents = std.fs.path.dirname(launch_paths.plist) orelse return error.InvalidLaunchAgentPath;
            _ = try std.Io.Dir.cwd().createDirPathStatus(runtime.io(), agents, .default_dir);
            const logs = std.fs.path.dirname(launch_paths.stdout_log) orelse return error.InvalidLaunchAgentPath;
            _ = try std.Io.Dir.cwd().createDirPathStatus(runtime.io(), logs, .default_dir);
            try ensurePrivateLog(launch_paths.stdout_log);
            try ensurePrivateLog(launch_paths.stderr_log);
            const plist = try render(allocator, .{ .home = home, .codex_home = codex_home, .path = path, .executable = executable });
            defer allocator.free(plist);
            try writeAtomically(launch_paths.plist, plist);
            if (try isLoadedWithRunner(allocator, uid, launch_paths.plist, context, runner)) try runPlan(allocator, .bootout, uid, launch_paths.plist, context, runner);
            try runPlan(allocator, .bootstrap, uid, launch_paths.plist, context, runner);
        },
        .disable => if (try isLoadedWithRunner(allocator, uid, launch_paths.plist, context, runner)) try runPlan(allocator, .bootout, uid, launch_paths.plist, context, runner),
        .uninstall => {
            if (try isLoadedWithRunner(allocator, uid, launch_paths.plist, context, runner)) try runPlan(allocator, .bootout, uid, launch_paths.plist, context, runner);
            std.Io.Dir.cwd().deleteFile(runtime.io(), launch_paths.plist) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        },
        .status => _ = try isLoadedWithRunner(allocator, uid, launch_paths.plist, context, runner),
    }
}

pub fn isLoadedWithRunner(allocator: std.mem.Allocator, uid: u32, plist: []const u8, context: ?*anyopaque, runner: CommandRunner) !bool {
    runPlan(allocator, .print, uid, plist, context, runner) catch |err| switch (err) {
        error.StaggerLaunchdNotLoaded => return false,
        else => return err,
    };
    return true;
}
fn runPlan(allocator: std.mem.Allocator, command: Command, uid: u32, plist: []const u8, context: ?*anyopaque, runner: CommandRunner) !void {
    var plan = try commandPlan(allocator, command, uid, plist);
    defer plan.deinit(allocator);
    try runner(context, plan.argv);
}
fn ensurePrivateLog(path: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(runtime.io(), path, .{ .truncate = false, .permissions = registry.private_file_permissions });
    file.close(runtime.io());
    try registry.hardenSensitiveFile(path);
}
fn writeAtomically(path: []const u8, bytes: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(runtime.io(), path, .{ .replace = true, .permissions = registry.private_file_permissions });
    defer atomic.deinit(runtime.io());
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(runtime.io(), &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try atomic.replace(runtime.io());
}

pub fn paths(allocator: std.mem.Allocator, home: []const u8) !Paths {
    if (!std.fs.path.isAbsolute(home)) return error.HomePathNotAbsolute;

    const plist = try std.fs.path.join(allocator, &.{ home, "Library", "LaunchAgents", label ++ ".plist" });
    errdefer allocator.free(plist);
    const stdout_log = try std.fs.path.join(allocator, &.{ home, "Library", "Logs", "codex-auth-stagger.log" });
    errdefer allocator.free(stdout_log);
    const stderr_log = try std.fs.path.join(allocator, &.{ home, "Library", "Logs", "codex-auth-stagger-error.log" });
    return .{ .plist = plist, .stdout_log = stdout_log, .stderr_log = stderr_log };
}

pub fn render(allocator: std.mem.Allocator, options: RenderOptions) ![]u8 {
    if (!std.fs.path.isAbsolute(options.executable)) return error.ExecutablePathNotAbsolute;

    const launch_paths = try paths(allocator, options.home);
    defer launch_paths.deinit(allocator);

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    try writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key>
        \\  <string>com.loongphy.codex-auth.stagger</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\    <string>
    );
    try writeXmlEscaped(writer, options.executable);
    try writer.writeAll(
        \\</string>
        \\    <string>stagger</string>
        \\    <string>tick</string>
        \\  </array>
        \\  <key>EnvironmentVariables</key>
        \\  <dict>
        \\    <key>HOME</key>
        \\    <string>
    );
    try writeXmlEscaped(writer, options.home);
    try writer.writeAll(
        \\</string>
        \\    <key>CODEX_HOME</key>
        \\    <string>
    );
    try writeXmlEscaped(writer, options.codex_home);
    try writer.writeAll(
        \\</string>
        \\    <key>PATH</key>
        \\    <string>
    );
    try writeXmlEscaped(writer, options.path);
    try writer.writeAll(
        \\</string>
        \\  </dict>
        \\  <key>RunAtLoad</key>
        \\  <true/>
        \\  <key>StartInterval</key>
        \\  <integer>300</integer>
        \\  <key>ProcessType</key>
        \\  <string>Background</string>
        \\  <key>ThrottleInterval</key>
        \\  <integer>60</integer>
        \\  <key>StandardOutPath</key>
        \\  <string>
    );
    try writeXmlEscaped(writer, launch_paths.stdout_log);
    try writer.writeAll(
        \\</string>
        \\  <key>StandardErrorPath</key>
        \\  <string>
    );
    try writeXmlEscaped(writer, launch_paths.stderr_log);
    try writer.writeAll(
        \\</string>
        \\</dict>
        \\</plist>
    );
    return output.toOwnedSlice();
}

pub fn commandPlan(allocator: std.mem.Allocator, command: Command, uid: u32, plist: []const u8) !CommandPlan {
    const target = switch (command) {
        .bootstrap => try std.fmt.allocPrint(allocator, "gui/{d}", .{uid}),
        .bootout, .print => try std.fmt.allocPrint(allocator, "gui/{d}/{s}", .{ uid, label }),
    };
    errdefer allocator.free(target);

    const argv = try allocator.alloc([]const u8, if (command == .bootstrap) 4 else 3);
    errdefer allocator.free(argv);
    argv[0] = "launchctl";
    argv[1] = @tagName(command);
    argv[2] = target;
    if (command == .bootstrap) argv[3] = plist;
    return .{ .argv = argv, .domain_target = target };
}

fn writeXmlEscaped(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&apos;"),
        else => try writer.writeByte(byte),
    };
}
