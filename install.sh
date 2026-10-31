#!/bin/bash
# Installs weekly-cleanup for the current user:
#   $BIN/weekly-cleanup.sh        the cleanup script
#   $BIN/weekly-cleanup-runner    tiny launcher that holds Full Disk Access
#   ~/Library/LaunchAgents/<label>.plist   weekly launchd schedule
#
# Options (environment variables):
#   BIN=~/bin                  install folder
#   LABEL=local.weekly-cleanup launchd label
#   WEEKDAY=6 HOUR=12 MINUTE=0 schedule (0 or 7 = Sunday, 6 = Saturday)
#   FORCE=1                    overwrite an installed script that was edited locally
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN="${BIN:-$HOME/bin}"
LABEL="${LABEL:-local.weekly-cleanup}"
WEEKDAY="${WEEKDAY:-6}"; HOUR="${HOUR:-12}"; MINUTE="${MINUTE:-0}"
FORCE="${FORCE:-0}"

PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/weekly-cleanup.log"
CONF_DIR="$HOME/.config/weekly-cleanup"
SCRIPT="$BIN/weekly-cleanup.sh"
RUNNER="$BIN/weekly-cleanup-runner"
RUNNER_SRC_COPY="$BIN/.weekly-cleanup-runner.swift"

die() { printf 'install: %s\n' "$*" >&2; exit 1; }

validate() {
  [[ "$LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "LABEL may only contain letters, digits, dots and dashes"
  [[ "$WEEKDAY" =~ ^[0-7]$ ]] || die "WEEKDAY must be 0-7"
  [[ "$HOUR" =~ ^([01]?[0-9]|2[0-3])$ ]] || die "HOUR must be 0-23"
  [[ "$MINUTE" =~ ^[0-5]?[0-9]$ ]] || die "MINUTE must be 0-59"
  case "$BIN$HOME" in *'"'*|*'<'*|*'>'*|*'&'*|*$'\n'*) die "BIN or HOME contains characters that break the plist" ;; esac
  command -v swiftc >/dev/null || die "swiftc not found (install the Xcode Command Line Tools: xcode-select --install)"
}

# Refuse to set up a second agent next to one installed under another label,
# and never overwrite an unrelated agent that happens to use the same label.
check_labels() {
  local f
  for f in "$HOME"/Library/LaunchAgents/*.plist; do
    [ -f "$f" ] && [ "$f" != "$PLIST" ] || continue
    if grep -qF "<string>$RUNNER</string>" "$f"; then
      die "already installed as $(basename "$f" .plist). Rerun with LABEL=$(basename "$f" .plist)"
    fi
  done
  if [ -f "$PLIST" ] && ! grep -qF "<string>$RUNNER</string>" "$PLIST"; then
    die "$PLIST exists and belongs to something else. Pick another LABEL."
  fi
}

# Never silently replace a script that was edited in place and is newer.
install_script() {
  mkdir -p "$BIN"
  if [ -f "$SCRIPT" ] && ! cmp -s "$REPO/weekly-cleanup.sh" "$SCRIPT" \
     && [ "$SCRIPT" -nt "$REPO/weekly-cleanup.sh" ] && [ "$FORCE" != 1 ]; then
    die "$SCRIPT was edited locally and is newer than the repo copy.
  See the difference: diff '$REPO/weekly-cleanup.sh' '$SCRIPT'
  Move your edits into the repo, or rerun with FORCE=1 to overwrite."
  fi
  install -m 755 "$REPO/weekly-cleanup.sh" "$SCRIPT"
  echo "script:  $SCRIPT"
}

# The runner is pinned to the installed script's SHA-256. Rebuilding changes
# the binary's signature, which makes macOS drop its Full Disk Access, so it
# is only rebuilt when the script or the runner source changed.
RUNNER_REBUILT=0
install_runner() {
  local pinned
  pinned="$("$REPO/runner/build.sh" source "$SCRIPT")"
  if [ -x "$RUNNER" ] && [ -f "$RUNNER_SRC_COPY" ] && [ "$pinned" = "$(cat "$RUNNER_SRC_COPY")" ]; then
    echo "runner:  $RUNNER (unchanged, Full Disk Access kept)"; return
  fi
  "$REPO/runner/build.sh" binary "$SCRIPT" "$RUNNER" "$LABEL.runner"
  printf '%s\n' "$pinned" > "$RUNNER_SRC_COPY"; chmod 644 "$RUNNER_SRC_COPY"
  RUNNER_REBUILT=1
  echo "runner:  $RUNNER (rebuilt, needs Full Disk Access again, see below)"
}

install_config() {
  mkdir -p "$CONF_DIR"
  if [ ! -f "$CONF_DIR/config" ]; then
    install -m 600 "$REPO/config.example" "$CONF_DIR/config"
    echo "config:  $CONF_DIR/config (new, all defaults)"
  else
    echo "config:  $CONF_DIR/config (kept)"
  fi
}

install_plist() {
  mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$RUNNER</string>
	</array>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Weekday</key>
		<integer>$WEEKDAY</integer>
		<key>Hour</key>
		<integer>$HOUR</integer>
		<key>Minute</key>
		<integer>$MINUTE</integer>
	</dict>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>
	<key>StandardOutPath</key>
	<string>$LOG</string>
	<key>StandardErrorPath</key>
	<string>$LOG</string>
	<key>LowPriorityIO</key>
	<true/>
	<key>Nice</key>
	<integer>10</integer>
	<key>RunAtLoad</key>
	<false/>
</dict>
</plist>
EOF
  plutil -lint "$PLIST" >/dev/null || die "generated plist is invalid: $PLIST"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "launchd: $LABEL (weekday $WEEKDAY, $(printf '%02d:%02d' "$HOUR" "$MINUTE"))"
}

validate
check_labels
install_script
install_runner
install_config
install_plist

cat <<EOF

Next:
  1. Try it:        $SCRIPT --dry-run
  2. Settings:      $CONF_DIR/config  (set ARCHIVE_DIR to enable the Unzip step)
  3. Telegram/Unzip steps need Full Disk Access for the runner:
     System Settings > Privacy & Security > Full Disk Access > + $RUNNER
     (Cmd+Shift+G in the file picker to type the path)
EOF
if [ "$RUNNER_REBUILT" = 1 ]; then
  echo "     The runner was rebuilt: if it is already in that list, remove it with - and add it again."
fi
echo "  Log: $LOG"
