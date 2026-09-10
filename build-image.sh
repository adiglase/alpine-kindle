#!/usr/bin/env bash
#
# build-image.sh - build a modern Alpine Linux chroot image for an armhf Kindle.
#
# Derived from schuhumi/alpine_kindle (GPL-3.0) - see README.md for attribution.
#
# Tested target stack: Kindle Paperwhite 5 / 11th gen on firmware 5.19.x
#   - userspace ABI is armhf ("kindlehf"), so ARCH=armv7 is correct
#   - X11 + awesome + upstart lab126_gui are all still present on this firmware,
#     which is what the nested-X (Xephyr) desktop approach depends on.
#
# Requirements on the host: root, curl, qemu-user-static, ~8 GB free disk.
#   Debian/Ubuntu/Pop!_OS:  sudo apt install qemu-user-static
#
set -euo pipefail

############################### CONFIG ###############################

ALPINE_BRANCH="${ALPINE_BRANCH:-v3.24}"   # pin a stable branch, never "edge"
ARCH="${ARCH:-armv7}"                     # Kindle armhf userspace
IMAGESIZE_MB="${IMAGESIZE_MB:-2560}"      # MUST stay below 4096: /mnt/us is FAT32
SWAP_MB="${SWAP_MB:-512}"                 # 0 disables the swap image
WITH_CHROMIUM="${WITH_CHROMIUM:-yes}"     # "no" -> netsurf only, ~700 MiB image
REPO="https://dl-cdn.alpinelinux.org/alpine"
REPO_INSECURE="http://dl-cdn.alpinelinux.org/alpine"   # http inside chroot: no ca-certificates yet

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="$HERE/release"
CACHE="$HERE/cache"
MNT="$HERE/mnt"
IMAGE="$OUTDIR/alpine.ext3"
SWAPIMG="$OUTDIR/swap.img"

PKGS=(
  alpine-base
  xorg-server-xephyr xwininfo xdpyinfo xauth xdotool xinput xset xterm
  dbus dbus-x11
  mate-desktop-environment mate-themes mate-icon-theme
  onboard
  netsurf
  sudo bash nano git curl unzip desktop-file-utils
  font-dejavu font-liberation font-noto
)
[ "$WITH_CHROMIUM" = "yes" ] && PKGS+=( chromium )

############################### HELPERS ##############################

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

LOOPDEV=""
cleanup() {
  set +e
  umount "$MNT/run/dbus" 2>/dev/null
  umount "$MNT/sys" 2>/dev/null
  umount "$MNT/proc" 2>/dev/null
  umount "$MNT/dev/pts" 2>/dev/null
  umount "$MNT/dev" 2>/dev/null
  umount "$MNT" 2>/dev/null
  [ -n "$LOOPDEV" ] && losetup -d "$LOOPDEV" 2>/dev/null
}
trap cleanup EXIT

############################### CHECKS ##############################

[ "$(id -u)" = "0" ] || die "Run me as root (needs loop mounts + chroot)."
QEMU="$(command -v qemu-arm-static || true)"
[ -n "$QEMU" ] || die "qemu-arm-static not found. Install qemu-user-static (apt install qemu-user-static)."
command -v curl >/dev/null || die "curl not found."

# The userstore is FAT32, so a single file cannot reach 4 GiB. Refuse to build an
# image that could never be copied to the Kindle.
case "$IMAGESIZE_MB" in ""|*[!0-9]*) die "IMAGESIZE_MB must be a number (got: $IMAGESIZE_MB)";; esac
case "$SWAP_MB" in ""|*[!0-9]*) die "SWAP_MB must be a number (got: $SWAP_MB)";; esac
[ "$IMAGESIZE_MB" -ge 1024 ] || die "IMAGESIZE_MB must be >= 1024 (got $IMAGESIZE_MB)"
[ "$IMAGESIZE_MB" -le 4095 ] || die "IMAGESIZE_MB must be <= 4095 - /mnt/us is FAT32 (got $IMAGESIZE_MB)"
[ "$SWAP_MB" -le 2048 ] || die "SWAP_MB must be <= 2048 (got $SWAP_MB)"

mkdir -p "$OUTDIR" "$CACHE" "$MNT"

########################## 1. ALPINE ROOTFS #########################

log "Resolving newest Alpine $ALPINE_BRANCH $ARCH minirootfs"
# sort -V, not 'sort -u | head -1': lexicographically "3.24.0" sorts before "3.24.1"
# only by accident, and would silently pick the older rootfs.
MINI="$(curl -fsSL "$REPO/$ALPINE_BRANCH/releases/$ARCH/" \
        | grep -oE "alpine-minirootfs-[0-9.]+-$ARCH\.tar\.gz" | sort -uV | tail -1)"
[ -n "$MINI" ] || die "Could not find a minirootfs in $REPO/$ALPINE_BRANCH/releases/$ARCH/"
log "Using $MINI"

TARBALL="$CACHE/$MINI"
if [ ! -f "$TARBALL" ]; then
  log "Downloading and verifying $MINI"
  curl -fL --progress-bar -o "$TARBALL.part" "$REPO/$ALPINE_BRANCH/releases/$ARCH/$MINI"
  curl -fsSL -o "$CACHE/$MINI.sha256" "$REPO/$ALPINE_BRANCH/releases/$ARCH/$MINI.sha256" \
    || die "Could not fetch the published checksum for $MINI - refusing to use an unverified rootfs"
  EXPECTED="$(awk '{print $1; exit}' "$CACHE/$MINI.sha256")"
  ACTUAL="$(sha256sum "$TARBALL.part" | awk '{print $1}')"
  if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
    rm -f "$TARBALL.part"
    die "Checksum mismatch for $MINI (expected ${EXPECTED:-none}, got $ACTUAL)"
  fi
  mv "$TARBALL.part" "$TARBALL"
fi

log "Creating ${IMAGESIZE_MB} MiB ext3 image at $IMAGE"
dd if=/dev/zero of="$IMAGE" bs=1M count="$IMAGESIZE_MB" status=progress
mkfs.ext3 -F -q "$IMAGE"
tune2fs -i 0 -c 0 "$IMAGE" >/dev/null          # disable fsck intervals: it's a plain file

log "Mounting image and unpacking minirootfs"
LOOPDEV="$(losetup -f --show "$IMAGE")"
mount "$LOOPDEV" "$MNT"
tar -xzf "$TARBALL" -C "$MNT"

# Repositories: pinned branch, main + community. http because a bare minirootfs
# has no CA bundle yet (packages are signature-verified regardless).
cat > "$MNT/etc/apk/repositories" <<EOF
$REPO_INSECURE/$ALPINE_BRANCH/main
$REPO_INSECURE/$ALPINE_BRANCH/community
EOF
echo kindle > "$MNT/etc/hostname"
mkdir -p "$MNT/run/dbus" "$MNT/etc/dconf/db/local.d" "$MNT/etc/dconf/profile"

# Post-install scripts need these live kernel interfaces.
mount -o bind /dev     "$MNT/dev"
mount -o bind /dev/pts "$MNT/dev/pts"
mount -o bind /proc    "$MNT/proc"
mount -o bind /sys     "$MNT/sys"
cp /etc/resolv.conf "$MNT/etc/resolv.conf"

############################ 2. PACKAGES ############################

log "Installing packages inside the chroot (this takes a few minutes)"
cp "$QEMU" "$MNT/usr/bin/qemu-arm-static"

cat > "$MNT/tmp/setup.sh" <<EOF
set -e
apk update
apk upgrade
apk add --no-cache ${PKGS[*]}

# --- user + sudo ---------------------------------------------------------
# No password is set here ON PURPOSE. A baked-in default password combined with an
# unsandboxed browser inside a chroot that shares /dev, /proc and /sys with the
# Kindle is a direct path from a malicious web page to root on the device.
# Set one on first run - you are already root in 'sh alpine.sh':  passwd alpine
adduser -D -s /bin/bash alpine 2>/dev/null || true
addgroup sudo 2>/dev/null || true
for g in sudo video audio input dialout; do
  addgroup alpine "\$g" 2>/dev/null || true
done
grep -q '^%sudo' /etc/sudoers || echo '%sudo ALL=(ALL) ALL' >> /etc/sudoers

# --- /run/dbus must exist for the bind mount -----------------------------
mkdir -p /run/dbus
EOF
chroot "$MNT" /usr/bin/qemu-arm-static /bin/sh /tmp/setup.sh
rm -f "$MNT/tmp/setup.sh"

########################### 3. DESKTOP SETUP ########################

log "Writing desktop configuration"

# The Kindle UI stays in charge of the X display; Xephyr nests inside it.
# -cc 4 = TrueColor. The window title is the hint awesome uses to fullscreen it.
cat > "$MNT/startgui.sh" <<'EOF'
#!/bin/sh
# Runs inside the chroot. Nests an X server on the Kindle's :0 and starts MATE.
chmod a+w /dev/shm 2>/dev/null

# Warn loudly when the desktop user has no password: it is the difference between
# "a browser bug" and "an attacker owns the Kindle".
if grep -q '^alpine:[!*]' /etc/shadow 2>/dev/null; then
  echo "WARNING: user 'alpine' has no password set."
  echo "         Run 'passwd alpine' (as root in 'sh alpine.sh') before browsing."
fi

# A system bus of our own: the Kindle's vanishes when its UI is stopped.
mkdir -p /run/dbus
[ -S /run/dbus/system_bus_socket ] || dbus-daemon --system --fork 2>/dev/null

SIZE="$(xwininfo -root -display :0 | grep -i geometry | cut -d' ' -f4)"
[ -n "$SIZE" ] || SIZE=1236x1648

# The window title is a lab126 convention the Kindle's WM parses:
#   L:<layer> N:<role> ID:<id> WS:true O:<orientation>
# L:A (application layer) plus WS:true plus O:U is what makes the window
# fullscreen. The 2019 upstream title "L:D_N:application_ID:xephyr" lands in the
# DIALOG layer instead and the window stays 100x100 forever, because the WM
# intercepts and ignores clients' own resize requests.
# Verified on firmware 5.19.2 (PW5). Re-check with tools/screenshot.sh after any
# firmware update - the convention is proprietary and can change.
env DISPLAY=:0 Xephyr :1 -title "L:A_N:application_ID:xephyr_WS:true_O:U" \
    -ac -br -screen "$SIZE" -cc 4 -reset -terminate &
sleep 3
su alpine -c "env DISPLAY=:1 mate-session"
killall Xephyr
EOF
chmod +x "$MNT/startgui.sh"

# Disable screen locking / blanking: a locked e-ink session with no working
# unlock is a known footgun in this setup, and mate-screensaver fights Xephyr.
printf 'user-db:user\nsystem-db:local\n' > "$MNT/etc/dconf/profile/user"
cat > "$MNT/etc/dconf/db/local.d/00-kindle" <<'EOF'
[org/mate/screensaver]
lock-enabled=false
idle-activation-enabled=false

[org/mate/power-manager]
sleep-display-ac=0
sleep-display-battery=0
EOF

# Chromium launcher flags. --no-sandbox is required: Kindle kernels generally
# ship without user namespaces, so the setuid/userns sandbox cannot start.
# The mouseid lookup resolves at launch time, when Xephyr is running.
#
# Alpine's launcher ends with 'exec "$PROGDIR/chromium" ${CHROMIUM_FLAGS} "$@"'
# - UNQUOTED - so every flag here must contain no whitespace, or the value gets
# word-split and the stray words are passed to Chromium as URLs to open. Hence
# the percent-encoded user agent (this is exactly why upstream did the same).
mkdir -p "$MNT/etc/chromium"
cat > "$MNT/etc/chromium/chromium.conf" <<'EOF'
# Sourced by /bin/sh from the chromium launcher.
mouseid="$(env DISPLAY=:1 xinput list --id-only 'Xephyr virtual mouse' 2>/dev/null)"
CHROMIUM_FLAGS="--no-sandbox --force-device-scale-factor=2 --pull-to-refresh=1 \
--disable-smooth-scrolling --enable-low-end-device-mode --disable-login-animations \
--disable-modal-animations --wm-window-animations-disabled --start-maximized \
--touch-devices=${mouseid} \
--user-agent=Mozilla%2F5.0%20%28Linux%3B%20Android%2010%3B%20K%29%20AppleWebKit%2F537.36%20%28KHTML%2C%20like%20Gecko%29%20Chrome%2F152.0.0.0%20Mobile%20Safari%2F537.36"
EOF

# Compile the system dconf database (inside the image, so dconf matches).
chroot "$MNT" /usr/bin/qemu-arm-static /bin/sh -c \
  'command -v dconf >/dev/null && dconf update || true'

########################## 4. FINISH + RELEASE ######################

log "Cleaning up and unmounting"
rm -f "$MNT/usr/bin/qemu-arm-static"
sync
umount "$MNT/sys"
umount "$MNT/proc"
umount "$MNT/dev/pts"
umount "$MNT/dev"
umount "$MNT" || { sleep 2; umount "$MNT"; }
losetup -d "$LOOPDEV"; LOOPDEV=""

if [ "$SWAP_MB" -gt 0 ]; then
  log "Creating ${SWAP_MB} MiB swap image"
  # Block-device swap (losetup + swapon) rather than a swap *file*: a swap file
  # needs bmap, and the userstore is vfat, which has none.
  dd if=/dev/zero of="$SWAPIMG" bs=1M count="$SWAP_MB" status=progress
  chmod 600 "$SWAPIMG"          # before mkswap: it warns on group/world-readable files
  mkswap "$SWAPIMG" >/dev/null
else
  rm -f "$SWAPIMG"
fi

cp "$HERE/alpine.sh" "$OUTDIR/"
cp "$HERE/contrib/alpine.conf" "$OUTDIR/"   # experimental: see docs/KNOWN-ISSUES.md
"$HERE/create-release.sh"

# Everything above ran as root, so the artifacts are root-owned. Hand them back to
# whoever invoked sudo, otherwise copying the zip to the Kindle needs sudo too.
if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
  chown -R "$SUDO_UID:$SUDO_GID" "$OUTDIR" "$CACHE" 2>/dev/null || true
fi

log "Done."
echo "    image:   $IMAGE ($(du -h "$IMAGE" | cut -f1))"
echo "    release: $OUTDIR/alpine.zip"
echo
echo "Next: read README.md - copy alpine.zip to /mnt/us on the Kindle, unzip it,"
echo "then 'sh alpine.sh' (shell only) or 'start alpine' (MATE desktop)."
