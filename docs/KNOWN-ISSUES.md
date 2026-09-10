# Known issues

Status of each item was established **on real hardware**: Kindle Paperwhite 5 (11th gen),
firmware 5.19.2, kernel 4.9.77-lab126, Véra jailbreak.

| # | Issue | Severity | Status |
|---|---|---|---|
| 1 | `stop alpine` leaves the rootfs mounted and the Kindle UI down | **high** | open — `alpine.conf` is experimental |
| 2 | Landscape (`O:LR`) renders with tearing | medium | open — portrait only |
| 3 | On-screen keyboard (`onboard`) not wired up to MATE | medium | open |
| 4 | Chromium is slow / battery-heavy at 512 MB | low | expected |
| 5 | Chromium `--touch-devices` hint may not resolve | low | untested |

---

## 1. `stop alpine` fails to tear down cleanly

**Symptom.** After `initctl stop alpine`:

```
initctl: Job failed while stopping
```

and the device is left in a half-broken state:

- the rootfs is still loop-mounted at `/tmp/alpine`
- loop devices for `alpine.ext3` and `swap.img` are still attached
- `lab126_gui` is stopped, so **the screen goes white/blank**

**Recovery** (always works, no reboot needed):

```sh
sh /mnt/us/alpine.sh cleanup     # unmounts + detaches loops + kills leftover procs
initctl start lab126_gui         # brings the reader UI back
```

A reboot also fixes it. A reboot is safe — nothing is left half-written; the userstore is
consistent.

**What is already fixed** (three real bugs found and corrected):

1. Bare `stop lab126_gui` in a job script failed with `Unknown instance:` — upstart jobs run
   with a minimal `PATH` that does not include `/sbin`. Now uses an absolute
   `/sbin/initctl`.
2. `kill $(pgrep Xephyr)` — with `pgrep` not on the job's `PATH` this expands to a bare
   `kill`, which signals *the job's own shell*. Now walks `/proc` instead.
3. The `post-stop` had an unbounded `while mount | grep …; do sleep 3; done` retry loop.
   upstart kills a section that overruns, so the loop guaranteed failure. Now bounded, with
   explicit warnings instead of spinning.

**Still unexplained.** The `post-stop` section still terminates partway, immediately after
logging `Unmounting Alpine rootfs`. `lab126_gui` is therefore never restarted by the job.
Note `/bin/sh` on this firmware is **busybox** (which matters: `sleep 0.2` is rejected —
integer only), and `/tmp` is a **symlink to `/var/tmp`**, so the mount actually appears at
`/var/tmp/alpine`.

Suggested next step: run the `post-stop` body under `sh -x` with each line timestamped to a
log file, to find the exact line where it dies. Alternatively sidestep upstart entirely — a
plain wrapper script that does stop/start itself, orchestrated from the shell rather than
from an upstart job, would avoid whatever upstart is doing to the section.

**Meanwhile:** `contrib/alpine.conf` is shipped for reference but **not recommended**, and it
has no `start on` line so it can never auto-start. The supported path is:

```sh
sh /mnt/us/alpine.sh              # shell
sh /mnt/us/alpine.sh startgui     # desktop
```

`startgui` does **not** stop the Kindle UI, so it cannot strand the device — at the cost of
~100-150 MB more RAM in use.

---

## 2. Landscape tears

Rotation itself works. Adding `O:LR` to the window title makes the WM rotate the screen:

```
O:U   -> lipc-get-prop com.lab126.winmgr orientation = U, root 1236x1648
O:LR  -> orientation = R, root 1648x1236         (correct)
```

But the rendered result is unusable — frames come out with smeared/ghosted panel artifacts,
while portrait is clean. `-fakescreenfps 30` made no difference, so it is not Xephyr's 2 fps
default fake-screen rate; it looks like the rotation + damage-tracking path in the `ligl`
display stack.

Next steps worth trying: set the orientation *before* Xephyr maps its window (rather than via
the window title at map time); check whether `ligl` damage rectangles are being computed for
the rotated geometry; compare against KOReader, which rotates cleanly.

Until then `startgui.sh` hardcodes `O:U`.

---

## 3. `onboard` is not started automatically

`onboard` is installed in the image (and MATE's screensaver is configured not to lock, partly
so a locked screen with no keyboard isn't possible), but nothing launches it, and MATE's
accessibility keyboard integration is not configured. Launch manually inside the session:

```sh
DISPLAY=:1 onboard -e &
```

To wire it up properly:

```sh
gsettings set org.mate.screensaver embedded-keyboard-enabled true
gsettings set org.mate.screensaver embedded-keyboard-command 'onboard -e'
```

---

## 4/5. Chromium

The device has **474 MB usable RAM** (a 512 MB device). MATE + Chromium is a tight fit; expect
slow page loads and heavy swap use. Chromium launches with `--no-sandbox` because Kindle
kernels lack user namespaces.

`netsurf` is installed as the light fallback and is the better default for e-ink.

The `--touch-devices=${mouseid}` flag is resolved at launch time from
`xinput list --id-only 'Xephyr virtual mouse'`. If the virtual pointer is named differently,
that flag silently does nothing and touch scrolling in Chromium won't work. Unverified.

---

## Not a bug: the window title is load-bearing

If the desktop window appears as a 100x100 stamp in the corner, the title is wrong. The
Kindle WM parses the window **name** and refuses to let clients size themselves; the 2019
upstream title `L:D_N:application_ID:xephyr` lands in the *dialog* layer. See
[COMPATIBILITY.md](COMPATIBILITY.md) for the full convention. Current:

```
L:A_N:application_ID:xephyr_WS:true_O:U
```
