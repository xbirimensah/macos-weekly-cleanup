#!/bin/bash
# Runs weekly-cleanup.sh against a throwaway fake home folder and checks what
# it removed and what it kept. Nothing outside the temp folder is touched:
# the steps that act on real apps or global caches (telegram, apps, packages)
# are skipped via SKIP_STEPS.
#
#   tests/run.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/weekly-cleanup.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/weekly-cleanup-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

export HOME="$T/home"
export WEEKLY_CLEANUP_TMP_X="$T/tmpx"
export WEEKLY_CLEANUP_CONFIG="$T/config"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
exists()  { if [ -e "$1" ]; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
missing() { if [ -e "$1" ]; then bad "$2 (still there: $1)"; else ok "$2"; fi; }
contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (no '$2' in output)"; fi; }
old()  { touch -t "$(date -v-"$2"d +%Y%m%d%H%M)" "$1"; }

write_config() {
  cat > "$WEEKLY_CLEANUP_CONFIG" <<EOF
# test config
ARCHIVE_DIR = "$T/archive"
SKIP_STEPS=telegram apps packages
NOTIFY_BELOW_GB=0
$1
EOF
}

UNZIP="$HOME/Library/Containers/com.Ababe.UnzipAnyFile/Data/Library/Application Support"
H_OLD="$UNZIP/0123456789ABCDEF0123456789ABCDEF"
H_LOOSE="$UNZIP/FEDCBA9876543210FEDCBA9876543210"
H_NEW="$UNZIP/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
CLONES="$WEEKLY_CLEANUP_TMP_X/com.google.Chrome.code_sign_clone"

build_fixture() {
  rm -rf "$HOME" "$WEEKLY_CLEANUP_TMP_X" "$T/archive"
  mkdir -p "$HOME/.Trash" "$HOME/Library/Caches/app" "$T/archive" \
           "$CLONES/code_sign_clone.old" "$CLONES/code_sign_clone.new" \
           "$H_OLD/Course A/Week 1" "$H_LOOSE/Course B" "$H_NEW/Course C" \
           "$HOME/proj/.next" "$HOME/proj2/.next" "$HOME/proj3/node_modules/x/.next" \
           "$HOME/Library/Application Support/foo/.next"
  echo trash > "$HOME/.Trash/fresh.txt"
  echo old > "$HOME/Library/Caches/app/old.bin"; old "$HOME/Library/Caches/app/old.bin" 10
  echo new > "$HOME/Library/Caches/app/new.bin"
  old "$CLONES/code_sign_clone.old" 30
  head -c 4096 /dev/zero > "$H_OLD/Course A/Week 1/lesson.mp4"
  echo notes > "$H_OLD/Course A/notes.txt"
  echo b > "$H_LOOSE/Course B/b.txt"; echo loose > "$H_LOOSE/loose.txt"
  echo c > "$H_NEW/Course C/c.txt"
  old "$H_OLD" 5; old "$H_LOOSE" 5
  old "$HOME/proj/.next" 10
  old "$HOME/proj3/node_modules/x/.next" 10
  old "$HOME/Library/Application Support/foo/.next" 10
}

NEXT_RUNNING=0
pgrep -f "next dev|next start|next-server" >/dev/null && NEXT_RUNNING=1

echo "dry run removes nothing"
build_fixture; write_config ""
out=$(bash "$SCRIPT" --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc"
contains "$out" "(DRY RUN)" "header says DRY RUN"
contains "$out" "would remove: $CLONES/code_sign_clone.old" "reports the stale clone"
contains "$out" "would archive: Course A" "reports the archive copy"
exists "$CLONES/code_sign_clone.old" "stale clone still there"
exists "$HOME/Library/Caches/app/old.bin" "old cache file still there"
exists "$H_OLD" "unzip extraction still there"
missing "$T/archive/Course A" "nothing copied to the archive"
exists "$HOME/proj/.next" "old .next still there"

echo "real run"
build_fixture; write_config ""
out=$(bash "$SCRIPT" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc"
missing "$CLONES/code_sign_clone.old" "stale browser clone removed"
exists  "$CLONES/code_sign_clone.new" "fresh browser clone kept"
missing "$HOME/Library/Caches/app/old.bin" "cache file older than 7d removed"
exists  "$HOME/Library/Caches/app/new.bin" "fresh cache file kept"
exists  "$HOME/.Trash/fresh.txt" "fresh Trash item kept"
exists  "$T/archive/Course A/Week 1/lesson.mp4" "extraction archived (nested file)"
exists  "$T/archive/Course A/notes.txt" "extraction archived (top file)"
missing "$H_OLD" "archived extraction removed locally"
exists  "$H_LOOSE/loose.txt" "extraction with loose files kept"
missing "$T/archive/Course B" "extraction with loose files not archived"
exists  "$H_NEW" "fresh extraction left alone"
exists  "$HOME/Library/Application Support/foo/.next" ".next inside ~/Library left alone"
exists  "$HOME/proj3/node_modules/x/.next" ".next inside node_modules left alone"
exists  "$HOME/proj2/.next" "fresh .next kept"
if [ "$NEXT_RUNNING" = 1 ]; then
  contains "$out" "a Next server is running, skipped" "old .next skipped while a Next server runs"
else
  missing "$HOME/proj/.next" "old .next removed"
fi
contains "$out" "skipped (SKIP_STEPS)" "skipped steps are reported"

echo "archive copy that differs is not trusted"
build_fixture; write_config ""
mkdir -p "$T/archive/Course A/Week 1"
head -c 4096 /dev/urandom > "$T/archive/Course A/Week 1/lesson.mp4"   # same size, other bytes
out=$(bash "$SCRIPT" 2>&1)
contains "$out" "MISMATCH" "reports the mismatch"
exists "$H_OLD/Course A/Week 1/lesson.mp4" "local copy kept"

echo "a folder name with a newline cannot redirect a removal"
build_fixture; write_config ""
mkdir -p "$HOME/Documents"; echo keep > "$HOME/Documents/keep.txt"
evil="$HOME/proj/a"$'\n'"$HOME/Documents"$'\n'
mkdir -p "$evil/.next"; old "$evil/.next" 10
out=$(bash "$SCRIPT" 2>&1)
exists "$HOME/Documents/keep.txt" "~/Documents untouched"
if [ "$NEXT_RUNNING" = 0 ]; then contains "$out" "REFUSED (unsafe path)" "newline path refused"; fi

echo "archive drive missing"
build_fixture; write_config ""; rmdir "$T/archive"
out=$(bash "$SCRIPT" 2>&1)
contains "$out" "not mounted, skipped" "unzip step skipped"
exists "$H_OLD" "extraction kept when the drive is missing"

echo "Trash age is time-in-Trash (ctime), not last edit (mtime)"
build_fixture; write_config ""
echo stale > "$HOME/.Trash/edited-long-ago.txt"; old "$HOME/.Trash/edited-long-ago.txt" 60
bash "$SCRIPT" >/dev/null 2>&1
exists "$HOME/.Trash/edited-long-ago.txt" "just-trashed file with an old mtime kept"

echo "config validation"
for bad_line in "TRASH_AGE_DAYS=soon" "DELETE_EVERYTHING=1" "SKIP_STEPS=nonsense" "no equals sign"; do
  write_config "$bad_line"
  bash "$SCRIPT" --dry-run >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] && ok "rejects '$bad_line'" || bad "'$bad_line' gave exit $rc, expected 2"
done
bash "$SCRIPT" --bogus >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "rejects an unknown option" || bad "unknown option gave exit $rc"
printf 'ARCHIVE_DIR=~/Drive Folder\n' > "$WEEKLY_CLEANUP_CONFIG"
got=$( (source "$SCRIPT"; load_config; printf '%s' "$ARCHIVE_DIR") )
[ "$got" = "$HOME/Drive Folder" ] && ok "~ expands, spaces kept" || bad "ARCHIVE_DIR parsed as '$got'"

echo "nuke refuses paths outside the allowed roots"
build_fixture
for p in /etc/hosts "$HOME" "$HOME/Documents" "$HOME/Library" "$HOME/.next" "$HOME/../outside" \
         "$HOME/.Trash/../Documents" "$T/elsewhere" /; do
  out=$( (source "$SCRIPT"; init_paths; DRY=1; nuke "$p") 2>&1 ); rc=$?
  if [ "$rc" = 1 ] && grep -q REFUSED <<<"$out"; then ok "refuses $p"; else bad "did not refuse $p"; fi
done
for p in "$HOME/.Trash/fresh.txt" "$HOME/proj/.next" "$CLONES/code_sign_clone.old" "$H_OLD"; do
  out=$( (source "$SCRIPT"; init_paths; DRY=1; nuke "$p") 2>&1 )
  contains "$out" "would remove" "allows $p"
done

if command -v swiftc >/dev/null; then
  echo "runner (Full Disk Access launcher)"
  R="$T/runner"; mkdir -p "$R"
  printf '#!/bin/bash\necho "args=$* home=$HOME tmpx=${WEEKLY_CLEANUP_TMP_X:-unset}"\n' > "$R/weekly-cleanup.sh"
  if "$REPO/runner/build.sh" binary "$R/weekly-cleanup.sh" "$R/weekly-cleanup-runner" test.runner 2>/dev/null; then
    out=$(HOME=/tmp WEEKLY_CLEANUP_TMP_X=/etc "$R/weekly-cleanup-runner" --dry-run 2>&1); rc=$?
    [ "$rc" = 0 ] && ok "runs the script it was built for" || bad "runner exit $rc: $out"
    contains "$out" "args=--dry-run" "passes arguments"
    contains "$out" "tmpx=unset" "drops WEEKLY_CLEANUP_* variables"
    real_home=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')
    contains "$out" "home=$real_home" "HOME comes from the user database"
    echo 'echo tampered' >> "$R/weekly-cleanup.sh"
    out=$("$R/weekly-cleanup-runner" 2>&1); rc=$?
    if [ "$rc" = 1 ] && ! grep -q tampered <<<"$out"; then ok "refuses an edited script"; else bad "ran an edited script: $out"; fi
  else
    bad "runner did not build"
  fi
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
