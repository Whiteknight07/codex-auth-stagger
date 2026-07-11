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

test "future anchor timestamps pause safely and legacy weekly reserves do not affect policy validity" {
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

    var legacy_reserve = policy();
    legacy_reserve.weekly_reserve_percent = 100;
    const accounts = [_]stagger.Account{account("A", now, usage(now, 10, 10))};
    try std.testing.expectEqualStrings("A", stagger.plan(accounts[0..], now, legacy_reserve).anchor.account_key);
}

test "missing usage fails closed" {
    var active = account("alpha", now, null);
    active.is_active = true;
    const accounts = [_]stagger.Account{active};

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
    try std.testing.expectEqual(stagger.PauseReason.usage_below_threshold, decision.paused.reason);
}

test "reset timestamps at the observation time are malformed" {
    var snapshot = usage(now, 10, 10);
    snapshot.five_hour.resets_at = now;
    const accounts = [_]stagger.Account{account("alpha", now, snapshot)};

    const decision = stagger.plan(accounts[0..], now, policy());
    try std.testing.expectEqual(stagger.PauseReason.usage_malformed, decision.paused.reason);
}

test "the exact five percent remaining boundary is eligible for both windows" {
    const accounts = [_]stagger.Account{
        account("five-hour", now, usage(now, 95, 20)),
        account("weekly", now, usage(now, 20, 95)),
    };

    try std.testing.expectEqualStrings("five-hour", stagger.plan(accounts[0..1], now, policy()).anchor.account_key);
    try std.testing.expectEqualStrings("weekly", stagger.plan(accounts[1..], now, policy()).anchor.account_key);
}

test "a fully used five hour window is ineligible rather than waiting for reset" {
    var snapshot = usage(now, 100, 20);
    snapshot.five_hour.resets_at = now + 120;
    const accounts = [_]stagger.Account{account("alpha", now, snapshot)};

    const decision = stagger.plan(accounts[0..], now, policy());
    try std.testing.expectEqual(stagger.PauseReason.usage_below_threshold, decision.paused.reason);
}

test "less than five percent remaining pauses either exact window" {
    const five_hour_accounts = [_]stagger.Account{account("five-hour", now, usage(now, 96, 20))};
    const weekly_accounts = [_]stagger.Account{account("weekly", now, usage(now, 20, 96))};

    try std.testing.expectEqual(stagger.PauseReason.usage_below_threshold, stagger.plan(five_hour_accounts[0..], now, policy()).paused.reason);
    try std.testing.expectEqual(stagger.PauseReason.usage_below_threshold, stagger.plan(weekly_accounts[0..], now, policy()).paused.reason);
}

test "ineligible active usage immediately fails over despite a future peer due time" {
    const active_usage = [_]?stagger.UsageSnapshot{
        null,
        usage(now, 96, 20),
        usage(now - policy().staleness_limit_seconds - 1, 20, 20),
        usage(now, 101, 20),
    };

    for (active_usage) |maybe_usage| {
        var active = account("active", now, maybe_usage);
        active.last_anchor_at = now;
        active.is_active = true;
        const accounts = [_]stagger.Account{
            active,
            account("failover", now + 10_000, usage(now, 20, 20)),
        };

        const decision = stagger.plan(accounts[0..], now, policy());
        try std.testing.expectEqualStrings("failover", decision.anchor.account_key);
    }
}

test "paused account does not prevent another eligible account anchoring" {
    const accounts = [_]stagger.Account{
        account("weekly-blocked", now - 100, usage(now, 20, 96)),
        account("eligible", now - 50, usage(now, 20, 20)),
    };

    const decision = stagger.plan(accounts[0..], now, policy());
    try std.testing.expectEqualStrings("eligible", decision.anchor.account_key);
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
