#!/bin/sh
#
# uninstall.sh - remove Alpine Linux for Kindle from the device.
#
# Run on the KINDLE, from kterm or SSH:
#
#     sh /mnt/us/uninstall.sh                 # remove everything (asks first)
#     sh /mnt/us/uninstall.sh --keep-image    # keep alpine.ext3 + swap.img
#     sh /mnt/us/uninstall.sh --yes           # no prompts
#     sh /mnt/us/uninstall.sh --dry-run       # show what would be removed
#
# This removes BOTH kinds of trace:
#   * runtime state:   mounts, loop devices, swap, leftover X/MATE processes
#   * installed files: the upstart job on the system partition, and the image and
#                      scripts on the userstore
#
# It does NOT touch the jailbreak, KOReader, your books, or any Kindle setting.
#
# A reboot afterwards is recommended: it reloads upstart without the job, remounts
# the root filesystem read-only, and clears /tmp.

US=/mnt/us
SELF_DIR="${ALPINE_UNINSTALL_DIR:-$(cd "$(dirname "$0")" && pwd)}"
[ -d "$SELF_DIR" ] || SELF_DIR="$US"

KEEP_IMAGE=no
ASSUME_YES=no
DRY_RUN=no

# Ask a yes/no question. In --dry-run or --yes mode, don't prompt at all: just
# report what the default would do. (The first version still prompted during a dry
# run, because `read` had no input and fell through to the default.)
confirms() {   # confirms "<question>" <default: y|n>
  _q="$1"
  _def="${2:-y}"
  if [ "$_def" = y ]; then _label="Y/n"; _word="yes"; else _label="y/N"; _word="no"; fi
  if [ "$DRY_RUN" = yes ]; then
    say "  $_q [$_label] -> $_word (dry run, not prompted)"
    [ "$_def" = y ]
    return $?
  fi
  if [ "$ASSUME_YES" = yes ]; then
    say "  $_q [$_label] -> $_word (--yes)"
    [ "$_def" = y ]
    return $?
  fi
  printf '  %s [%s] ' "$_q" "$_label"
  read -r _a
  [ -z "$_a" ] && _a="$_def"
  case "$_a" in
    [yY]*) return 0 ;;
    *) return 1 ;;
  esac
}

for arg in "$@"; do
  case "$arg" in
    --keep-image) KEEP_IMAGE=yes ;;
    --yes|-y)     ASSUME_YES=yes ;;
    --dry-run|-n) DRY_RUN=yes ;;
    --help|-h)    sed -n '3,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# BusyBox sh reads a script incrementally. Removing /mnt/us/uninstall.sh while
# that same file is still being interpreted makes the shell lose the unread
# tail and report a bogus "unterminated quoted string". For a real uninstall,
# re-exec an ephemeral copy first so the installed copy can safely remove
# itself. A dry run does not remove the script and therefore needs no copy.
if [ "$DRY_RUN" != yes ] && [ "${ALPINE_UNINSTALL_RELOCATED:-no}" != yes ] \
   && [ "$SELF_DIR" = "$US" ]; then
  TMP_UNINSTALL="$(mktemp /tmp/alpine-uninstall.XXXXXX)" \
    || { echo "could not create temporary uninstaller" >&2; exit 1; }
  cp "$0" "$TMP_UNINSTALL" || exit 1
  ALPINE_UNINSTALL_RELOCATED=yes
  ALPINE_UNINSTALL_DIR="$SELF_DIR"
  export ALPINE_UNINSTALL_RELOCATED ALPINE_UNINSTALL_DIR
  exec sh "$TMP_UNINSTALL" "$@"
fi

ROOT_MADE_RW=no
cleanup_uninstaller() {
  [ "$ROOT_MADE_RW" = yes ] && mntroot ro >/dev/null 2>&1
  [ "${ALPINE_UNINSTALL_RELOCATED:-no}" = yes ] && rm -f "$0"
}
trap cleanup_uninstaller EXIT HUP INT TERM

say()  { printf '%s\n' "$*"; }
run()  {
  if [ "$DRY_RUN" = yes ]; then
    say "  would run: $*"
  else
    "$@"
  fi
}

MNT_PARENT="$(readlink -f /tmp 2>/dev/null)"
[ -n "$MNT_PARENT" ] || MNT_PARENT=/tmp
MNT_REAL="$MNT_PARENT/alpine"
rootfs_is_mounted() {
  awk -v logical=/tmp/alpine -v real="$MNT_REAL" \
    '$2 == logical || $2 == real { found=1 } END { exit !found }' /proc/mounts
}

say "Alpine Linux for Kindle - uninstaller"
say "====================================="
[ "$DRY_RUN" = yes ] && say "(dry run - nothing will be changed)"
say

########################################################################
say "1. Stop any running session"
########################################################################

if rootfs_is_mounted; then
  # Use the launcher's own cleanup when available: it unmounts in the right
  # order, disables swap and detaches the loop devices.
  if [ -x "$SELF_DIR/alpine.sh" ] || [ -f "$SELF_DIR/alpine.sh" ]; then
    run sh "$SELF_DIR/alpine.sh" cleanup
  else
    say "  alpine.sh not found; unmounting manually"
    for m in run/dbus sys proc dev/pts dev ""; do
      run umount "/tmp/alpine/$m" 2>/dev/null
    done
  fi
else
  say "  nothing mounted"
fi

# Leftover desktop processes, by pid, walking /proc (pgrep may be absent).
for p in /proc/[0-9]*; do
  [ -r "$p/comm" ] || continue
  case "$(cat "$p/comm" 2>/dev/null)" in
    Xephyr|mate-session|marco|mate-panel|caja|mate-screensaver|onboard|mate-settings-daemon)
      say "  killing ${p#/proc/} ($(cat "$p/comm"))"
      run kill "${p#/proc/}" 2>/dev/null
      ;;
  esac
done

# Any loop device still backed by our files.
for b in /sys/block/loop*; do
  [ -r "$b/loop/backing_file" ] || continue
  case "$(cat "$b/loop/backing_file" 2>/dev/null)" in
    *alpine.ext3*|*swap.img*)
      N="${b##*/}"
      say "  detaching loop ${N#loop} ($(cat "$b/loop/backing_file"))"
      if [ -b "/dev/$N" ]; then run losetup -d "/dev/$N" 2>/dev/null
      else run losetup -d "/dev/loop/${N#loop}" 2>/dev/null; fi
      ;;
  esac
done

########################################################################
say
say "2. Upstart job (system partition)"
########################################################################

if [ -f /etc/upstart/alpine.conf ]; then
  say "  found /etc/upstart/alpine.conf - this is a change to the system partition"
  if confirms "Remove it?" y; then
    run mntroot rw || { say "  ERROR: could not remount the Kindle root filesystem read-write"; exit 1; }
    [ "$DRY_RUN" = yes ] || ROOT_MADE_RW=yes
    if ! run rm -f /etc/upstart/alpine.conf; then
      run mntroot ro
      ROOT_MADE_RW=no
      say "  ERROR: could not remove /etc/upstart/alpine.conf"
      exit 1
    fi
    run mntroot ro || { say "  ERROR: root filesystem is still writeable; run 'mntroot ro'"; exit 1; }
    ROOT_MADE_RW=no
    say "  removed"
  else
    say "  kept"
  fi
else
  say "  not installed"
fi

# Orientation can be left rotated by a landscape experiment.
ORIENT="$(lipc-get-prop com.lab126.winmgr orientation 2>/dev/null)"
if [ -n "$ORIENT" ] && [ "$ORIENT" != "U" ]; then
  say "  screen orientation is '$ORIENT' (not portrait) - restoring U"
  run lipc-set-prop com.lab126.winmgr orientation U
fi

########################################################################
say
say "3. Files on the userstore ($US)"
########################################################################

FILES="alpine.sh alpine.conf alpine-run.log alpine.log diag.sh install.sh uninstall.sh alpine.zip
       startgui.out startgui2.out"
for f in $FILES; do
  [ -e "$US/$f" ] || continue
  say "  removing $f"
  run rm -f "$US/$f"
done

if [ -d "$US/alpine-kindle-docs" ]; then
  say "  removing alpine-kindle-docs"
  run rm -rf "$US/alpine-kindle-docs"
fi

# Debug logs from development sessions, if any are present.
for f in "$US"/mate*.log; do
  [ -e "$f" ] || continue
  say "  removing $(basename "$f")"
  run rm -f "$f"
done

if [ "$KEEP_IMAGE" = yes ]; then
  say "  keeping alpine.ext3 and swap.img (--keep-image)"
else
  say "  alpine.ext3 is 2.5 GB - deleting it means a full re-copy to reinstall later."
  if confirms "Delete alpine.ext3 and swap.img?" y; then
    for f in alpine.ext3 swap.img; do
      [ -e "$US/$f" ] || continue
      say "  removing $f ($(ls -l "$US/$f" | awk '{printf "%.1f GB", $5/1073741824}'))"
      run rm -f "$US/$f"
    done
  else
    say "  kept (remove later with: rm -f $US/alpine.ext3 $US/swap.img)"
  fi
fi

########################################################################
say
say "4. Verify"
########################################################################

if rootfs_is_mounted; then
  say "  WARNING: Alpine is still mounted at $MNT_REAL - reboot to clear it"
else
  say "  no Alpine mounts"
fi

LEFT=""
for b in /sys/block/loop*; do
  [ -r "$b/loop/backing_file" ] || continue
  case "$(cat "$b/loop/backing_file" 2>/dev/null)" in
    *alpine.ext3*|*swap.img*) LEFT="$LEFT ${b##*/}" ;;
  esac
done
[ -n "$LEFT" ] && say "  WARNING: loops still attached:$LEFT" || say "  no Alpine loop devices"

[ -f /etc/upstart/alpine.conf ] && say "  upstart job still present" || say "  upstart job removed"

if [ "$KEEP_IMAGE" = yes ]; then
  say "  note: alpine.ext3/swap.img kept - remove them later with:"
  say "        rm -f $US/alpine.ext3 $US/swap.img"
fi

say
say "Recommended: reboot now (hold power ~20 s). That reloads upstart without the"
say "job, remounts the root filesystem read-only, and clears /tmp."
say
say "Not touched: your jailbreak, KOReader, books, and Kindle settings."
