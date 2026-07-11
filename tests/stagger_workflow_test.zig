const std = @import("std");
const fs = @import("codex_auth").core.compat_fs;
const coordinator = @import("codex_auth").stagger.coordinator;
const anchor = @import("codex_auth").stagger.anchor;
const registry = @import("codex_auth").registry;
const scheduler = @import("codex_auth").stagger;
const fixtures = @import("support/fixtures.zig");

const anchor_now: i64 = 2_000_000;
const spacing_seconds: i64 = 60;

const Recorder = struct {
    calls: usize = 0,
    argv: ?[]const []const u8 = null,
};

fn record(context: ?*anyopaque, _: []const u8, argv: []const []const u8) !void {
    const recorder: *Recorder = @ptrCast(@alignCast(context.?));
    recorder.calls += 1;
    recorder.argv = argv;
}

const AnchorDirectoryRecorder = struct {
    allocator: std.mem.Allocator,
    paths: [3]?[]u8 = .{ null, null, null },
    calls: usize = 0,

    fn deinit(self: *AnchorDirectoryRecorder) void {
        for (self.paths) |path| if (path) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

fn recordEmptyAnchorDirectory(context: ?*anyopaque, working_directory: []const u8, _: []const []const u8) !void {
    const recorder: *AnchorDirectoryRecorder = @ptrCast(@alignCast(context.?));
    var dir = try fs.cwd().openDir(working_directory, .{ .iterate = true });
    defer dir.close();
    var iterator = dir.iterate();
    try std.testing.expect(try iterator.next() == null);
    const directory_stat = try fs.cwd().statFile(working_directory);
    if (comptime @import("builtin").os.tag != .windows) {
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), directory_stat.permissions.toMode() & 0o777);
    }
    try dir.writeFile(.{ .sub_path = "anchor-marker", .data = "present only during this anchor" });
    recorder.paths[recorder.calls] = try recorder.allocator.dupe(u8, working_directory);
    recorder.calls += 1;
}

fn recordEmptyAnchorDirectoryThenFail(context: ?*anyopaque, working_directory: []const u8, argv: []const []const u8) !void {
    try recordEmptyAnchorDirectory(context, working_directory, argv);
    return error.TestAnchorRunnerFailed;
}

fn failAnchor(_: ?*anyopaque, _: []const u8, _: []const []const u8) !void {
    return error.StaggerAnchorFailed;
}

fn noRefresh(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: [2][]const u8) !coordinator.RefreshedUsage {
    return error.TestUnexpectedResult;
}

fn refreshSafeUsage(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: [2][]const u8) !coordinator.RefreshedUsage {
    return .{ .snapshots = .{ snapshot(anchor_now), snapshot(anchor_now) } };
}

fn expectArgv(actual: []const []const u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg);
    }
}

test "anchor runner uses the complete bounded read-only command" {
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const codex_home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(codex_home);
    var recorder = Recorder{};
    try anchor.run(allocator, codex_home, &recorder, record);
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try expectArgv(recorder.argv.?, &.{
        "codex",                "exec",                  "--model",  "gpt-5.6-luna",              "--ephemeral",
        "--ignore-user-config", "--ignore-rules",        "-c",       "approval_policy=\"never\"", "--sandbox",
        "read-only",            "--skip-git-repo-check", "OK only.",
    });
}

test "each anchor receives an empty private directory that is removed afterward" {
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const codex_home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(codex_home);
    const anchor_root = try std.fs.path.join(allocator, &.{ codex_home, "accounts", "stagger-anchor" });
    defer allocator.free(anchor_root);
    var recorder = AnchorDirectoryRecorder{ .allocator = allocator };
    defer recorder.deinit();

    try anchor.run(allocator, codex_home, &recorder, recordEmptyAnchorDirectory);
    try anchor.run(allocator, codex_home, &recorder, recordEmptyAnchorDirectory);
    try std.testing.expectError(error.TestAnchorRunnerFailed, anchor.run(allocator, codex_home, &recorder, recordEmptyAnchorDirectoryThenFail));

    try std.testing.expectEqual(@as(usize, 3), recorder.calls);
    const first_path = recorder.paths[0] orelse return error.TestUnexpectedResult;
    const second_path = recorder.paths[1] orelse return error.TestUnexpectedResult;
    const third_path = recorder.paths[2] orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, first_path, second_path));
    try std.testing.expect(!std.mem.eql(u8, second_path, third_path));
    var root = try fs.cwd().openDir(anchor_root, .{ .iterate = true });
    defer root.close();
    var iterator = root.iterate();
    try std.testing.expect(try iterator.next() == null);
}

const LaunchdRecorder = struct {
    loaded: bool = false,
    calls: usize = 0,
    bootouts: usize = 0,
};

fn recordLaunchd(context: ?*anyopaque, argv: []const []const u8) !void {
    const recorder: *LaunchdRecorder = @ptrCast(@alignCast(context.?));
    recorder.calls += 1;
    if (std.mem.eql(u8, argv[1], "print")) {
        if (!recorder.loaded) return error.StaggerLaunchdNotLoaded;
        return;
    }
    if (std.mem.eql(u8, argv[1], "bootstrap")) {
        recorder.loaded = true;
        return;
    }
    if (std.mem.eql(u8, argv[1], "bootout")) {
        recorder.loaded = false;
        recorder.bootouts += 1;
        return;
    }
    return error.TestUnexpectedResult;
}

test "launch lifecycle is idempotent and preserves scheduler data" {
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);
    var recorder = LaunchdRecorder{};

    try @import("codex_auth").stagger.launchd.lifecycleWithRunner(
        allocator,
        .enable,
        home,
        "/tmp/stagger-workflow/.codex",
        "/tmp/codex-auth-stagger",
        "/opt/homebrew/bin:/usr/bin",
        501,
        &recorder,
        recordLaunchd,
    );
    try std.testing.expect(recorder.loaded);
    try std.testing.expectEqual(@as(usize, 2), recorder.calls);

    try @import("codex_auth").stagger.launchd.lifecycleWithRunner(
        allocator,
        .disable,
        home,
        "/tmp/stagger-workflow/.codex",
        "/tmp/codex-auth-stagger",
        "/opt/homebrew/bin:/usr/bin",
        501,
        &recorder,
        recordLaunchd,
    );
    try std.testing.expect(!recorder.loaded);
    try std.testing.expectEqual(@as(usize, 1), recorder.bootouts);

    try @import("codex_auth").stagger.launchd.lifecycleWithRunner(
        allocator,
        .uninstall,
        home,
        "/tmp/stagger-workflow/.codex",
        "/tmp/codex-auth-stagger",
        "/opt/homebrew/bin:/usr/bin",
        501,
        &recorder,
        recordLaunchd,
    );
    try std.testing.expectEqual(@as(usize, 1), recorder.bootouts);

    const paths = try @import("codex_auth").stagger.launchd.paths(allocator, home);
    defer paths.deinit(allocator);
    try std.testing.expectError(error.FileNotFound, fs.cwd().access(paths.plist, .{}));
}

fn snapshot(now: i64) registry.RateLimitSnapshot {
    return .{
        .primary = .{ .used_percent = 10, .window_minutes = 300, .resets_at = now + 300 },
        .secondary = .{ .used_percent = 10, .window_minutes = 10_080, .resets_at = now + 10_080 },
        .credits = .{ .has_credits = false, .unlimited = false, .balance = null },
        .plan_type = .plus,
    };
}

fn seedScheduler(allocator: std.mem.Allocator, codex_home: []const u8, now: i64) !void {
    var reg = fixtures.makeEmptyRegistry();
    defer reg.deinit(allocator);
    try fixtures.appendAccount(allocator, &reg, "alpha@example.test", "alpha", .plus);
    try fixtures.appendAccount(allocator, &reg, "beta@example.test", "beta", .plus);
    for (reg.accounts.items) |*account| {
        account.last_usage = snapshot(now);
        account.last_usage_at = now;
    }
    try registry.saveRegistry(allocator, codex_home, &reg);

    for ([_][]const u8{ "alpha@example.test", "beta@example.test" }, reg.accounts.items) |email, account| {
        const path = try registry.accountAuthPath(allocator, codex_home, account.account_key);
        defer allocator.free(path);
        const auth_json = try fixtures.authJsonWithEmailPlan(allocator, email, "plus");
        defer allocator.free(auth_json);
        try fs.cwd().writeFile(.{ .sub_path = path, .data = auth_json });
    }

    var config = scheduler.Config{
        .account_keys = .{
            try allocator.dupe(u8, reg.accounts.items[0].account_key),
            try allocator.dupe(u8, reg.accounts.items[1].account_key),
        },
        .policy = .{
            .spacing_seconds = spacing_seconds,
            .safety_margin_seconds = 0,
            .staleness_limit_seconds = 300,
            .weekly_reserve_percent = 5,
        },
    };
    defer config.deinit(allocator);
    var state = scheduler.State{ .accounts = .{
        .{ .account_key = try allocator.dupe(u8, config.account_keys[0]), .due_at = now, .last_anchor_at = null },
        .{ .account_key = try allocator.dupe(u8, config.account_keys[1]), .due_at = now + spacing_seconds, .last_anchor_at = null },
    } };
    defer state.deinit(allocator);
    try scheduler.save(allocator, codex_home, &config, &state);
}

test "one-shot ticks rotate A then B then A through a fake anchor" {
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const codex_home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(codex_home);
    try seedScheduler(allocator, codex_home, anchor_now);
    var recorder = Recorder{};
    for ([_]i64{ anchor_now, anchor_now + spacing_seconds, anchor_now + 2 * spacing_seconds }) |now| {
        _ = try coordinator.tick(allocator, codex_home, .{ .dry_run = false, .use_api = false }, .{
            .context = &recorder,
            .now_seconds = now,
            .refresh_usage = noRefresh,
            .run_anchor = record,
        });
    }
    try std.testing.expectEqual(@as(usize, 3), recorder.calls);

    var persisted = try scheduler.load(allocator, codex_home);
    defer persisted.deinit(allocator);
    try std.testing.expectEqual(anchor_now + 2 * spacing_seconds, persisted.state.accounts[0].last_anchor_at.?);
    try std.testing.expectEqual(anchor_now + spacing_seconds, persisted.state.accounts[1].last_anchor_at.?);
}

test "dry run does not persist state activate an account or anchor" {
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const codex_home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(codex_home);
    try seedScheduler(allocator, codex_home, anchor_now);
    var recorder = Recorder{};

    _ = try coordinator.tick(allocator, codex_home, .{ .dry_run = true, .use_api = false }, .{
        .context = &recorder,
        .now_seconds = anchor_now,
        .refresh_usage = noRefresh,
        .run_anchor = record,
    });
    try std.testing.expectEqual(@as(usize, 0), recorder.calls);

    var persisted = try scheduler.load(allocator, codex_home);
    defer persisted.deinit(allocator);
    try std.testing.expectEqual(@as(?i64, null), persisted.state.accounts[0].last_anchor_at);
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    try std.testing.expect(reg.active_account_key == null);
}

test "a fresh API usage check replaces stale cached usage before planning" {
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const codex_home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(codex_home);
    try seedScheduler(allocator, codex_home, anchor_now - 1_000);
    var recorder = Recorder{};

    const outcome = try coordinator.tick(allocator, codex_home, .{ .dry_run = false, .use_api = true }, .{
        .context = &recorder,
        .now_seconds = anchor_now,
        .refresh_usage = refreshSafeUsage,
        .run_anchor = record,
    });

    try std.testing.expectEqual(coordinator.Outcome.anchored, outcome);
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
}

test "paid credit status and balance do not affect eligible account selection" {
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const codex_home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(codex_home);
    try seedScheduler(allocator, codex_home, anchor_now);
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (reg.accounts.items[0].last_usage) |*last_usage| {
        last_usage.credits = .{
            .has_credits = true,
            .unlimited = false,
            .balance = try allocator.dupe(u8, "1000"),
        };
    } else return error.TestUnexpectedResult;
    try registry.saveRegistry(allocator, codex_home, &reg);
    var recorder = Recorder{};

    const outcome = try coordinator.tick(allocator, codex_home, .{ .dry_run = false, .use_api = false }, .{
        .context = &recorder,
        .now_seconds = anchor_now,
        .refresh_usage = noRefresh,
        .run_anchor = record,
    });

    try std.testing.expectEqual(coordinator.Outcome.anchored, outcome);
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
}

test "unusable active usage fails over to an eligible peer immediately" {
    const UnusableUsage = enum { stale, missing, malformed, exact_window_missing };
    const unusable_usage = [_]UnusableUsage{ .stale, .missing, .malformed, .exact_window_missing };

    for (unusable_usage) |case| {
        var tmp = fs.tmpDir(.{});
        defer tmp.cleanup();
        const allocator = std.testing.allocator;
        const codex_home = try tmp.dir.realpathAlloc(allocator, ".");
        defer allocator.free(codex_home);
        try seedScheduler(allocator, codex_home, anchor_now);

        {
            var reg = try registry.loadRegistry(allocator, codex_home);
            defer reg.deinit(allocator);
            const active_account = &reg.accounts.items[0];
            switch (case) {
                .stale => active_account.last_usage_at = anchor_now - 301,
                .missing => if (active_account.last_usage) |*last_usage| {
                    registry.freeRateLimitSnapshot(allocator, last_usage);
                    active_account.last_usage = null;
                } else return error.TestUnexpectedResult,
                .malformed => if (active_account.last_usage) |*last_usage| {
                    if (last_usage.primary) |*five_hour| {
                        five_hour.used_percent = 101;
                    } else return error.TestUnexpectedResult;
                } else return error.TestUnexpectedResult,
                .exact_window_missing => if (active_account.last_usage) |*last_usage| {
                    if (last_usage.secondary) |*weekly| {
                        weekly.window_minutes = 60;
                    } else return error.TestUnexpectedResult;
                } else return error.TestUnexpectedResult,
            }
            try registry.activateAccountByKey(allocator, codex_home, &reg, active_account.account_key);
            try registry.saveRegistry(allocator, codex_home, &reg);
        }

        {
            var persisted = try scheduler.load(allocator, codex_home);
            defer persisted.deinit(allocator);
            persisted.state.accounts[0].last_anchor_at = anchor_now;
            persisted.state.accounts[1].due_at = anchor_now + 10_000;
            try scheduler.save(allocator, codex_home, &persisted.config, &persisted.state);
        }

        var recorder = Recorder{};
        const outcome = try coordinator.tick(allocator, codex_home, .{ .dry_run = false, .use_api = false }, .{
            .context = &recorder,
            .now_seconds = anchor_now,
            .refresh_usage = noRefresh,
            .run_anchor = record,
        });

        try std.testing.expectEqual(coordinator.Outcome.anchored, outcome);
        try std.testing.expectEqual(@as(usize, 1), recorder.calls);
        var active = try registry.loadRegistry(allocator, codex_home);
        defer active.deinit(allocator);
        try std.testing.expectEqualStrings(active.accounts.items[1].account_key, active.active_account_key orelse return error.TestUnexpectedResult);
    }
}

test "anchor failure keeps the provisional duplicate guard across a retry" {
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const codex_home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(codex_home);
    try seedScheduler(allocator, codex_home, anchor_now);

    try std.testing.expectError(error.StaggerAnchorFailed, coordinator.tick(allocator, codex_home, .{ .dry_run = false, .use_api = false }, .{
        .context = null,
        .now_seconds = anchor_now,
        .refresh_usage = noRefresh,
        .run_anchor = failAnchor,
    }));
    const outcome = try coordinator.tick(allocator, codex_home, .{ .dry_run = false, .use_api = false }, .{
        .context = null,
        .now_seconds = anchor_now + 1,
        .refresh_usage = noRefresh,
        .run_anchor = record,
    });
    try std.testing.expectEqual(coordinator.Outcome.waiting, outcome);
}

test "activation failure keeps the provisional duplicate guard across a retry" {
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const codex_home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(codex_home);
    try seedScheduler(allocator, codex_home, anchor_now);
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    const auth_path = try registry.accountAuthPath(allocator, codex_home, reg.accounts.items[0].account_key);
    defer allocator.free(auth_path);
    try fs.cwd().deleteFile(auth_path);

    try std.testing.expectError(error.StaggerActivationFailed, coordinator.tick(allocator, codex_home, .{ .dry_run = false, .use_api = false }, .{
        .context = null,
        .now_seconds = anchor_now,
        .refresh_usage = noRefresh,
        .run_anchor = record,
    }));
    const outcome = try coordinator.tick(allocator, codex_home, .{ .dry_run = false, .use_api = false }, .{
        .context = null,
        .now_seconds = anchor_now + 1,
        .refresh_usage = noRefresh,
        .run_anchor = record,
    });
    try std.testing.expectEqual(coordinator.Outcome.waiting, outcome);
}
