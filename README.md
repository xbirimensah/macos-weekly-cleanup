# macos-weekly-cleanup

A weekly disk cleanup for macOS that only removes things that come back on their own, like caches, build output and old browser copies. Unique data gets copied to an external drive and verified before the local copy is deleted.

It's a bash script, a launchd agent that runs it once a week, and a tiny Swift launcher that holds Full Disk Access so `/bin/bash` doesn't need it.

```
launchd (weekly) -> weekly-cleanup-runner (Full Disk Access) -> weekly-cleanup.sh
```

## What it cleans

| Step | What | Rule |
|---|---|---|
| `clones` | Chrome and Brave `code_sign_clone` copies in the per-user temp folder | Both browsers copy themselves there on every launch and never clean up, so dozens pile up. Clones older than the oldest running browser are removed. |
| `telegram` | Telegram's media cache | Only when it's over `TELEGRAM_LIMIT_GB`. Telegram is quit first and reopened afterwards. It downloads media again when you need it. |
| `unzip` | Extracted copies kept by the "Unzip - RAR ZIP 7Z Unarchiver" app | Each extraction is copied to `ARCHIVE_DIR` and every file is checked for the same size there. Only then is the local copy removed. Anything that doesn't check out is kept. Off unless `ARCHIVE_DIR` is set. |
| `caches` | Files in `~/Library/Caches` | Untouched for `CACHE_AGE_DAYS` |
| `trash` | Items in `~/.Trash` | In the Trash for `TRASH_AGE_DAYS`. Measured from when the item was trashed, not when it was last edited. |
| `apps` | Claude desktop `Cache`/`Code Cache` and VM bundle, Discord `Cache`/`download` and old `app-*` builds | Only while the app is closed |
| `next` | `.next` build folders under your home folder | Untouched for `NEXT_AGE_DAYS`. Folders inside `node_modules` and `~/Library` are left alone. Skipped while a Next server is running. |
| `packages` | Homebrew, pip, uv and npm caches | Uses each tool's own clean command |

At the end it reports what needs `sudo` (`/Library/Updates`), prints free space before and after, and shows a macOS notification if free space is below `NOTIFY_BELOW_GB`.

## Safety

- Every removal goes through one function that only accepts paths inside the folders listed above (and `.next` folders). It refuses everything else, including paths with `..` or line breaks. All file lists are read null-separated, so odd file names can't split into other paths.
- Before an Unzip extraction is deleted, every file is compared byte for byte with its archived copy.
- `--dry-run` lists everything it would remove without touching anything. Run it first.
- The config file is parsed, never executed. Unknown keys and non-numeric values stop the run before anything is deleted.

### Full Disk Access

The runner is pinned to one exact version of the script. `install.sh` compiles the script's SHA-256 into the runner, and the runner refuses any other version. It reads the script once, checks it and hands bash that text, so the file can't be swapped in between. bash also gets a fixed environment (`HOME` from the user database, a fixed `PATH`), so environment variables can't change what it deletes. Editing the script means running `install.sh` again. That rebuilds the runner, and macOS then asks for Full Disk Access again.

One limit remains: the `packages` step runs `brew`, `pip3`, `uv` and `npm`, and they run with the runner's Full Disk Access. If you don't want that, add `packages` to `SKIP_STEPS`.

## Install

Requires macOS and the Xcode Command Line Tools (`xcode-select --install`) for `swiftc`.

```bash
git clone https://github.com/xbirimensah/macos-weekly-cleanup.git
cd macos-weekly-cleanup
tests/run.sh          # optional: runs against a throwaway fake home folder
./install.sh
~/bin/weekly-cleanup.sh --dry-run
```

By default it runs Saturdays at 12:00. If the Mac is asleep at that time, launchd runs it at the next wake. Change the schedule or the paths with environment variables:

```bash
WEEKDAY=0 HOUR=9 MINUTE=30 ./install.sh     # Sundays 09:30
BIN=~/.local/bin LABEL=com.you.cleanup ./install.sh
```

The Telegram and Unzip steps read app data that macOS protects. For those steps, give the runner Full Disk Access: **System Settings > Privacy & Security > Full Disk Access > +**, press Cmd+Shift+G and enter `~/bin/weekly-cleanup-runner`. The other steps work without it.

`install.sh` rebuilds the runner only when the script or the runner source changed. A rebuild changes the binary's signature, and macOS then drops the grant. If the runner is already in the Full Disk Access list, remove it with **-** and add it again. `install.sh` also refuses to overwrite an installed script you edited in place (`FORCE=1` overrides). Make your changes in the repo and reinstall.

## Configure

`~/.config/weekly-cleanup/config`, created from [`config.example`](config.example) on first install:

```ini
ARCHIVE_DIR=/Volumes/MyDrive/Archives
TRASH_AGE_DAYS=14
SKIP_STEPS=telegram next
```

## Use

```bash
~/bin/weekly-cleanup.sh --dry-run                     # preview
~/bin/weekly-cleanup.sh                               # run now
launchctl kickstart gui/$(id -u)/local.weekly-cleanup # run now through launchd (with Full Disk Access)
tail -50 ~/Library/Logs/weekly-cleanup.log            # last runs
```

## Uninstall

```bash
./uninstall.sh
```

This removes the agent, the script and the runner. It keeps your config and the log. Remove the runner from the Full Disk Access list by hand.

## Tests

```bash
tests/run.sh
```

The tests build a fake home folder in a temp directory, run the script against it (dry run and real), and check what was removed and what was kept. They also cover config validation, the path guard (including folder names with line breaks) and archive verification. If `swiftc` is installed, they also build a runner and check that it refuses an edited script and clears the environment. Steps that touch real apps or global caches (`telegram`, `apps`, `packages`) are skipped.

## License

MIT
