const std = @import("std");
const stagger = @import("codex_auth").core.stagger;

const five_hours: i64 = 5 * 60 * 60;
const one_week: i64 = 7 * 24 * 60 * 60;
const now: i64 = 2_000_000;

fn policy() stagger.Policy {
    return .{
        .spacing_seconds = 2 * 60 * 60 + 30 * 60,
        .safety_margin_seconds = 60,
        .staleness_limit_seconds = 5 * 60,
        .weekly_reserve_percent = 5,
    };
}

fn usage(observed_at: i64, five_hour_used: f64, weekly_used: f64) stagger.UsageSnapshot {
    return .{
        .observed_at = observed_at,
        .five_hour = .{ .used_percent = five_hour_used, .resets_at = now + five_hours },
        .weekly = .{ .used_percent = weekly_used, .resets_at = now + one_week },
    };
}

fn account(key: []const u8, due_at: ?i64, snapshot: ?stagger.UsageSnapshot) stagger.Account {
    return .{
        .key = key,
        .usage = snapshot,
        .due_at = due_at,
        .last_anchor_at = null,
    };
}

test "oldest overdue eligible account wins" {
    const accounts = [_]stagger.Account{
        account("later", now - 10, usage(now, 20, 20)),
        account("oldest", now - 100, usage(now, 30, 30)),
    };

    const decision = stagger.plan(accounts[0..], now, policy());
    try std.testing.expectEqualStrings("oldest", decision.anchor.account_key);
    try std.testing.expectEqual(now + 2 * policy().spacing_seconds, decision.anchor.next_due_at);
}

test "equal due times use account key as deterministic tie breaker" {
    const accounts = [_]stagger.Account{
        account("beta", now - 100, usage(now, 20, 20)),
        account("alpha", now - 100, usage(now, 20, 20)),
    };

    const decision = stagger.plan(accounts[0..], now, policy());
    try std.testing.expectEqualStrings("alpha", decision.anchor.account_key);
}

test "future due account waits" {
    const accounts = [_]stagger.Account{
        account("alpha", now + 300, usage(now, 10, 10)),
    };

    const decision = stagger.plan(accounts[0..], now, policy());
    try std.testing.expectEqual(now + 300, decision.wait.until);
}

test "last anchor enforces spacing and prevents a duplicate anchor" {
    var configured = account("alpha", now - 1000, usage(now, 10, 10));
    configured.last_anchor_at = now - 60;
    const accounts = [_]stagger.Account{configured};

    const decision = stagger.plan(accounts[0..], now, policy());
    try std.testing.expectEqual(now - 60 + policy().spacing_seconds, decision.wait.until);
}

test "first anchor schedules from now instead of catching up from an old due time" {
    const accounts = [_]stagger.Account{
        account("alpha", now - (10 * policy().spacing_seconds), usage(now, 10, 10)),
    };

    const decision = stagger.plan(accounts[0..], now, policy());
    try std.testing.expectEqual(now + policy().spacing_seconds, decision.anchor.next_due_at);
}

test "two accounts rotate anchors at spacing intervals" {
    var rotation_policy = policy();
    rotation_policy.spacing_seconds = 60;
    var accounts = [_]stagger.Account{
        account("A", now, usage(now, 10, 10)),
        account("B", now, usage(now, 10, 10)),
    };
    const spacing = rotation_policy.spacing_seconds;

    const first = stagger.plan(accounts[0..], now, rotation_policy);
    try std.testing.expectEqualStrings("A", first.anchor.account_key);
    try std.testing.expectEqual(now + 2 * spacing, first.anchor.next_due_at);
    accounts[0].last_anchor_at = now;
    accounts[0].due_at = first.anchor.next_due_at;

    accounts[0].usage = usage(now + spacing, 10, 10);
    accounts[1].usage = usage(now + spacing, 10, 10);
    const second = stagger.plan(accounts[0..], now + spacing, rotation_policy);
    try std.testing.expectEqualStrings("B", second.anchor.account_key);
    try std.testing.expectEqual(now + 3 * spacing, second.anchor.next_due_at);
    accounts[1].last_anchor_at = now + spacing;
    accounts[1].due_at = second.anchor.next_due_at;

    accounts[0].usage = usage(now + 2 * spacing, 10, 10);
    accounts[1].usage = usage(now + 2 * spacing, 10, 10);
    const third = stagger.plan(accounts[0..], now + 2 * spacing, rotation_policy);
    try std.testing.expectEqualStrings("A", third.anchor.account_key);
}

test "global anchor gap blocks another eligible account" {
    const planned_at = now + policy().spacing_seconds - 1;
    var first = account("A", now + 2 * policy().spacing_seconds, usage(planned_at, 10, 10));
    first.last_anchor_at = now;
    const accounts = [_]stagger.Account{
        first,
        account("B", now, usage(planned_at, 10, 10)),
    };

    const decision = stagger.plan(accounts[0..], planned_at, policy());
    try std.testing.expect(decision == .wait);
    try std.testing.expectEqualStrings("B", decision.wait.account_key);
    try std.testing.expectEqual(now + policy().spacing_seconds, decision.wait.until);
    try std.testing.expectEqual(stagger.WaitReason.spacing, decision.wait.reason);
}

test "rotation interval overflow pauses safely" {
    var overflowing_policy = policy();
    overflowing_policy.spacing_seconds = std.math.maxInt(i64);
    const accounts = [_]stagger.Account{
        account("A", now, usage(now, 10, 10)),
        account("B", now, usage(now, 10, 10)),
    };

    const decision = stagger.plan(accounts[0..], now, overflowing_policy);
    try std.testing.expectEqual(stagger.PauseReason.invalid_policy, decision.paused.reason);
}

test "future anchor timestamps and a full weekly reserve pause safely" {
    var future_anchor = account("A", now, usage(now, 10, 10));
    future_anchor.last_anchor_at = now + 1;
    const future_accounts = [_]stagger.Account{
        future_anchor,
        account("B", now, usage(now, 10, 10)),
    };
    try std.testing.expectEqual(
        stagger.PauseReason.account_malformed,
        stagger.plan(future_accounts[0..], now, policy()).paused.reason,
    );

    var full_reserve = policy();
    full_reserve.weekly_reserve_percent = 100;
    const accounts = [_]stagger.Account{account("A", now, usage(now, 10, 10))};
    try std.testing.expectEqual(
        stagger.PauseReason.invalid_policy,
        stagger.plan(accounts[0..], now, full_reserve).paused.reason,
    );
}

test "missing usage fails closed" {
    const accounts = [_]stagger.Account{account("alpha", now, null)};

    const decision = stagger.plan(accounts[0..], now, policy());
    try std.testing.expectEqual(stagger.PauseReason.usage_missing, decision.paused.reason);
}

test "stale usage fails closed" {
    const stale_at = now - policy().staleness_limit_seconds - 1;
    const accounts = [_]stagger.Account{
        account("alpha", now, usage(stale_at, 10, 10)),
    };

    const decision = stagger.plan(accounts[0..], now, policy());
    try std.testing.expectEqual(stagger.PauseReason.usage_stale, decision.paused.reason);
}

test "future observation and malformed percentages fail closed" {
    const future_usage = usage(now + 1, 10, 10);
    var malformed_usage = usage(now, 10, 10);
    malformed_usage.weekly.used_percent = 101;
    const future_accounts = [_]stagger.Account{account("future", now, future_usage)};
    const malformed_accounts = [_]stagger.Account{account("malformed", now, malformed_usage)};

    try std.testing.expectEqual(
        stagger.PauseReason.usage_malformed,
        stagger.plan(future_accounts[0..], now, policy()).paused.reason,
    );
    try std.testing.expectEqual(
        stagger.PauseReason.usage_malformed,
        stagger.plan(malformed_accounts[0..], now, policy()).paused.reason,
    );
}

test "an exhausted five hour reading after its reset fails closed" {
    var snapshot = usage(now - 120, 100, 10);
    snapshot.five_hour.resets_at = now - 60;
    const accounts = [_]stagger.Account{account("alpha", now, snapshot)};

    const decision = stagger.plan(accounts[0..], now, policy());
    try std.testing.expectEqual(stagger.PauseReason.usage_malformed, decision.paused.reason);
}

test "reset timestamps at the observation time are malformed" {
    var snapshot = usage(now, 10, 10);
    snapshot.five_hour.resets_at = now;
    const accounts = [_]stagger.Account{account("alpha", now, snapshot)};

    const decision = stagger.plan(accounts[0..], now, policy());
    try std.testing.expectEqual(stagger.PauseReason.usage_malformed, decision.paused.reason);
}

test "the exact one percent remaining boundary pauses both windows" {
    const accounts = [_]stagger.Account{
        account("five-hour", now, usage(now, 99, 20)),
        account("weekly", now, usage(now, 20, 99)),
    };

    var one_percent_only = policy();
    one_percent_only.weekly_reserve_percent = 0;
    try std.testing.expectEqual(stagger.PauseReason.usage_malformed, stagger.plan(accounts[0..1], now, one_percent_only).paused.reason);
    try std.testing.expectEqual(stagger.PauseReason.weekly_reserve, stagger.plan(accounts[1..], now, one_percent_only).paused.reason);
}

test "exhausted five hour window waits through reset safety margin" {
    var snapshot = usage(now, 100, 20);
    snapshot.five_hour.resets_at = now + 120;
    const accounts = [_]stagger.Account{account("alpha", now, snapshot)};

    const decision = stagger.plan(accounts[0..], now, policy());
    try std.testing.expectEqual(now + 120 + policy().safety_margin_seconds, decision.wait.until);
    try std.testing.expectEqual(stagger.WaitReason.five_hour_reset, decision.wait.reason);
}

test "weekly reserve is stricter than the one percent minimum" {
    const accounts = [_]stagger.Account{account("alpha", now, usage(now, 20, 95))};

    const decision = stagger.plan(accounts[0..], now, policy());
    try std.testing.expectEqual(stagger.PauseReason.weekly_reserve, decision.paused.reason);
}

test "paused account does not prevent another eligible account anchoring" {
    const accounts = [_]stagger.Account{
        account("weekly-blocked", now - 100, usage(now, 20, 96)),
        account("eligible", now - 50, usage(now, 20, 20)),
    };

    const decision = stagger.plan(accounts[0..], now, policy());
    try std.testing.expectEqualStrings("eligible", decision.anchor.account_key);
}

test "wait selects earliest safe time across temporarily blocked accounts" {
    var first = usage(now, 100, 20);
    first.five_hour.resets_at = now + 600;
    var second = usage(now, 100, 20);
    second.five_hour.resets_at = now + 300;
    const accounts = [_]stagger.Account{
        account("first", now, first),
        account("second", now, second),
    };

    const decision = stagger.plan(accounts[0..], now, policy());
    try std.testing.expectEqual(now + 300 + policy().safety_margin_seconds, decision.wait.until);
}

test "no configured accounts and invalid policy pause safely" {
    const no_accounts = [_]stagger.Account{};
    try std.testing.expectEqual(
        stagger.PauseReason.no_accounts,
        stagger.plan(no_accounts[0..], now, policy()).paused.reason,
    );

    var invalid = policy();
    invalid.spacing_seconds = 0;
    const accounts = [_]stagger.Account{account("alpha", now, usage(now, 20, 20))};
    try std.testing.expectEqual(
        stagger.PauseReason.invalid_policy,
        stagger.plan(accounts[0..], now, invalid).paused.reason,
    );
}
