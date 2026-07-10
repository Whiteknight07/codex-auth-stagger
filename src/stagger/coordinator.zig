const std = @import("std");
const core = @import("../core/stagger.zig");
const registry = @import("../registry/root.zig");
const auth = @import("../auth/auth.zig");
const storage = @import("storage.zig");
const lock_mod = @import("lock.zig");
const anchor = @import("anchor.zig");
const usage_api = @import("../api/usage.zig");

const five_hours_minutes: i64 = 5 * 60;
const weekly_minutes: i64 = 7 * 24 * 60;

pub const Options = struct { dry_run: bool, use_api: bool };
pub const Outcome = enum { anchored, waiting, paused, dry_run };
pub const UsageRefresher = *const fn (?*anyopaque, std.mem.Allocator, []const u8, [2][]const u8) anyerror!RefreshedUsage;

pub const RefreshedUsage = struct {
    snapshots: [2]registry.RateLimitSnapshot,
    pub fn deinit(self: *RefreshedUsage, allocator: std.mem.Allocator) void {
        for (&self.snapshots) |*snapshot| registry.freeRateLimitSnapshot(allocator, snapshot);
        self.* = undefined;
    }
};

pub const Runtime = struct {
    context: ?*anyopaque,
    now_seconds: i64,
    refresh_usage: UsageRefresher,
    run_anchor: anchor.Runner,
};

pub fn tick(allocator: std.mem.Allocator, codex_home: []const u8, options: Options, runtime: Runtime) !Outcome {
    var lock = switch (try lock_mod.Lock.acquire(allocator, codex_home)) {
        .busy => return error.StaggerBusy,
        .acquired => |value| value,
    };
    defer lock.release();
    var persisted = storage.load(allocator, codex_home) catch |err| switch (err) {
        error.FileNotFound => return error.StaggerNotConfigured,
        else => return err,
    };
    defer persisted.deinit(allocator);
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    if (options.use_api) {
        var refreshed = try runtime.refresh_usage(runtime.context, allocator, codex_home, persisted.config.account_keys);
        defer refreshed.deinit(allocator);
        for (persisted.config.account_keys, refreshed.snapshots) |key, snapshot| {
            registry.updateUsage(allocator, &reg, key, try registry.cloneRateLimitSnapshot(allocator, snapshot));
        }
        if (!options.dry_run) try registry.saveRegistry(allocator, codex_home, &reg);
    }
    const accounts = try plannerAccounts(allocator, &persisted, &reg);
    defer allocator.free(accounts);
    switch (core.plan(accounts, runtime.now_seconds, persisted.config.policy)) {
        .anchor => |decision| {
            if (options.dry_run) return .dry_run;
            const index = stateIndex(&persisted.state, decision.account_key) orelse return error.InvalidSchedulerData;
            persisted.state.accounts[index].last_anchor_at = runtime.now_seconds;
            persisted.state.accounts[index].due_at = decision.next_due_at;
            try storage.save(allocator, codex_home, &persisted.config, &persisted.state);
            registry.activateAccountByKey(allocator, codex_home, &reg, decision.account_key) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return error.StaggerActivationFailed,
            };
            try registry.saveRegistry(allocator, codex_home, &reg);
            const active_path = try registry.activeAuthPath(allocator, codex_home);
            defer allocator.free(active_path);
            var current = auth.parseAuthInfo(allocator, active_path) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return error.StaggerActivationUnverified,
            };
            defer current.deinit(allocator);
            const active_key = current.record_key orelse return error.StaggerActivationUnverified;
            if (!std.mem.eql(u8, active_key, decision.account_key)) return error.StaggerActivationUnverified;
            try anchor.run(runtime.context, runtime.run_anchor);
            return .anchored;
        },
        .wait => return .waiting,
        .paused => return .paused,
    }
}

pub fn refreshSelectedUsage(_: ?*anyopaque, allocator: std.mem.Allocator, codex_home: []const u8, keys: [2][]const u8) !RefreshedUsage {
    var snapshots: [2]registry.RateLimitSnapshot = undefined;
    var count: usize = 0;
    errdefer for (snapshots[0..count]) |*snapshot| registry.freeRateLimitSnapshot(allocator, snapshot);
    for (keys, 0..) |key, index| {
        const auth_path = try registry.accountAuthPath(allocator, codex_home, key);
        defer allocator.free(auth_path);
        var result = try usage_api.fetchUsageForAuthPathDetailed(allocator, auth_path);
        errdefer if (result.snapshot) |*snapshot| registry.freeRateLimitSnapshot(allocator, snapshot);
        if (result.missing_auth or result.snapshot == null) return error.StaggerUsageRefreshFailed;
        if (result.status_code) |status| if (status < 200 or status > 299) return error.StaggerUsageRefreshFailed;
        snapshots[index] = result.snapshot.?;
        result.snapshot = null;
        count += 1;
    }
    return .{ .snapshots = snapshots };
}

fn plannerAccounts(allocator: std.mem.Allocator, persisted: *const storage.Scheduler, reg: *const registry.Registry) ![]core.Account {
    const result = try allocator.alloc(core.Account, 2);
    errdefer allocator.free(result);
    for (persisted.config.account_keys, 0..) |key, index| {
        const record_index = findAccountIndex(reg, key) orelse return error.StaggerAccountMissing;
        const record = &reg.accounts.items[record_index];
        result[index] = .{ .key = key, .usage = try mapUsage(record), .due_at = persisted.state.accounts[index].due_at, .last_anchor_at = persisted.state.accounts[index].last_anchor_at };
    }
    return result;
}

fn findAccountIndex(reg: *const registry.Registry, key: []const u8) ?usize {
    for (reg.accounts.items, 0..) |account, index| {
        if (std.mem.eql(u8, account.account_key, key)) return index;
    }
    return null;
}

fn stateIndex(state: *const storage.State, key: []const u8) ?usize {
    for (state.accounts, 0..) |account, index| if (std.mem.eql(u8, account.account_key, key)) return index;
    return null;
}
fn mapUsage(record: *const registry.AccountRecord) !?core.UsageSnapshot {
    const snapshot = record.last_usage orelse return null;
    const observed_at = record.last_usage_at orelse return error.StaggerUsageMalformed;
    const five = exactWindow(snapshot, five_hours_minutes) orelse return error.StaggerUsageMalformed;
    const week = exactWindow(snapshot, weekly_minutes) orelse return error.StaggerUsageMalformed;
    const credits = snapshot.credits orelse return error.StaggerUsageMalformed;
    return .{ .observed_at = observed_at, .five_hour = .{ .used_percent = five.used_percent, .resets_at = five.resets_at orelse return error.StaggerUsageMalformed }, .weekly = .{ .used_percent = week.used_percent, .resets_at = week.resets_at orelse return error.StaggerUsageMalformed }, .paid_credits_enabled = credits.has_credits or credits.unlimited };
}
fn exactWindow(snapshot: registry.RateLimitSnapshot, minutes: i64) ?registry.RateLimitWindow {
    var found: ?registry.RateLimitWindow = null;
    for ([_]?registry.RateLimitWindow{ snapshot.primary, snapshot.secondary }) |candidate| {
        const value = candidate orelse continue;
        if (value.window_minutes != null and value.window_minutes.? == minutes) {
            if (found != null) return null;
            found = value;
        }
    }
    return found;
}
