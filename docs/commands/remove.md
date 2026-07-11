# `codex-auth-stagger remove`

## Usage

```shell
codex-auth-stagger remove [--api|--skip-api]
codex-auth-stagger remove --live [--api|--skip-api]
codex-auth-stagger remove <query> [<query>...]
codex-auth-stagger remove --all
```

## Interactive Remove

`codex-auth-stagger remove` opens the remove picker.

- The default picker stays local-only so deletion is not blocked by refresh work.
- `--api` attempts a best-effort foreground refresh for picker display.
- `--skip-api` explicitly forbids remote refresh.
- `q` quits without deleting accounts.

## Live Remove

`codex-auth-stagger remove --live` keeps the picker open after each deletion.

- Removed rows disappear from the current display immediately.
- Existing row overlays stay in place until the next scheduled refresh.
- The active account shown after deletion comes from the persisted registry state.

## Query Remove

`codex-auth-stagger remove <query> [<query>...]` removes one or more accounts using stored local data.

Selectors can match:

- displayed row number,
- alias fragment,
- email fragment,
- account name fragment, or
- `account_key` fragment.

Selector-based remove does not accept `--live`, `--api`, or `--skip-api`.

If a selector matches multiple accounts in a TTY, `remove` asks for confirmation. If stdin is not a TTY, ambiguous matches fail and the user must refine the selector.

## Remove All

`codex-auth-stagger remove --all` clears all accounts tracked in `registry.json`.

- It does not accept `--live`, `--api`, or `--skip-api`.
- It deletes managed account snapshots and matching managed backups.
- It leaves malformed or unidentifiable backup files in place.

## Active Account Reconciliation

When the removed account was active:

- another remaining account is promoted when possible,
- `auth.json` is rewritten from the promoted account when safe,
- `auth.json` is deleted when no accounts remain and the current auth matches a tracked removed account,
- malformed or unsyncable `auth.json` is left untouched.

After a successful deletion, stdout prints `Removed N account(s): ...` in removal order.
