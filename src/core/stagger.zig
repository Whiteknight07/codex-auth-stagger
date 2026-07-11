const std = @import("std");

pub const Policy = struct {
    spacing_seconds: i64,
    safety_margin_seconds: i64,
    staleness_limit_seconds: i64,
    // Retained in persisted scheduler data for compatibility; eligibility is fixed at 5%.
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
    is_active: bool = false,
};

pub const PauseReason = enum {
    no_accounts,
    invalid_policy,
    account_malformed,
    usage_missing,
    usage_stale,
    usage_malformed,
    usage_below_threshold,
};

pub const WaitReason = enum {
    scheduled,
    spacing,
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

const minimum_remaining_percent = 5.0;

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
    const active_account_ineligible = activeAccountIsIneligible(accounts, now, policy);

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

        switch (usageEligibility(account.usage, now, policy)) {
            .eligible => {},
            .paused => |reason| {
                considerPause(&best_pause, candidate, reason);
                continue;
            },
        }

        var until = if (active_account_ineligible and !account.is_active) now else due_at;
        var wait_reason: WaitReason = .scheduled;

        if (!active_account_ineligible) {
            switch (global_spacing) {
                .until => |spacing_until| if (spacing_until > until) {
                    until = spacing_until;
                    wait_reason = .spacing;
                },
                .no_anchors, .invalid => {},
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
        policy.staleness_limit_seconds > 0;
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

fn hasMinimumHeadroom(used_percent: f64) bool {
    return used_percent <= 100.0 - minimum_remaining_percent;
}

const UsageEligibility = union(enum) {
    eligible: UsageSnapshot,
    paused: PauseReason,
};

fn usageEligibility(maybe_snapshot: ?UsageSnapshot, now: i64, policy: Policy) UsageEligibility {
    const snapshot = maybe_snapshot orelse return .{ .paused = .usage_missing };
    switch (validateUsage(snapshot, now, policy)) {
        .valid => {},
        .paused => |reason| return .{ .paused = reason },
    }
    if (!hasMinimumHeadroom(snapshot.five_hour.used_percent) or
        !hasMinimumHeadroom(snapshot.weekly.used_percent))
    {
        return .{ .paused = .usage_below_threshold };
    }
    return .{ .eligible = snapshot };
}

fn activeAccountIsIneligible(accounts: []const Account, now: i64, policy: Policy) bool {
    for (accounts) |account| {
        if (!account.is_active) continue;
        return switch (usageEligibility(account.usage, now, policy)) {
            .eligible => false,
            .paused => true,
        };
    }
    return false;
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
