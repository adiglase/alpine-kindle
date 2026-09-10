#!/bin/sh
# diag.sh - loop-device / swap diagnostics for the Alpine chroot on a Kindle.
#
# Run this OUTSIDE the chroot (a plain kterm or SSH shell), with the Alpine
# rootfs NOT mounted:
#     sh /mnt/us/diag.sh
#
# It only ever attaches a loop device that sysfs reports as free.

US=/mnt/us

echo "=== 1. loop node layout ==="
ls -l /dev/loop-control 2>/dev/null
ls -l /dev/loop 2>/dev/null | head -25
ls -l /dev/loop[0-9] /dev/loop[0-9][0-9] 2>/dev/null | head -20

echo
echo "=== 2. attached loops, as reported by sysfs ==="
for b in /sys/block/loop*; do
  [ -d "$b" ] || continue
  BF="$b/loop/backing_file"
  if [ -r "$BF" ]; then
    printf "  %-9s backing=%s\n" "${b##*/}" "$(cat "$BF" 2>/dev/null)"
  else
    printf "  %-9s (backing_file not readable)\n" "${b##*/}"
  fi
done

echo
echo "=== 3. apply the same find_free_loop logic the fixed alpine.sh uses ==="
FREE=""
for b in /sys/block/loop*; do
  [ -d "$b" ] || continue
  BF="$b/loop/backing_file"
  [ -r "$BF" ] || continue
  [ -s "$BF" ] && continue
  N="${b##*/}"
  if [ -b "/dev/$N" ]; then FREE="/dev/$N"; break; fi
  if [ -b "/dev/loop/${N#loop}" ]; then FREE="/dev/loop/${N#loop}"; break; fi
done
echo "  free loop found: ${FREE:-NONE}"

echo
echo "=== 4. attach and enable the swap image ==="
ATTACHED=""
if [ -f "$US/swap.img" ]; then
  echo "  swap.img: $(ls -l "$US/swap.img" | awk '{print $5" bytes"}')"
  if [ -n "$FREE" ]; then
    if losetup "$FREE" "$US/swap.img" 2>&1; then
      echo "  losetup $FREE OK"
      if swapon "$FREE" 2>&1; then ATTACHED="$FREE"; echo "  swapon OK"; else echo "  swapon FAILED"; fi
    else
      echo "  losetup FAILED"
    fi
  else
    echo "  no free loop device - cannot test"
  fi
else
  echo "  $US/swap.img NOT FOUND"
fi

echo
echo "=== 5. active swap ==="
cat /proc/swaps

echo
echo "=== 6. memory ==="
free -m 2>/dev/null || cat /proc/meminfo | head -3

echo
echo "=== 7. zram capability (RAM-backed swap: faster, no flash wear) ==="
ls /sys/class/zram-control/ 2>&1 | head -5
for z in /sys/block/zram*; do
  [ -d "$z" ] || continue
  printf "  %-8s disksize=%s\n" "${z##*/}" "$(cat "$z/disksize" 2>/dev/null)"
done

echo
 echo "=== 8. kernel swap support ==="
grep -i -E "^SwapTotal|^SwapFree|^MemTotal" /proc/meminfo

# This script is diagnostic: leave the device safe to connect to a PC again.
# alpine.sh enables swap for each session and disables it on exit.
echo
echo "=== 9. cleanup ==="
if [ -n "$ATTACHED" ]; then
  swapoff "$ATTACHED" 2>/dev/null && echo "  swapoff $ATTACHED OK"
  losetup -d "$ATTACHED" 2>/dev/null && echo "  loop detached OK"
else
  echo "  nothing to clean up"
fi
echo "  device is safe to connect via USB"
