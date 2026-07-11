# `codex-auth-stagger export`

## Usage

```shell
codex-auth-stagger export [<dir>]
codex-auth-stagger export --cpa [<dir>]
```

## Standard Export

- Exports stored account auth snapshots.
- A directory path writes direct child `*.auth.json` files to that directory.
- Without a directory path, files are written to `CODEX_HOME/accounts/backup`.
- The exported directory can be imported with `codex-auth-stagger import <dir>`.

## CLIProxyAPI Export

`--cpa` exports flat [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) token JSON.

- A directory path writes direct child `.json` files to that directory.
- Without a directory path, files are written to `CODEX_HOME/accounts/backup`.
- The exported directory can be imported with `codex-auth-stagger import --cpa <dir>`.

## Output

- `stdout` receives the number of exported accounts and destination directory.
