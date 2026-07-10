const std = @import("std");
const runtime = @import("../core/runtime.zig");
const stagger = @import("../core/stagger.zig");
const registry_common = @import("../registry/common.zig");

pub const schema_version: u32 = 1;
const max_file_bytes = 64 * 1024;

pub const Config = struct {
    account_keys: [2][]u8,
    policy: stagger.Policy,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.account_keys) |key| allocator.free(key);
        self.* = undefined;
    }
};

pub const AccountState = struct {
    account_key: []u8,
    due_at: ?i64,
    last_anchor_at: ?i64,
};

pub const State = struct {
    accounts: [2]AccountState,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.accounts) |account| allocator.free(account.account_key);
        self.* = undefined;
    }
};

pub const Scheduler = struct {
    config: Config,
    state: State,

    pub fn deinit(self: *Scheduler, allocator: std.mem.Allocator) void {
        self.config.deinit(allocator);
        self.state.deinit(allocator);
        self.* = undefined;
    }
};

const ConfigFile = struct {
    schema_version: u32,
    account_keys: [2][]const u8,
    policy: stagger.Policy,
};

const StateFile = struct {
    schema_version: u32,
    accounts: [2]AccountStateFile,
};

const AccountStateFile = struct {
    account_key: []const u8,
    due_at: ?i64,
    last_anchor_at: ?i64,
};

pub fn load(allocator: std.mem.Allocator, codex_home: []const u8) !Scheduler {
    const config_path = try configPath(allocator, codex_home);
    defer allocator.free(config_path);
    const state_path = try statePath(allocator, codex_home);
    defer allocator.free(state_path);

    const config_data = try readPrivateFile(allocator, config_path);
    defer allocator.free(config_data);
    const state_data = try readPrivateFile(allocator, state_path);
    defer allocator.free(state_data);

    var config_parsed = std.json.parseFromSlice(ConfigFile, allocator, config_data, .{}) catch return error.InvalidSchedulerData;
    defer config_parsed.deinit();
    var state_parsed = std.json.parseFromSlice(StateFile, allocator, state_data, .{}) catch return error.InvalidSchedulerData;
    defer state_parsed.deinit();

    if (config_parsed.value.schema_version != schema_version or state_parsed.value.schema_version != schema_version) {
        return error.InvalidSchedulerData;
    }

    var config = try copyConfig(allocator, config_parsed.value);
    errdefer config.deinit(allocator);
    var state = try copyState(allocator, state_parsed.value);
    errdefer state.deinit(allocator);
    try validate(&config, &state);
    return .{ .config = config, .state = state };
}

pub fn save(allocator: std.mem.Allocator, codex_home: []const u8, config: *const Config, state: *const State) !void {
    try validate(config, state);
    try registry_common.ensureAccountsDir(allocator, codex_home);

    const config_path = try configPath(allocator, codex_home);
    defer allocator.free(config_path);
    const state_path = try statePath(allocator, codex_home);
    defer allocator.free(state_path);

    var config_writer: std.Io.Writer.Allocating = .init(allocator);
    defer config_writer.deinit();
    try std.json.Stringify.value(ConfigFile{
        .schema_version = schema_version,
        .account_keys = config.account_keys,
        .policy = config.policy,
    }, .{ .whitespace = .indent_2 }, &config_writer.writer);
    try writePrivateFileAtomic(config_path, config_writer.written());

    var state_writer: std.Io.Writer.Allocating = .init(allocator);
    defer state_writer.deinit();
    try std.json.Stringify.value(StateFile{
        .schema_version = schema_version,
        .accounts = .{
            stateFileAccount(state.accounts[0]),
            stateFileAccount(state.accounts[1]),
        },
    }, .{ .whitespace = .indent_2 }, &state_writer.writer);
    try writePrivateFileAtomic(state_path, state_writer.written());
}

pub fn configPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ codex_home, "accounts", "stagger-config.json" });
}

pub fn statePath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ codex_home, "accounts", "stagger-state.json" });
}

fn stateFileAccount(account: AccountState) AccountStateFile {
    return .{
        .account_key = account.account_key,
        .due_at = account.due_at,
        .last_anchor_at = account.last_anchor_at,
    };
}

fn readPrivateFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    try registry_common.hardenSensitiveFile(path);
    var file = try std.Io.Dir.cwd().openFile(runtime.io(), path, .{});
    defer file.close(runtime.io());
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(runtime.io(), &buffer);
    return reader.interface.allocRemaining(allocator, .limited(max_file_bytes));
}

fn copyConfig(allocator: std.mem.Allocator, file: ConfigFile) !Config {
    var config = Config{
        .account_keys = undefined,
        .policy = file.policy,
    };
    var copied: usize = 0;
    errdefer for (config.account_keys[0..copied]) |key| allocator.free(key);
    for (file.account_keys, 0..) |key, index| {
        config.account_keys[index] = try allocator.dupe(u8, key);
        copied += 1;
    }
    return config;
}

fn copyState(allocator: std.mem.Allocator, file: StateFile) !State {
    var state: State = .{ .accounts = undefined };
    var copied: usize = 0;
    errdefer for (state.accounts[0..copied]) |account| allocator.free(account.account_key);
    for (file.accounts, 0..) |account, index| {
        state.accounts[index] = .{
            .account_key = try allocator.dupe(u8, account.account_key),
            .due_at = account.due_at,
            .last_anchor_at = account.last_anchor_at,
        };
        copied += 1;
    }
    return state;
}

fn validate(config: *const Config, state: *const State) !void {
    if (!stagger.validPolicy(config.policy)) return error.InvalidSchedulerData;
    if (config.account_keys[0].len == 0 or config.account_keys[1].len == 0) return error.InvalidSchedulerData;
    if (std.mem.eql(u8, config.account_keys[0], config.account_keys[1])) return error.InvalidSchedulerData;

    for (state.accounts, 0..) |account, index| {
        if (account.account_key.len == 0 or !std.mem.eql(u8, account.account_key, config.account_keys[index])) {
            return error.InvalidSchedulerData;
        }
    }
}

fn writePrivateFileAtomic(path: []const u8, data: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(runtime.io(), path, .{
        .replace = true,
        .permissions = registry_common.private_file_permissions,
    });
    defer atomic_file.deinit(runtime.io());
    var writer = atomic_file.file.writer(runtime.io(), &buffer);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
    try atomic_file.replace(runtime.io());
    try registry_common.hardenSensitiveFile(path);
}
