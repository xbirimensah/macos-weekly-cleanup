#!/bin/bash
# weekly-cleanup: frees disk space on macOS. It clears caches that apps rebuild
# on their own and archives unique data to an external drive before removing
# it. Every step skips itself when the owning app is running or the archive
# drive is missing.
#
#   weekly-cleanup.sh            clean
#   weekly-cleanup.sh --dry-run  only report what would be removed
#
# Settings: ~/.config/weekly-cleanup/config (see config.example).

set -uo pipefail
export LC_ALL=C   # ps/date parsing below expects English month and day names

STEPS="clones telegram unzip caches trash apps next packages"

# ------------------------------------------------------------- defaults
TELEGRAM_LIMIT_GB=10     # clear Telegram's media cache above this size
CACHE_AGE_DAYS=7         # ~/Library/Caches files untouched this long go
TRASH_AGE_DAYS=7         # items sitting in the Trash this long go
NEXT_AGE_DAYS=7          # .next build dirs untouched this long go
CLAUDE_VM_AGE_DAYS=14    # Claude desktop VM bundle unused this long goes
UNZIP_AGE_DAYS=2         # Unzip app extractions older than this get archived
NOTIFY_BELOW_GB=20       # macOS notification if free space ends below this
ARCHIVE_DIR=""           # where Unzip extractions are archived; empty = step off
SKIP_STEPS=""            # space-separated step names to skip

DRY=0
CONFIG="${WEEKLY_CLEANUP_CONFIG:-$HOME/.config/weekly-cleanup/config}"

say()     { printf '%s\n' "$*"; }
head2()   { printf '\n=== %s ===\n' "$*"; }
die()     { printf 'weekly-cleanup: %s\n' "$*" >&2; exit 2; }
free_gb() { df -g /System/Volumes/Data | awk 'NR==2{print $4}'; }
running() { pgrep -x "$1" >/dev/null 2>&1; }
trim()    { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# Reads KEY=value lines. Only known keys are accepted; the file is parsed,
# never executed.
load_config() {
  [ -f "$CONFIG" ] || return 0
  local line key val n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1))
    line=$(trim "$line")
    case "$line" in ''|'#'*) continue ;; esac
    [ "${line#*=}" != "$line" ] || die "$CONFIG line $n: expected KEY=value"
    key=$(trim "${line%%=*}")
    val=$(trim "${line#*=}")
    val="${val#\"}"; val="${val%\"}"
    case "$key" in
      TELEGRAM_LIMIT_GB|CACHE_AGE_DAYS|TRASH_AGE_DAYS|NEXT_AGE_DAYS|CLAUDE_VM_AGE_DAYS|UNZIP_AGE_DAYS|NOTIFY_BELOW_GB)
        [[ "$val" =~ ^[0-9]{1,4}$ ]] || die "$CONFIG line $n: $key must be a whole number"
        printf -v "$key" '%s' "$val" ;;
      ARCHIVE_DIR) ARCHIVE_DIR="${val/#\~/$HOME}" ;;
      SKIP_STEPS)  SKIP_STEPS="$val" ;;
      *) die "$CONFIG line $n: unknown key '$key'" ;;
    esac
  done < "$CONFIG"
  local s
  for s in $SKIP_STEPS; do
    case " $STEPS " in *" $s "*) ;; *) die "SKIP_STEPS: unknown step '$s' (steps: $STEPS)" ;; esac
  done
}

init_paths() {
  [ -n "${HOME:-}" ] && [ "$HOME" != "/" ] && [ -d "$HOME" ] || die "HOME is not set to a real folder"
  LIB="$HOME/Library"
  TMP_X="${WEEKLY_CLEANUP_TMP_X:-$(dirname "$(getconf DARWIN_USER_TEMP_DIR)")/X}"
  TG_GROUP="$LIB/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram"
  UNZIP_DIR="$LIB/Containers/com.Ababe.UnzipAnyFile/Data/Library/Application Support"
  CLAUDE_SUPPORT="$LIB/Application Support/Claude"
  DISCORD_SUPPORT="$LIB/Application Support/discord"
}

# Removes a path. Only paths inside the folders this script cleans are
# allowed, plus .next folders under $HOME. Everything else is refused.
nuke() {
  local p="${1:?}" root allowed=0
  case "$p" in
    *$'\n'*|*"/../"*|*"/.."|*"/./"*) say "  REFUSED (unsafe path): $p"; return 1 ;;
    "$HOME"/?*/.next) allowed=1 ;;
  esac
  for root in "$TMP_X" "$HOME/.Trash" "$UNZIP_DIR" "$TG_GROUP" "$CLAUDE_SUPPORT" "$DISCORD_SUPPORT"; do
    case "$p" in "$root"/?*) allowed=1 ;; esac
  done
  if [ "$allowed" = 0 ]; then say "  REFUSED (outside allowed roots): $p"; return 1; fi
  if [ "$DRY" = 1 ]; then say "  would remove: $p"; else rm -rf "${p:?}"; fi
}

# ------------------------------------------------- Chrome/Brave sign clones
# Chrome and Brave copy themselves into the temp dir on every launch and never
# delete old copies. A running browser still needs the clone made at its
# launch, so only clones older than the oldest running instance (minus a
# 10 minute margin) are removed.
step_clones() {
  local pair b proc d cutoff p t n c unreadable
  for pair in "com.google.Chrome:Google Chrome" "com.brave.Browser:Brave Browser"; do
    b="${pair%%:*}"; proc="${pair#*:}"
    d="$TMP_X/$b.code_sign_clone"
    [ -d "$d" ] || continue
    cutoff=$(( $(date +%s) - 3600 ))
    unreadable=0
    for p in $(pgrep -x "$proc"); do
      t=$(date -j -f "%a %b %d %T %Y" "$(ps -o lstart= -p "$p" | xargs)" +%s 2>/dev/null) \
        || { unreadable=1; break; }
      [ "$t" -lt "$cutoff" ] && cutoff=$t
    done
    # Without the browser's start time we can't tell which clone it uses.
    if [ "$unreadable" = 1 ]; then say "  $b: could not read the browser's start time, skipped"; continue; fi
    cutoff=$((cutoff - 600))
    n=0
    while IFS= read -r -d '' c; do
      [ "$(stat -f %m "$c")" -lt "$cutoff" ] || continue
      nuke "$c" && n=$((n+1))
    done < <(find "$d" -mindepth 1 -maxdepth 1 -type d -name 'code_sign_clone.*' -print0)
    say "  $b: $n stale clones $([ "$DRY" = 1 ] && echo 'would be ')removed (kept anything newer than $(date -r "$cutoff" '+%F %R'))"
  done
}

# ---------------------------------------------------------- Telegram media
# Telegram re-downloads media on demand. Prefer setting a cache limit inside
# Telegram (Settings > Data and Storage > Storage Usage); this is a backstop.
step_telegram() {
  local media gb was_running f
  for media in "$TG_GROUP"/appstore/account-*/postbox/media; do
    [ -d "$media" ] || continue
    gb=$(du -sg "$media" 2>/dev/null | cut -f1)
    say "  media cache: ${gb:-0}GB (limit ${TELEGRAM_LIMIT_GB}GB)"
    [ "${gb:-0}" -lt "$TELEGRAM_LIMIT_GB" ] && continue
    if [ "$DRY" = 1 ]; then say "  would quit Telegram, clear the cache, relaunch"; continue; fi
    was_running=0
    if running Telegram; then
      was_running=1
      osascript -e 'quit app "Telegram"' >/dev/null 2>&1 && sleep 5
    fi
    if running Telegram; then say "  Telegram would not quit, skipped"; continue; fi
    while IFS= read -r -d '' f; do nuke "$f"; done < <(find "$media" -mindepth 1 -maxdepth 1 -print0)
    [ "$was_running" = 1 ] && open -g -a Telegram
    say "  cleared"
  done
}

# ------------------------------------------------ Unzip app extractions
# The "Unzip - RAR ZIP 7Z Unarchiver" app keeps a full extracted copy of every
# archive in its container. Each extraction is copied to ARCHIVE_DIR, every
# file is compared byte for byte with its copy there, and only then is the
# local copy removed. Anything that does not match stays.
archive_one() {
  local src="$1" name dst f checked=0 bad=0
  name=$(basename "$src"); dst="$ARCHIVE_DIR/$name"
  if [ "$DRY" = 1 ]; then say "  would archive: $name -> $dst"; return 1; fi
  if ! rsync -a --ignore-existing "$src/" "$dst/" 2>/dev/null; then
    say "  copy failed for $name, kept local copy"; return 1
  fi
  while IFS= read -r -d '' f; do
    checked=$((checked+1))
    cmp -s "$src/$f" "$dst/$f" || bad=$((bad+1))
  done < <(cd "$src" && find . -type f ! -name '._*' ! -name .DS_Store -print0)
  if [ "$checked" = 0 ]; then say "  no files found in $name, kept"; return 1; fi
  if [ "$bad" = 0 ]; then say "  archived: $name"; return 0; fi
  say "  MISMATCH ($bad of $checked files differ in $dst), kept local copy"; return 1
}

step_unzip() {
  [ -d "$UNZIP_DIR" ] || { say "  none"; return; }
  [ -n "$ARCHIVE_DIR" ] || { say "  ARCHIVE_DIR not set, skipped"; return; }
  [ -d "$ARCHIVE_DIR" ] || { say "  $ARCHIVE_DIR not mounted, skipped"; return; }
  local hashdir ok src loose
  while IFS= read -r -d '' hashdir; do
    loose=$(find "$hashdir" -mindepth 1 -maxdepth 1 ! -type d ! -name '._*' ! -name .DS_Store | head -1)
    if [ -n "$loose" ]; then say "  loose files in $(basename "$hashdir"), kept"; continue; fi
    ok=1
    while IFS= read -r -d '' src; do
      archive_one "$src" || ok=0
    done < <(find "$hashdir" -mindepth 1 -maxdepth 1 -type d -print0)
    [ "$ok" = 1 ] && nuke "$hashdir"
  done < <(find "$UNZIP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$UNZIP_AGE_DAYS" \
             -regex '.*/[0-9A-F]\{32\}$' -print0)
}

# ------------------------------------------------------- ~/Library/Caches
step_caches() {
  local before
  before=$(du -sm "$LIB/Caches" 2>/dev/null | cut -f1)
  if [ "$DRY" = 1 ]; then
    say "  would remove $(find "$LIB/Caches" -type f -mtime +"$CACHE_AGE_DAYS" 2>/dev/null | wc -l | tr -d ' ') files older than ${CACHE_AGE_DAYS}d"
  else
    find "$LIB/Caches" -type f -mtime +"$CACHE_AGE_DAYS" -delete 2>/dev/null
    find "$LIB/Caches" -mindepth 1 -type d -empty -delete 2>/dev/null
  fi
  say "  ${before:-0}MB -> $(du -sm "$LIB/Caches" 2>/dev/null | cut -f1)MB"
}

# ------------------------------------------------------------------ Trash
# Uses ctime: moving a file to the Trash updates ctime, not mtime.
step_trash() {
  local n=0 t
  while IFS= read -r -d '' t; do nuke "$t" && n=$((n+1)); done \
    < <(find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -ctime +"$TRASH_AGE_DAYS" -print0 2>/dev/null)
  say "  $n items older than ${TRASH_AGE_DAYS}d $([ "$DRY" = 1 ] && echo 'would be ')removed"
}

# ----------------------------------------------------- app-specific caches
step_apps() {
  local d old name builds=() vm="$CLAUDE_SUPPORT/vm_bundles/claudevm.bundle"
  if running Claude; then
    say "  Claude running, skipped"
  else
    # "Unused" = nothing inside the bundle changed within the age limit.
    if [ -d "$vm" ] && [ -z "$(find "$vm" -mtime -"$CLAUDE_VM_AGE_DAYS" -print -quit 2>/dev/null)" ]; then
      nuke "$vm" && say "  Claude VM bundle removed (unused ${CLAUDE_VM_AGE_DAYS}d+)"
    fi
    for d in Cache "Code Cache"; do [ -d "$CLAUDE_SUPPORT/$d" ] && nuke "$CLAUDE_SUPPORT/$d"; done
  fi
  if running Discord; then
    say "  Discord running, skipped"
  else
    for d in Cache download; do [ -d "$DISCORD_SUPPORT/$d" ] && nuke "$DISCORD_SUPPORT/$d"; done
    # keep only the newest app-x.y.z build
    for d in "$DISCORD_SUPPORT"/app-*; do
      name=$(basename "$d")
      [ -d "$d" ] && [[ "$name" =~ ^app-[0-9][0-9.]*$ ]] && builds+=("$name")
    done
    if [ "${#builds[@]}" -gt 1 ]; then
      printf '%s\n' "${builds[@]}" | sort -V | sed '$d' \
        | while IFS= read -r old; do nuke "$DISCORD_SUPPORT/$old"; done
    fi
  fi
  return 0
}

# ---------------------------------------------------------- .next builds
step_next() {
  if pgrep -f "next dev|next start|next-server" >/dev/null; then
    say "  a Next server is running, skipped"; return
  fi
  local d
  while IFS= read -r -d '' d; do
    say "  $(du -sh "$d" 2>/dev/null | cut -f1) ${d#"$HOME"/}"; nuke "$d"
  done < <(find "$HOME" -xdev -path "$LIB" -prune -o -type d -name node_modules -prune \
             -o -type d -name .next -mtime +"$NEXT_AGE_DAYS" -prune -print0 2>/dev/null)
}

# ------------------------------------------------------- package caches
step_packages() {
  if [ "$DRY" = 1 ]; then say "  would run brew cleanup, pip/uv/npm cache clean"; return; fi
  command -v brew >/dev/null && brew cleanup --prune=all -s 2>&1 | tail -1
  command -v pip3 >/dev/null && pip3 cache purge 2>&1 | tail -1
  command -v uv   >/dev/null && uv cache clean 2>&1 | tail -1
  command -v npm  >/dev/null && npm cache clean --force >/dev/null 2>&1 && say "  npm cache cleaned"
  return 0
}

run_step() {
  local name="$1" title="$2"
  head2 "$title"
  case " $SKIP_STEPS " in *" $name "*) say "  skipped (SKIP_STEPS)"; return ;; esac
  "step_$name"
}

main() {
  case "${1:-}" in
    "") ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown option '$1' (use --dry-run or --help)" ;;
  esac
  load_config
  init_paths

  say "Weekly cleanup - $(date '+%F %T')$([ "$DRY" = 1 ] && echo ' (DRY RUN)')"
  local start end d up
  start=$(free_gb)
  say "free before: ${start}GB"

  # Telegram and Unzip data sit behind macOS App Data protection. Under
  # launchd this only works once weekly-cleanup-runner has Full Disk Access.
  if [ -d "$TG_GROUP" ] && ! ls "$TG_GROUP" >/dev/null 2>&1; then
    say "WARNING: no Full Disk Access - Telegram/Unzip steps will be skipped."
    say "  Fix: System Settings > Privacy & Security > Full Disk Access > + weekly-cleanup-runner"
  fi

  run_step clones   "BROWSER CODE-SIGN CLONES"
  run_step telegram "TELEGRAM"
  run_step unzip    "UNZIP APP EXTRACTIONS"
  run_step caches   "LIBRARY CACHES"
  run_step trash    "TRASH"
  run_step apps     "APP CACHES"
  run_step next     "NEXT.JS BUILD DIRS"
  run_step packages "PACKAGE CACHES"

  head2 "REPORT ONLY (needs a human)"
  up=$(du -sg /Library/Updates 2>/dev/null | cut -f1)
  say "  /Library/Updates: ${up:-0}GB (needs sudo)"

  end=$(free_gb)
  head2 "DONE"
  d=$((end - start))
  say "free: ${start}GB -> ${end}GB ($([ "$d" -ge 0 ] && echo +)${d}GB)"
  if [ "$end" -lt "$NOTIFY_BELOW_GB" ]; then
    osascript -e "display notification \"Only ${end}GB free after cleanup\" with title \"Weekly cleanup\"" 2>/dev/null
  fi
  exit 0
}

# Sourcing the file (tests) defines the functions without running anything.
# The runner passes the script text with bash -c, where BASH_SOURCE is empty.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then main "$@"; fi
