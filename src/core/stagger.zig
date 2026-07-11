const std = @import("std");

pub const Policy = struct {
    spacing_seconds: i64,
    safety_margin_seconds: i64,
    staleness_limit_seconds: i64,
    weekly_reserve_percent: f64,
};

pub const RateLimitWindow = struct {
    used_percent: f64,
    resets_at: i64,
};

pub const UsageSnapshot = struct {
    observed_at: i64,
    five_hour: RateLimitWindow,
    weekly: RateLimitWindow,
};

pub const Account = struct {
    key: []const u8,
    usage: ?UsageSnapshot,
    due_at: ?i64,
    last_anchor_at: ?i64,
};

pub const PauseReason = enum {
    no_accounts,
    invalid_policy,
    account_malformed,
    usage_missing,
    usage_stale,
    usage_malformed,
    weekly_reserve,
};

pub const WaitReason = enum {
    scheduled,
    spacing,
    five_hour_reset,
};

pub const AnchorDecision = struct {
    account_key: []const u8,
    next_due_at: i64,
};

pub const WaitDecision = struct {
    account_key: []const u8,
    until: i64,
    reason: WaitReason,
};

pub const PauseDecision = struct {
    account_key: ?[]const u8,
    reason: PauseReason,
};

pub const Decision = union(enum) {
    anchor: AnchorDecision,
    wait: WaitDecision,
    paused: PauseDecision,
};

const Candidate = struct {
    account_key: []const u8,
    due_at: i64,
};

const PauseCandidate = struct {
    candidate: Candidate,
    reason: PauseReason,
};

const Validation = union(enum) {
    valid,
    paused: PauseReason,
};

const GlobalSpacing = union(enum) {
    no_anchors,
    until: i64,
    invalid,
};

/// Produces one deterministic action from an immutable scheduling snapshot.
/// The caller owns all side effects. It may persist `next_due_at` as a
/// fail-closed duplicate guard before attempting an anchor.
pub fn plan(accounts: []const Account, now: i64, policy: Policy) Decision {
    if (!validPolicy(policy)) {
        return pause(null, .invalid_policy);
    }
    if (accounts.len == 0) {
        return pause(null, .no_accounts);
    }

    const account_count = std.math.cast(i64, accounts.len) orelse {
        return pause(null, .invalid_policy);
    };
    const rotation_seconds = std.math.mul(i64, account_count, policy.spacing_seconds) catch {
        return pause(null, .invalid_policy);
    };
    const next_due_at = std.math.add(i64, now, rotation_seconds) catch {
        return pause(null, .invalid_policy);
    };
    const global_spacing = globalSpacing(accounts, now, policy.spacing_seconds);
    if (global_spacing == .invalid) return pause(null, .account_malformed);

    var best_anchor: ?Candidate = null;
    var best_wait: ?WaitDecision = null;
    var best_pause: ?PauseCandidate = null;

    for (accounts, 0..) |account, index| {
        const due_at = account.due_at orelse now;
        const candidate = Candidate{ .account_key = account.key, .due_at = due_at };

        if (account.key.len == 0 or hasDuplicateKey(accounts, account.key, index)) {
            considerPause(&best_pause, candidate, .account_malformed);
            continue;
        }
        if (account.last_anchor_at) |last_anchor_at| {
            if (last_anchor_at > now) {
                considerPause(&best_pause, candidate, .account_malformed);
                continue;
            }
        }

        const snapshot = account.usage orelse {
            considerPause(&best_pause, candidate, .usage_missing);
            continue;
        };
        switch (validateUsage(snapshot, now, policy)) {
            .valid => {},
            .paused => |reason| {
                considerPause(&best_pause, candidate, reason);
                continue;
            },
        }

        if (snapshot.five_hour.used_percent < 100.0 and !hasRequiredHeadroom(snapshot.five_hour.used_percent, 1.0)) {
            considerPause(&best_pause, candidate, .usage_malformed);
            continue;
        }

        const weekly_required_remaining_percent = @max(1.0, policy.weekly_reserve_percent);
        if (!hasRequiredHeadroom(snapshot.weekly.used_percent, weekly_required_remaining_percent)) {
            considerPause(&best_pause, candidate, .weekly_reserve);
            continue;
        }

        var until = due_at;
        var wait_reason: WaitReason = .scheduled;

        switch (global_spacing) {
            .until => |spacing_until| if (spacing_until > until) {
                until = spacing_until;
                wait_reason = .spacing;
            },
            .no_anchors, .invalid => {},
        }

        if (snapshot.five_hour.used_percent >= 100.0) {
            const reset_until = std.math.add(i64, snapshot.five_hour.resets_at, policy.safety_margin_seconds) catch {
                considerPause(&best_pause, candidate, .usage_malformed);
                continue;
            };
            if (reset_until <= now) {
                considerPause(&best_pause, candidate, .usage_malformed);
                continue;
            }
            if (reset_until > until) {
                until = reset_until;
                wait_reason = .five_hour_reset;
            }
        }

        if (until > now) {
            considerWait(&best_wait, .{
                .account_key = account.key,
                .until = until,
                .reason = wait_reason,
            });
            continue;
        }

        considerCandidate(&best_anchor, candidate);
    }

    if (best_anchor) |candidate| {
        return .{ .anchor = .{
            .account_key = candidate.account_key,
            .next_due_at = next_due_at,
        } };
    }
    if (best_wait) |decision| {
        return .{ .wait = decision };
    }
    if (best_pause) |decision| {
        return pause(decision.candidate.account_key, decision.reason);
    }
    return pause(null, .account_malformed);
}

pub fn validPolicy(policy: Policy) bool {
    return policy.spacing_seconds > 0 and
        policy.safety_margin_seconds >= 0 and
        policy.staleness_limit_seconds > 0 and
        std.math.isFinite(policy.weekly_reserve_percent) and
        policy.weekly_reserve_percent >= 0.0 and
        policy.weekly_reserve_percent < 100.0;
}

fn validateUsage(snapshot: UsageSnapshot, now: i64, policy: Policy) Validation {
    if (snapshot.observed_at > now or
        !validPercent(snapshot.five_hour.used_percent) or
        !validPercent(snapshot.weekly.used_percent) or
        snapshot.five_hour.resets_at <= snapshot.observed_at or
        snapshot.weekly.resets_at <= snapshot.observed_at)
    {
        return .{ .paused = .usage_malformed };
    }

    const age = std.math.sub(i64, now, snapshot.observed_at) catch {
        return .{ .paused = .usage_malformed };
    };
    if (age > policy.staleness_limit_seconds or snapshot.weekly.resets_at <= now) {
        return .{ .paused = .usage_stale };
    }
    return .valid;
}

fn validPercent(value: f64) bool {
    return std.math.isFinite(value) and value >= 0.0 and value <= 100.0;
}

fn hasRequiredHeadroom(used_percent: f64, required_remaining_percent: f64) bool {
    return used_percent < 100.0 - required_remaining_percent;
}

fn hasDuplicateKey(accounts: []const Account, key: []const u8, index: usize) bool {
    for (accounts, 0..) |other, other_index| {
        if (index != other_index and std.mem.eql(u8, key, other.key)) return true;
    }
    return false;
}

fn globalSpacing(accounts: []const Account, now: i64, spacing_seconds: i64) GlobalSpacing {
    var latest_anchor_at: ?i64 = null;
    for (accounts) |account| {
        const last_anchor_at = account.last_anchor_at orelse continue;
        if (last_anchor_at > now) return .invalid;
        if (latest_anchor_at == null or last_anchor_at > latest_anchor_at.?) {
            latest_anchor_at = last_anchor_at;
        }
    }
    const last_anchor_at = latest_anchor_at orelse return .no_anchors;
    const until = std.math.add(i64, last_anchor_at, spacing_seconds) catch return .invalid;
    return .{ .until = until };
}

fn considerCandidate(best: *?Candidate, candidate: Candidate) void {
    if (best.* == null or candidateLess(candidate, best.*.?)) best.* = candidate;
}

fn considerPause(best: *?PauseCandidate, candidate: Candidate, reason: PauseReason) void {
    if (best.* == null or candidateLess(candidate, best.*.?.candidate)) {
        best.* = .{ .candidate = candidate, .reason = reason };
    }
}

fn considerWait(best: *?WaitDecision, candidate: WaitDecision) void {
    if (best.* == null or
        candidate.until < best.*.?.until or
        (candidate.until == best.*.?.until and std.mem.order(u8, candidate.account_key, best.*.?.account_key) == .lt))
    {
        best.* = candidate;
    }
}

fn candidateLess(left: Candidate, right: Candidate) bool {
    return left.due_at < right.due_at or
        (left.due_at == right.due_at and std.mem.order(u8, left.account_key, right.account_key) == .lt);
}

fn pause(account_key: ?[]const u8, reason: PauseReason) Decision {
    return .{ .paused = .{ .account_key = account_key, .reason = reason } };
}
