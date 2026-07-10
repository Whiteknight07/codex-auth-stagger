const std = @import("std");
const cli = @import("../cli/root.zig");
const runtime = @import("../core/runtime.zig");
const registry = @import("../registry/root.zig");
const scheduler = @import("../stagger/root.zig");
const lock_mod = @import("../stagger/lock.zig");
const preflight = @import("preflight.zig");
const query = @import("query.zig");
const http = @import("../api/http.zig");
const launchd = @import("../stagger/launchd.zig");
const coordinator = @import("../stagger/coordinator.zig");
const anchor_mod = @import("../stagger/anchor.zig");

const safety_margin_seconds: i64 = 60;
const staleness_limit_seconds: i64 = 5 * 60;
const anchor_timeout_ms: u64 = 15_000;
const anchor_output_limit_bytes: usize = 1024;

pub fn handle(allocator: std.mem.Allocator, codex_home: []const u8, options: cli.types.StaggerOptions) !void {
    handleInner(allocator, codex_home, options) catch |err| {
        if (staggerErrorMessage(err)) |message| {
            try writeError(message);
        }
        return err;
    };
}

fn handleInner(allocator: std.mem.Allocator, codex_home: []const u8, options: cli.types.StaggerOptions) !void {
    switch (options) {
        .configure => |configure| try configureScheduler(allocator, codex_home, configure),
        .tick => |tick_options| try tick(allocator, codex_home, tick_options),
        .action => |action| if (action == .status)
            try status(allocator, codex_home)
        else
            try lifecycle(allocator, codex_home, action),
    }
}

fn status(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    var persisted = scheduler.load(allocator, codex_home) catch |err| switch (err) {
        error.FileNotFound => {
            try writeLine("Stagger scheduler is not configured.");
            return;
        },
        else => return err,
    };
    defer persisted.deinit(allocator);
    if (@import("builtin").os.tag != .macos) {
        try writeLine("Stagger scheduler is configured for two accounts; LaunchAgent integration is unavailable on this platform.");
        return;
    }
    const home = try registry.resolveUserHome(allocator);
    defer allocator.free(home);
    const paths = try launchd.paths(allocator, home);
    defer paths.deinit(allocator);
    std.Io.Dir.cwd().access(runtime.io(), paths.plist, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try writeLine("Stagger scheduler is configured for two accounts; the LaunchAgent is not installed.");
            return;
        },
        else => return err,
    };
    const uid: u32 = @intCast(std.c.getuid());
    const loaded = try launchd.isLoadedWithRunner(allocator, uid, paths.plist, null, productionCommandRunner);
    if (loaded) {
        try writeLine("Stagger scheduler is configured for two accounts; the LaunchAgent is loaded. Account identities are hidden.");
    } else {
        try writeLine("Stagger scheduler is configured for two accounts; the LaunchAgent is installed but not loaded. Account identities are hidden.");
    }
}

pub fn configureScheduler(allocator: std.mem.Allocator, codex_home: []const u8, options: cli.types.StaggerConfigureOptions) !void {
    var lock = switch (try lock_mod.Lock.acquire(allocator, codex_home)) {
        .busy => return error.StaggerBusy,
        .acquired => |value| value,
    };
    defer lock.release();
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    const primary = try resolveUniqueSelector(allocator, &reg, options.primary_selector);
    const secondary = try resolveUniqueSelector(allocator, &reg, options.secondary_selector);
    if (std.mem.eql(u8, primary, secondary)) return error.StaggerSelectorsMustBeDistinct;

    const now = std.Io.Timestamp.now(runtime.io(), .real).toSeconds();
    const spacing = @as(i64, options.spacing_minutes) * 60;
    var config = scheduler.Config{ .account_keys = .{
        try allocator.dupe(u8, primary), try allocator.dupe(u8, secondary),
    }, .policy = .{
        .spacing_seconds = spacing,
        .safety_margin_seconds = safety_margin_seconds,
        .staleness_limit_seconds = staleness_limit_seconds,
        .weekly_reserve_percent = @floatFromInt(options.weekly_reserve_percent),
    } };
    defer config.deinit(allocator);
    var state = scheduler.State{ .accounts = .{
        .{ .account_key = try allocator.dupe(u8, primary), .due_at = now, .last_anchor_at = null },
        .{ .account_key = try allocator.dupe(u8, secondary), .due_at = now + spacing, .last_anchor_at = null },
    } };
    defer state.deinit(allocator);
    try scheduler.save(allocator, codex_home, &config, &state);
    try writeLine("Stagger scheduler configured for two accounts.");
}

fn tick(allocator: std.mem.Allocator, codex_home: []const u8, options: cli.types.StaggerTickOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    const outcome = try coordinator.tick(allocator, codex_home, .{
        .dry_run = options.dry_run,
        .use_api = preflight.apiModeUsesApi(reg.api.usage, options.api_mode),
    }, .{
        .context = null,
        .now_seconds = std.Io.Timestamp.now(runtime.io(), .real).toSeconds(),
        .refresh_usage = coordinator.refreshSelectedUsage,
        .run_anchor = anchor_mod.runProduction,
    });
    switch (outcome) {
        .anchored => try writeLine("Stagger tick anchored an eligible account."),
        .waiting => try writeLine("Stagger tick is waiting for the next eligible window."),
        .paused => try writeLine("Stagger tick paused because usage data is not safe to schedule."),
        .dry_run => try writeLine("Stagger tick would anchor an eligible account."),
    }
}

fn resolveUniqueSelector(allocator: std.mem.Allocator, reg: *registry.Registry, selector: []const u8) ![]const u8 {
    var resolution = try query.resolveSwitchQueryLocally(allocator, reg, selector);
    defer resolution.deinit(allocator);
    return switch (resolution) {
        .direct => |key| key,
        .not_found => error.StaggerSelectorNotFound,
        .multiple => error.StaggerSelectorAmbiguous,
    };
}

fn lifecycle(allocator: std.mem.Allocator, codex_home: []const u8, action: cli.types.StaggerAction) !void {
    if (@import("builtin").os.tag != .macos) return error.StaggerLaunchdRequiresMacOS;
    const home = try registry.resolveUserHome(allocator);
    defer allocator.free(home);
    const executable_z = try std.process.executablePathAlloc(runtime.io(), allocator);
    defer allocator.free(executable_z);
    const executable: []const u8 = executable_z;
    var environment = try registry.getEnvMap(allocator);
    defer environment.deinit();
    const path = environment.get("PATH") orelse "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    const uid: u32 = @intCast(std.c.getuid());
    try launchd.lifecycleWithRunner(allocator, action, home, codex_home, executable, path, uid, null, productionCommandRunner);
    switch (action) {
        .status => try writeLine("Stagger LaunchAgent status checked."),
        .enable => try writeLine("Stagger scheduler enabled."),
        .disable => try writeLine("Stagger scheduler disabled."),
        .uninstall => try writeLine("Stagger scheduler uninstalled; scheduler data was retained."),
    }
}

fn productionCommandRunner(_: ?*anyopaque, argv: []const []const u8) !void {
    var result = http.runChildCaptureWithOutputLimit(std.heap.page_allocator, argv, anchor_timeout_ms, null, anchor_output_limit_bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.StaggerLaunchdFailed,
    };
    defer result.deinit(std.heap.page_allocator);
    if (result.timed_out) return error.StaggerLaunchdTimedOut;
    switch (result.term) {
        .exited => |code| if (code != 0) {
            if (std.mem.eql(u8, argv[1], "print") and launchd.printReportsServiceNotFound(result.stderr)) return error.StaggerLaunchdNotLoaded;
            return error.StaggerLaunchdFailed;
        },
        else => return error.StaggerLaunchdFailed,
    }
}

fn writeLine(line: []const u8) !void {
    var stdout: std.Io.File = .stdout();
    var buffer: [512]u8 = undefined;
    var writer = stdout.writer(runtime.io(), &buffer);
    try writer.interface.writeAll(line);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

fn writeError(line: []const u8) !void {
    var stderr: std.Io.File = .stderr();
    var buffer: [512]u8 = undefined;
    var writer = stderr.writer(runtime.io(), &buffer);
    try writer.interface.print("Error: {s}\n", .{line});
    try writer.interface.flush();
}

fn staggerErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.StaggerBusy => "The stagger scheduler is busy; try again after the current tick finishes.",
        error.StaggerNotConfigured => "The stagger scheduler is not configured.",
        error.StaggerSelectorNotFound => "A stagger account selector did not match a managed account.",
        error.StaggerSelectorAmbiguous => "A stagger account selector matched more than one managed account.",
        error.StaggerSelectorsMustBeDistinct => "The primary and secondary selectors must resolve to different accounts.",
        error.StaggerAccountMissing => "A configured stagger account is no longer available.",
        error.StaggerUsageMalformed, error.StaggerUsageRefreshFailed => "Usage data is unavailable or unsafe; no account was anchored.",
        error.StaggerActivationFailed, error.StaggerActivationUnverified => "Account activation could not be verified; no anchor was attempted.",
        error.StaggerAnchorTimedOut, error.StaggerAnchorFailed => "The anchor command did not complete successfully.",
        error.StaggerLaunchdRequiresMacOS => "LaunchAgent lifecycle commands require macOS.",
        error.StaggerLaunchdTimedOut, error.StaggerLaunchdFailed => "The macOS scheduler command did not complete successfully.",
        error.InvalidSchedulerData => "The stagger scheduler data is invalid; reconfigure it before running a tick.",
        else => null,
    };
}
