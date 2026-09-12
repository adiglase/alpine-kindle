# install.sh - one-shot installer for Alpine Linux for Kindle.
#
# Run this ON THE KINDLE, from a kterm or SSH shell:
#
#     sh /mnt/us/install.sh
#
# It expects the release files to be next to it on the userstore:
#
#     alpine.ext3  alpine.sh  alpine.conf  swap.img   (the last two optional)
#     install.sh
#
# i.e. unzip the release into /mnt/us, then run this once. It:
#   - verifies the files are present and sane
#   - checks the device is a supported armhf machine with enough space
#   - makes sure the Alpine rootfs is not currently mounted
#   - optionally installs the (experimental) upstart job
#   - prints exactly what to run next
#
# Nothing here stops the Kindle UI, mounts the image, or modifies the stock system
# other than copying one optional file into /etc/upstart.

US=/mnt/us
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -d "$SELF_DIR" ] || SELF_DIR="$US"

ok()   { printf '  [ ok ] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

echo "Alpine Linux for Kindle - installer"
echo "==================================="

################################ checks #####################################

echo
echo "1. Device"
ARCH="$(uname -m)"
[ "$ARCH" = "armv7l" ] || die "This image is armhf; this device reports '$ARCH'.
       It will not run here."
ok "architecture: $ARCH"
ok "kernel: $(uname -r)"

MODEL="$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')"
[ -n "$MODEL" ] && ok "model: $MODEL"
FW="$(cat /etc/prettyversion.txt 2>/dev/null)"
[ -n "$FW" ] && ok "firmware: $FW"

echo
echo "2. Files"
for f in alpine.ext3 alpine.sh; do
  if [ ! -f "$SELF_DIR/$f" ]; then
    die "$SELF_DIR/$f is missing.
       Copy the release contents next to this script (or into $US)."
  fi
  ok "$f present ($(ls -l "$SELF_DIR/$f" | awk '{print $5}') bytes)"
done
[ -f "$SELF_DIR/swap.img" ] && ok "swap.img present (optional)" \
                          || warn "no swap.img - the desktop will be tight at 512 MB"
[ -f "$SELF_DIR/alpine.conf" ] && ok "alpine.conf present (experimental upstart job)" \
                              || warn "no alpine.conf - that's fine, see alpine-kindle-docs/KNOWN-ISSUES.md"

# A 2.5 GiB image must actually be that size; a truncated copy is the most likely
# failure after a USB/MTP transfer.
SZ="$(ls -l "$SELF_DIR/alpine.ext3" | awk '{print $5}')"
[ "$SZ" -gt 1000000000 ] || die "alpine.ext3 is only $SZ bytes - the copy was truncated."

echo
echo "3. Make sure nothing is mounted"
MNT_PARENT="$(readlink -f /tmp 2>/dev/null)"
[ -n "$MNT_PARENT" ] || MNT_PARENT=/tmp
MNT_REAL="$MNT_PARENT/alpine"
rootfs_is_mounted() {
  awk -v logical=/tmp/alpine -v real="$MNT_REAL" \
    '$2 == logical || $2 == real { found=1 } END { exit !found }' /proc/mounts
}
if rootfs_is_mounted; then
  warn "the Alpine rootfs is already mounted; cleaning up first"
  sh "$SELF_DIR/alpine.sh" cleanup || die "the Alpine rootfs is still mounted; reboot before installing"
fi
rootfs_is_mounted && die "the Alpine rootfs is still mounted; reboot before installing"
ok "no stale mounts"

FREE="$(df -k "$US" 2>/dev/null | awk 'NR==2{print $4}')"
[ -n "$FREE" ] && ok "free space on $US: $((FREE/1024)) MiB"

################################ actions #####################################

echo
echo "4. Upstart job (optional, experimental)"
printf "   Install 'start alpine' / 'stop alpine' support? [y/N] "
read -r REPLY
case "$REPLY" in
  [yY]*)
    [ -f "$SELF_DIR/alpine.conf" ] || die "alpine.conf not found next to this script"
    mntroot rw >/dev/null 2>&1 || die "could not remount the Kindle root filesystem read-write"
    trap 'mntroot ro >/dev/null 2>&1' EXIT HUP INT TERM
    if ! cp "$SELF_DIR/alpine.conf" /etc/upstart/alpine.conf; then
      mntroot ro >/dev/null 2>&1
      die "could not install /etc/upstart/alpine.conf"
    fi
    mntroot ro >/dev/null 2>&1 \
      || die "job installed, but the Kindle root filesystem could not be remounted read-only"
    trap - EXIT HUP INT TERM
    ok "installed /etc/upstart/alpine.conf"
    warn "EXPERIMENTAL: restarting the Kindle UI can trigger its crash-recovery screen."
    warn "If it does not recover: sh $US/alpine.sh cleanup ; reboot"
    ;;
  *)
    ok "skipped - using the manual launcher"
    ;;
esac

###############################################################################

cat <<EOF

Done. Two ways to run it:

  Shell only (lightest, always safe):
      cd $US && sh alpine.sh

  Desktop (JWM), no Kindle UI changes:
      cd $US && sh alpine.sh startgui

  Desktop with the Kindle UI stopped first (frees ~150 MB, needs the upstart job):
      initctl start alpine

Read $US/alpine-kindle-docs/KNOWN-ISSUES.md before using 'stop alpine'.

If you copied alpine.zip to the Kindle, you can now delete it to recover space:
    rm -f $US/alpine.zip

Quick device sanity check after the first run:  cat $US/alpine-run.log
EOF
