const std = @import("std");
const fs = @import("codex_auth").core.compat_fs;
const runtime = @import("codex_auth").core.runtime;
const scheduler = @import("codex_auth").stagger;

fn config(allocator: std.mem.Allocator) !scheduler.Config {
    return .{
        .account_keys = .{
            try allocator.dupe(u8, "account-a"),
            try allocator.dupe(u8, "account-b"),
        },
        .policy = .{
            .spacing_seconds = 9_000,
            .safety_margin_seconds = 60,
            .staleness_limit_seconds = 300,
            .weekly_reserve_percent = 5,
        },
    };
}

fn state(allocator: std.mem.Allocator) !scheduler.State {
    return .{ .accounts = .{
        .{ .account_key = try allocator.dupe(u8, "account-a"), .due_at = 100, .last_anchor_at = 50 },
        .{ .account_key = try allocator.dupe(u8, "account-b"), .due_at = null, .last_anchor_at = null },
    } };
}

test "scheduler storage round trips exactly two configured accounts and planner state" {
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const codex_home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(codex_home);

    var configured = try config(allocator);
    defer configured.deinit(allocator);
    var persisted_state = try state(allocator);
    defer persisted_state.deinit(allocator);
    try scheduler.save(allocator, codex_home, &configured, &persisted_state);

    var loaded = try scheduler.load(allocator, codex_home);
    defer loaded.deinit(allocator);
    try std.testing.expectEqualStrings("account-a", loaded.config.account_keys[0]);
    try std.testing.expectEqual(@as(?i64, 100), loaded.state.accounts[0].due_at);
    try std.testing.expectEqual(@as(?i64, null), loaded.state.accounts[1].last_anchor_at);
    try std.testing.expectEqual(@as(i64, 9_000), loaded.config.policy.spacing_seconds);
}

test "scheduler storage rejects a missing private state file" {
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const codex_home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(codex_home);

    try std.testing.expectError(error.FileNotFound, scheduler.load(allocator, codex_home));
}

test "scheduler storage rejects duplicate configured account keys" {
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const codex_home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(codex_home);
    try tmp.dir.makePath("accounts");
    try tmp.dir.writeFile(.{ .sub_path = "accounts/stagger-config.json", .data =
        \\{"schema_version":1,"account_keys":["same","same"],"policy":{"spacing_seconds":9000,"safety_margin_seconds":60,"staleness_limit_seconds":300,"weekly_reserve_percent":5}}
    });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/stagger-state.json", .data =
        \\{"schema_version":1,"accounts":[{"account_key":"same","due_at":100,"last_anchor_at":null},{"account_key":"same","due_at":null,"last_anchor_at":null}]}
    });

    try std.testing.expectError(error.InvalidSchedulerData, scheduler.load(allocator, codex_home));
}

test "scheduler storage rejects an unsupported configuration schema version" {
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const codex_home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(codex_home);
    try tmp.dir.makePath("accounts");
    try tmp.dir.writeFile(.{ .sub_path = "accounts/stagger-config.json", .data =
        \\{"schema_version":2,"account_keys":["account-a","account-b"],"policy":{"spacing_seconds":9000,"safety_margin_seconds":60,"staleness_limit_seconds":300,"weekly_reserve_percent":5}}
    });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/stagger-state.json", .data =
        \\{"schema_version":1,"accounts":[{"account_key":"account-a","due_at":100,"last_anchor_at":50},{"account_key":"account-b","due_at":null,"last_anchor_at":null}]}
    });

    try std.testing.expectError(error.InvalidSchedulerData, scheduler.load(allocator, codex_home));
}

test "scheduler storage rejects an unsupported state schema version" {
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const codex_home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(codex_home);
    try tmp.dir.makePath("accounts");
    try tmp.dir.writeFile(.{ .sub_path = "accounts/stagger-config.json", .data =
        \\{"schema_version":1,"account_keys":["account-a","account-b"],"policy":{"spacing_seconds":9000,"safety_margin_seconds":60,"staleness_limit_seconds":300,"weekly_reserve_percent":5}}
    });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/stagger-state.json", .data =
        \\{"schema_version":0,"accounts":[{"account_key":"account-a","due_at":100,"last_anchor_at":50},{"account_key":"account-b","due_at":null,"last_anchor_at":null}]}
    });

    try std.testing.expectError(error.InvalidSchedulerData, scheduler.load(allocator, codex_home));
}

test "scheduler storage rejects malformed policy values" {
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const codex_home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(codex_home);
    try tmp.dir.makePath("accounts");
    try tmp.dir.writeFile(.{ .sub_path = "accounts/stagger-config.json", .data =
        \\{"schema_version":1,"account_keys":["account-a","account-b"],"policy":{"spacing_seconds":0,"safety_margin_seconds":60,"staleness_limit_seconds":300,"weekly_reserve_percent":5}}
    });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/stagger-state.json", .data =
        \\{"schema_version":1,"accounts":[{"account_key":"account-a","due_at":100,"last_anchor_at":50},{"account_key":"account-b","due_at":null,"last_anchor_at":null}]}
    });

    try std.testing.expectError(error.InvalidSchedulerData, scheduler.load(allocator, codex_home));
}

test "scheduler storage rejects malformed state values" {
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const codex_home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(codex_home);
    try tmp.dir.makePath("accounts");
    try tmp.dir.writeFile(.{ .sub_path = "accounts/stagger-config.json", .data =
        \\{"schema_version":1,"account_keys":["account-a","account-b"],"policy":{"spacing_seconds":9000,"safety_margin_seconds":60,"staleness_limit_seconds":300,"weekly_reserve_percent":5}}
    });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/stagger-state.json", .data =
        \\{"schema_version":1,"accounts":[{"account_key":"account-a","due_at":"not-a-timestamp","last_anchor_at":50},{"account_key":"account-b","due_at":null,"last_anchor_at":null}]}
    });

    try std.testing.expectError(error.InvalidSchedulerData, scheduler.load(allocator, codex_home));
}

test "scheduler lock reports busy while another process holds it" {
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const codex_home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(codex_home);

    const ready_path = try std.fs.path.join(allocator, &.{ codex_home, "lock-ready" });
    defer allocator.free(ready_path);
    var env_map = try runtime.currentEnviron().createMap(allocator);
    defer env_map.deinit();
    const lock_holder_exe = env_map.get("STAGGER_LOCK_HOLDER_EXE") orelse return error.SkipZigTest;
    try env_map.put("CODEX_HOME", codex_home);
    try env_map.put("STAGGER_LOCK_READY_PATH", ready_path);
    var child = try std.process.spawn(fs.io(), .{
        .argv = &.{
            lock_holder_exe,
        },
        .environ_map = &env_map,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(fs.io());

    var attempts: usize = 0;
    while (true) {
        fs.cwd().access(ready_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                attempts += 1;
                if (attempts == 100) return error.LockHolderDidNotStart;
                try std.Io.sleep(fs.io(), .fromMilliseconds(20), .awake);
                continue;
            },
            else => return err,
        };
        break;
    }

    const second = try scheduler.Lock.acquire(allocator, codex_home);
    switch (second) {
        .busy => {},
        .acquired => |lock| {
            var acquired = lock;
            acquired.release();
            return error.TestUnexpectedResult;
        },
    }
}
