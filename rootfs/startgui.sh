#!/bin/sh
# Runs inside the chroot. Nests an X server on the Kindle's :0 and starts JWM.
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

SIZE="$(xwininfo -root -display :0 | awk '/-geometry/{print $2; exit}')"
[ -n "$SIZE" ] || SIZE=1236x1648

# The window title is a lab126 convention the Kindle's WM parses:
#   L:<layer> N:<role> ID:<id> WS:true O:<orientation>
# L:A (application layer) plus WS:true plus O:U makes the window fullscreen.
env DISPLAY=:0 Xephyr :1 -title "L:A_N:application_ID:xephyr_WS:true_O:U" \
    -ac -br -screen "$SIZE" -cc 4 -reset &
xephyr_pid=$!

# Wait until clients can connect instead of relying on a fixed device-speed delay.
attempt=0
until env DISPLAY=:1 xdpyinfo >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 20 ] || ! kill -0 "$xephyr_pid" 2>/dev/null; then
    echo "ERROR: Xephyr display :1 did not become ready." >&2
    kill "$xephyr_pid" 2>/dev/null || true
    wait "$xephyr_pid" 2>/dev/null || true
    exit 1
  fi
  sleep 1
done

su alpine -c "env DISPLAY=:1 dbus-run-session -- /usr/local/bin/kindle-session"
status=$?
kill "$xephyr_pid" 2>/dev/null || true
wait "$xephyr_pid" 2>/dev/null || true
exit "$status"
