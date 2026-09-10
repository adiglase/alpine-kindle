#!/bin/sh
#
# alpine.sh - mount the Alpine rootfs image and drop into it (Kindle side).
# Derived from schuhumi/alpine_kindle (GPL-3.0) - see README.md.
#
# Usage on the Kindle:
#   sh alpine.sh              shell inside Alpine
#   sh alpine.sh startgui     mount, then start the MATE desktop
#   sh alpine.sh cleanup      unmount whatever a killed session left behind
#
# Everything this script prints is ALSO appended to alpine-run.log next to the
# image. So instead of copying text off the e-ink screen, plug the Kindle into a
# PC and read /mnt/us/alpine-run.log there.

DIR="$(dirname "$0")"
[ "$DIR" = "." ] && DIR="$(pwd)"
MNT=/tmp/alpine
LOG="$DIR/alpine-run.log"
SWAPDEV=""

# ------------------------------------------------------------- logging ------
: > "$LOG" 2>/dev/null
say() {
  echo "$@"
  echo "$@" >> "$LOG" 2>/dev/null
}

# A snapshot taken from inside the chroot, so a failing run leaves useful facts
# behind without anyone having to type them.
snapshot() {
  {
    echo "--- chroot snapshot ---"
    echo "alpine-release: $(cat "$MNT/etc/alpine-release" 2>/dev/null)"
    echo "installed pkgs: $(chroot "$MNT" /bin/sh -c 'apk list --installed 2>/dev/null | wc -l' 2>/dev/null)"
    echo "uname:          $(chroot "$MNT" /bin/sh -c 'uname -m' 2>/dev/null)"
    echo "free -m:";      chroot "$MNT" /bin/sh -c 'free -m' 2>&1 | sed 's/^/  /'
    echo "df -h /:";      chroot "$MNT" /bin/sh -c 'df -h /' 2>&1 | sed 's/^/  /'
    echo "/proc/swaps:";  sed 's/^/  /' /proc/swaps
    echo "--- end snapshot ---"
  } >> "$LOG" 2>&1
}

# ---------------------------------------------------------------- swap ------
# swap.img is a pre-formatted block image: attach it with losetup and swap on
# the loop device (a swap *file* is impossible on the vfat userstore).
#
# Node naming differs between firmwares: some expose /dev/loop<N>, others (e.g.
# firmware 5.19.x on an 11th gen) expose /dev/loop/<N> as a *directory*. So ask
# sysfs which loops exist and which are free instead of guessing paths.
find_free_loop() {
  # 1. sysfs: a loop whose backing_file is empty has nothing attached
  for b in /sys/block/loop*; do
    [ -d "$b" ] || continue
    BF="$b/loop/backing_file"
    [ -r "$BF" ] || continue
    [ -s "$BF" ] && continue
    N="${b##*/}"
    if [ -b "/dev/$N" ]; then echo "/dev/$N"; return 0; fi
    if [ -b "/dev/loop/${N#loop}" ]; then echo "/dev/loop/${N#loop}"; return 0; fi
  done
  # 2. whatever losetup offers, if the node actually exists
  L="$(losetup -f 2>/dev/null)"
  if [ -n "$L" ] && [ -b "$L" ]; then echo "$L"; return 0; fi
  # 3. brute force, both layouts
  for d in /dev/loop[0-9] /dev/loop[0-9][0-9] /dev/loop/[0-9] /dev/loop/[0-9][0-9]; do
    [ -b "$d" ] || continue
    losetup "$d" 2>/dev/null | grep -q . && continue
    echo "$d"; return 0
  done
  return 1
}

# Detach any loop device backed by file $1. Not every firmware releases the loop
# device on unmount, and there are only ~16 of them.
detach_loop_for() {
  BASE="$(basename "$1")"
  for b in /sys/block/loop*; do
    [ -d "$b" ] || continue
    BF="$b/loop/backing_file"
    [ -r "$BF" ] || continue
    case "$(cat "$BF" 2>/dev/null)" in
      *"$BASE")
        N="${b##*/}"
        if [ -b "/dev/$N" ]; then losetup -d "/dev/$N" 2>/dev/null;
        else losetup -d "/dev/loop/${N#loop}" 2>/dev/null; fi
        say "Detached loop device ${N#loop}"
        ;;
    esac
  done
}

enable_swap() {
  [ -f "$DIR/swap.img" ] || return 0
  # A previous session (or tools/diag.sh) may already have it attached.
  for b in /sys/block/loop*; do
    [ -r "$b/loop/backing_file" ] || continue
    case "$(cat "$b/loop/backing_file" 2>/dev/null)" in
      *swap.img) say "Swap already active - leaving it as is."; return 0 ;;
    esac
  done
  L="$(find_free_loop)" || { say "No free loop device for swap - continuing without it."; return 0; }
  if ! losetup "$L" "$DIR/swap.img" 2>/dev/null; then
    say "Could not attach $L to swap.img - continuing without swap."
    return 0
  fi
  if swapon "$L" 2>/dev/null; then
    SWAPDEV="$L"
    say "Swap enabled on $SWAPDEV"
  else
    losetup -d "$L" 2>/dev/null
    say "swapon failed (kernel without CONFIG_SWAP?) - continuing without swap."
  fi
}

disable_swap() {
  [ -n "$SWAPDEV" ] || return 0
  swapoff "$SWAPDEV" 2>/dev/null
  losetup -d "$SWAPDEV" 2>/dev/null
  say "Swap disabled ($SWAPDEV)"
  SWAPDEV=""
}

# -------------------------------------------------------------- mounting ---
mount_rootfs() {
  say "Mounting Alpine rootfs ($DIR/alpine.ext3)"
  mkdir -p "$MNT"
  mount -o loop,noatime -t ext3 "$DIR/alpine.ext3" "$MNT" || return 1
  mount -o bind /dev     "$MNT/dev"
  mount -o bind /dev/pts "$MNT/dev/pts"
  mount -o bind /proc    "$MNT/proc"
  mount -o bind /sys     "$MNT/sys"
  mount -o bind /var/run/dbus "$MNT/run/dbus" 2>/dev/null

  # Live network + host config from the Kindle itself.
  [ -r /etc/hosts ] && cp /etc/hosts "$MNT/etc/hosts"
  if [ -r /etc/resolv.conf ]; then
    cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"
  else
    echo "nameserver 8.8.8.8" > "$MNT/etc/resolv.conf"
  fi
  chmod a+w /dev/shm 2>/dev/null

  enable_swap
  snapshot
}

unmount_rootfs() {
  say "Leaving Alpine, cleaning up"
  pkill Xephyr 2>/dev/null
  sleep 1
  disable_swap
  umount "$MNT/run/dbus" 2>/dev/null
  umount "$MNT/sys" 2>/dev/null
  umount "$MNT/proc" 2>/dev/null
  umount "$MNT/dev/pts" 2>/dev/null
  umount "$MNT/dev" 2>/dev/null
  sync
  umount "$MNT" 2>/dev/null
  # The loop device is released asynchronously; retry a few times.
  i=0
  while mount | grep -q "on $MNT "; do
    i=$((i + 1))
    [ "$i" -gt 10 ] && { say "WARNING: $MNT still mounted - reboot to clean up."; break; }
    say "Still busy, retrying in ${i}s..."
    sleep "$i"
    umount "$MNT" 2>/dev/null
  done
  # Free the loop devices too - firmware does not always do it for us.
  detach_loop_for "$DIR/alpine.ext3"
  detach_loop_for "$DIR/swap.img"
  say "Alpine unmounted."
}

# ------------------------------------------------------------------ main ---
# Recovery mode: clean up mounts left behind by a session that was killed rather
# than exited (e.g. connecting USB stops the framework and kills kterm without
# running any cleanup). Safe to run when nothing is mounted.
if [ "$1" = "cleanup" ]; then
  say "Cleaning up any leftover Alpine mounts..."
  unmount_rootfs
  exit 0
fi

if mount | grep -q "on $MNT "; then
  say "Rootfs already mounted - entering the existing session."
  ALREADY=yes
else
  ALREADY=no
  mount_rootfs || { say "ERROR: could not mount $DIR/alpine.ext3"; exit 1; }
fi

if [ "$1" = "startgui" ] || [ "$1" = "gui" ]; then
  say "Starting the MATE desktop (Xephyr on the Kindle's X server)..."
  chroot "$MNT" /startgui.sh
else
  say "Dropping into Alpine. Type 'exit' to come back to the Kindle."
  chroot "$MNT" /bin/sh
fi

if [ "$ALREADY" = "yes" ]; then
  say "Another Alpine session is still using $MNT - leaving it mounted."
else
  unmount_rootfs
fi

say "Log written to $LOG"
