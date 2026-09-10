# Known issues

Hardware-related status was established on a real Kindle Paperwhite 5 (11th gen), firmware
5.19.2, kernel 4.9.77-lab126, Véra jailbreak. Release automation status is established in CI.

| # | Issue | Severity | Status |
|---|---|---|---|
| 1 | `stop alpine` leaves the rootfs mounted and the Kindle UI down | **high** | fixed in tree — verified twice on PW5 |
| 2 | Landscape (`O:LR`) renders with tearing | medium | open — portrait only |
| 3 | On-screen keyboard (`onboard`) not wired up to MATE | medium | fixed in tree — verified on PW5 |
| 4 | Chromium `--touch-devices` hint may not resolve | low | untested |
| 5 | No prebuilt GitHub Release | medium | fixed in tree — `v*` tags publish a verified zip |
| 6 | Memory and swap strategy needs tuning | medium | open — current disk swap works |
| 7 | Uninstaller does not unload project-loaded kernel modules | low | latent — none are loaded today |

---

## 1. `stop alpine` teardown — fixed, UI restart still experimental

**Original symptom.** Before the fix, `initctl stop alpine` produced:

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

**Root causes and fixes.** The original three fixes were necessary but incomplete:

1. Bare `stop lab126_gui` in a job script failed with `Unknown instance:` — upstart jobs run
   with a minimal `PATH` that does not include `/sbin`. Now uses an absolute
   `/sbin/initctl`.
2. `kill $(pgrep Xephyr)` — with `pgrep` not on the job's `PATH` this expands to a bare
   `kill`, which signals *the job's own shell*. Now walks `/proc` instead.
3. The `post-stop` had an unbounded `while mount | grep …; do sleep 3; done` retry loop.
   upstart kills a section that overruns, so the loop guaranteed failure. Now bounded, with
   explicit warnings instead of spinning.
4. Upstart executes job sections with error-exit behavior. The first rootfs `umount` normally
   returned busy while MATE was still exiting, which aborted `post-stop` before its retry and
   before the UI restart. Expected failures are now handled explicitly.
5. `/tmp` resolves to `/var/tmp`, so matching only `on /tmp/alpine` falsely reported that a
   live `/var/tmp/alpine` mount was gone. Mount checks now compare both logical and resolved
   paths through `/proc/mounts`.
6. A chroot-scoped `dbus-launch` survived `mate-session` and held the `/proc` bind. `post-stop`
   now kills only processes whose resolved root is inside the Alpine mount, retries each bind
   mount separately for at most ten seconds, and never detaches the rootfs loop while mounted.
7. The job's swap setup used only `losetup -f`, which names a nonexistent flat node on this
   firmware. It now uses the launcher's complete sysfs plus `/dev/loop/<N>` detection; hardware
   verification showed `/dev/loop/12` providing the intended 512 MB swap and disappearing on
   stop.

The clean-room audit also found that this firmware accepts `mntroot ro`, not `mntroot r`.
Installer and uninstaller now use the verified spelling, check failures, and leave `/` read-only.

**Hardware verification.** Multiple consecutive stops on the PW5 completed with `stop_exit=0`,
`alpine stop/waiting`, `lab126_gui start/running`, no Alpine mounts, and no Alpine-backed
loops. The non-instrumented public job was used for the final runs, including one with the
project swap active.

**Remaining caveat.** After the final stop, Amazon's UI displayed its `KPPMainAppV2` core-dump
collector once, then recovered to the normal Home screen after about 30 seconds. The Alpine
state was already clean and the stock root filesystem was read-only. A full reboot remains
more reliable than surgically rebuilding the Amazon UI service ordering.

`contrib/alpine.conf` therefore remains opt-in and has no `start on` line, so it can never
auto-start. The safest supported path remains:

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

## 3. On-screen keyboard — fixed

Onboard now starts hidden with the MATE session and automatically appears when an accessible
text field receives focus. It uses the compact, high-contrast layout and docks to the bottom
500 pixels of the 1236x1648 portrait display, shrinking the application work area while shown.

MATE's screensaver XEmbed command is also configured (`onboard -e`). Screen locking remains
disabled because the screensaver and Kindle's nested e-ink display path still need separate
hardware validation; enabling a lock by default would make a regression difficult to recover
from. The configured keyboard removes the previous prerequisite for that future testing.

Verified on a PW5 at 1236x1648: MATE autostarts Onboard, AT-SPI focus events show and hide it,
and pointer input reaches its keys through Xephyr. Physical multi-touch gestures remain outside
this issue's single-touch keyboard scope.

---

## 4. Chromium touch scrolling

Chromium launches with `--no-sandbox` because Kindle kernels lack user namespaces.

The `--touch-devices=${mouseid}` flag is resolved at launch time from
`xinput list --id-only 'Xephyr virtual mouse'`. If the virtual pointer is named differently,
that flag silently does nothing and touch scrolling in Chromium won't work. Unverified.

## 5. Prebuilt GitHub Release — fixed

A push of a `v*` tag now builds the documented 2560 MiB image and 512 MiB swap, creates the
tagged GitHub Release if needed, and attaches `alpine.zip`, `alpine.zip.sha256`, and
`BUILD-INFO.txt`. CI verifies the checksum and archive both before upload and after downloading
the published assets. The README leads with this no-build path; local builds remain supported
for custom image, swap, browser, or Alpine branch choices.

No tagged image existed before this automation, so the first published image will be the first
release with these assets. See [COMPATIBILITY.md](COMPATIBILITY.md#published-images) for the
per-release Alpine version record.

## 6. Memory and swap strategy

The device has **474 MB usable RAM** (a 512 MB device), plus the Kindle's existing 128 MB
`/dev/zram0`. MATE with the Kindle UI still running is too tight for comfortable use. The
experimental upstart path stops the UI and has been measured at about 451 MB used with about
57 MB of the project's 512 MB disk swap in use.

Chromium is slow and battery-heavy in this budget; `netsurf` is the better default for e-ink.
A second zram device may outperform disk swap and could shrink the release, but it must be
benchmarked without altering the Kindle's existing `/dev/zram0`. Track this in
[GitHub issue #6](https://github.com/adiglase/alpine-kindle/issues/6).

## 7. Kernel modules are not unloaded

The project does not currently load any kernel modules, so this has no runtime effect today.
If zram or a future feature loads modules, the launcher must record exactly which modules it
loaded and the uninstaller must remove only those, in reverse dependency order. It must never
guess or unload modules already used by the stock system. Track this in
[GitHub issue #7](https://github.com/adiglase/alpine-kindle/issues/7).

---

## Not a bug: the window title is load-bearing

If the desktop window appears as a 100x100 stamp in the corner, the title is wrong. The
Kindle WM parses the window **name** and refuses to let clients size themselves; the 2019
upstream title `L:D_N:application_ID:xephyr` lands in the *dialog* layer. See
[COMPATIBILITY.md](COMPATIBILITY.md) for the full convention. Current:

```
L:A_N:application_ID:xephyr_WS:true_O:U
```
