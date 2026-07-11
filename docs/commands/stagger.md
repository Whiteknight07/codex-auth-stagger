# `codex-auth-stagger stagger`

`stagger` schedules two selected accounts into separate usage windows. It is designed for accounts you manage yourself and is deliberately conservative: when it cannot establish that an account is safe to use, it does not switch or anchor it.

## Usage

```shell
codex-auth-stagger stagger configure --primary <selector> --secondary <selector> [--spacing-minutes <1..299>] [--weekly-reserve-percent <0..99>]
codex-auth-stagger stagger tick [--dry-run] [--api|--skip-api]
codex-auth-stagger stagger status
codex-auth-stagger stagger enable
codex-auth-stagger stagger disable
codex-auth-stagger stagger uninstall
```

`configure` requires two distinct selectors. Selectors use the same local matching rules as `switch`; an unmatched or ambiguous selector is rejected. The default spacing is 150 minutes. `--weekly-reserve-percent` remains accepted for configuration compatibility, but no longer affects scheduling.

## Recommended Setup

1. Configure two distinct managed accounts.
2. Run `codex-auth-stagger stagger status` to confirm the saved configuration.
3. Run `codex-auth-stagger stagger tick --dry-run` and review the proposed outcome.
4. Enable the macOS scheduler only after the dry run is satisfactory.

```shell
codex-auth-stagger stagger configure --primary personal --secondary work
codex-auth-stagger stagger status
codex-auth-stagger stagger tick --dry-run
codex-auth-stagger stagger enable
```

Each scheduled invocation runs one `tick` and exits. `codex-auth-stagger` does not run a permanent daemon; on macOS, the operating system invokes future ticks.

## Usage Data and Safety

By default, a tick uses the configured API-refresh mode. `--api` explicitly refreshes usage before planning. This uses the undocumented OpenAI usage endpoint and sends the account access token to OpenAI; the endpoint or its response format may change or fail.

`--skip-api` makes the tick use only cached usage stored in the registry. It does not scan local session files. Cached data can be stale or incomplete, so this mode does not relax any safety checks.

The scheduler fails closed: it pauses rather than authorizing an anchor when the usage data is missing, stale, malformed, ambiguous, or below the safety threshold. An account must have at least 5% remaining in both the exact five-hour and weekly windows; a fully used five-hour window is not scheduled for its reset. Paid-credit status and balance never add capacity or affect account selection. If the active configured account is ineligible, another eligible configured account may anchor immediately without waiting for normal spacing or its own due time.

Anchors run `codex exec` from a fresh private empty directory inside `CODEX_HOME/accounts`, removed after the command completes, with read-only sandboxing, approval disabled, user config and rules ignored, and `--ephemeral`. Ephemeral anchors do not persist a Codex session, so there is no archive step to run.

Use `--dry-run` before enabling automation or after changing configuration. It shows the planning outcome without changing the active account or writing an anchor.

## Scheduling Scope

`enable`, `disable`, and `uninstall` are macOS-only lifecycle commands. `tick`, including `tick --dry-run`, is the cross-platform manual operation; run it yourself from a supported shell when no macOS scheduler is installed.

On macOS, scheduler output is written to private per-user logs:

- `~/Library/Logs/codex-auth-stagger.log`
- `~/Library/Logs/codex-auth-stagger-error.log`

Scheduler configuration and state are private files under `$CODEX_HOME/accounts/`, alongside the managed account data. Treat those files and logs as private: they may contain account-related operational information.

`disable` stops future scheduled ticks while preserving the LaunchAgent plist and the scheduler configuration and state, so it can be enabled again. `uninstall` removes the LaunchAgent plist but retains the scheduler configuration and state for a later reinstall or review.

## Returning to Manual Switching

Run `codex-auth-stagger stagger disable`, then use `codex-auth-stagger switch` as usual. Disabling the stagger scheduler does not remove managed accounts or change the currently active account.

If you kept a legacy switching fallback during migration, leave it stopped while stagger scheduling is enabled. Do not run two automatic switchers at once. After disabling stagger, you can continue manual switching without starting that fallback.

## Related Docs

- [switch](./switch.md)
- [API refresh](../api.md)
- [permissions](../permissions.md)
