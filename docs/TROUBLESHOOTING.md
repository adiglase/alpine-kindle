# Troubleshooting

Start with the log. Every path that matters writes to `/mnt/us/alpine.log` when you use the
upstart route (`start alpine`), and to the terminal when you use `sh alpine.sh`.

```sh
cat /mnt/us/alpine.log
```

## The Kindle UI is gone / screen is blank

Reboot (hold power ~20 s). Upstart starts `lab126_gui` fresh on boot, and nothing in this
project modifies the stock filesystem beyond one file in `/etc/upstart/`.

Don't panic and don't factory reset — SSH or kterm is your recovery channel:

```sh
stop alpine          # if the job is running
reboot
```

To remove the upstart job entirely:

```sh
mntroot rw
rm /etc/upstart/alpine.conf
mntroot ro
```

## `sh alpine.sh` fails to mount

Check the image is where the script expects, and that nothing else holds it:

```sh
ls -l /mnt/us/alpine.ext3
mount | grep alpine
losetup -a
```

If it's stuck mounted, unmount in the right order (bind mounts first, image last):

```sh
umount /tmp/alpine/run/dbus /tmp/alpine/sys /tmp/alpine/proc /tmp/alpine/dev/pts /tmp/alpine/dev
umount /tmp/alpine
```

## No desktop appears after `startgui`

First, look at the screen without your eyes: `tools/screenshot.sh` dumps the panel over
SSH. That answers "is it black, the wrong size, or not there at all" in seconds.

1. Is Xephyr running? `ps | grep Xephyr`
2. **Is the window the right size?** The Kindle WM parses the window *name* and refuses to
   let clients size themselves (`xdotool windowsize` is silently ignored). Check:
   ```sh
   chroot /tmp/alpine /usr/bin/xwininfo -root -tree -display :0 | grep -i xephyr
   ```
   You want `1236x1648+0+0`. The 2019 upstream title (`L:D_N:application_ID:xephyr`) gives
   **100x100**, because `L:D` is the *dialog* layer. The correct title is:
   ```
   L:A_N:application_ID:xephyr_WS:true_O:U
   ```
   Full convention: docs/COMPATIBILITY.md.
3. **Is KOReader running?** It paints the framebuffer directly and hides everything X draws.
   Exit KOReader first - its SSH daemon keeps working, it is a separate process.
4. **Did pillow survive?** If the Kindle UI was stopped, `pillowd` went with it and the panel
   stops updating, so the screen looks frozen even though X is fine:
   ```sh
   initctl status pillow     # want: start/running
   initctl start pillow
   ```
5. **Out of memory?** MATE needs the UI stopped at 512 MB. `free -m` inside the chroot.

Can the chroot reach the Kindle's X server?

```sh
chroot /tmp/alpine /bin/sh
DISPLAY=:0 xdpyinfo | head      # if this fails, X is not reachable / not running
```

## Getting the Kindle UI back

```sh
initctl start lab126_gui        # restores the reader UI
```

If the Alpine rootfs is left mounted, unmount it first with `sh /mnt/us/alpine.sh cleanup`,
or use `start alpine` / `stop alpine` so the upstart job manages both sides.

## `swapon failed`

Your kernel is built without `CONFIG_SWAP`, or the loop device couldn't be attached. Harmless —
the scripts continue without swap. To reduce memory pressure instead, use `WITH_CHROMIUM=no`
and/or run the desktop with the Kindle UI stopped (`start alpine`).

## Chromium won't start, or dies immediately

- It's launched with `--no-sandbox` (Kindle kernels lack user namespaces). If that's still not
  enough, check free memory: `free -m` inside the chroot.
- Try starting it from a terminal inside the session so you see the error:
  ```sh
  DISPLAY=:1 chromium 2>&1 | head -40
  ```
- Fallback: `netsurf` is installed and much lighter.

## Touch input / on-screen keyboard

`onboard` is installed in the image. If the keyboard doesn't appear when you tap a text field,
launch it manually:

```sh
DISPLAY=:1 onboard -e &
```

Chromium's `--touch-devices` hint is resolved at launch time from
`xinput list --id-only 'Xephyr virtual mouse'`; if the virtual pointer has a different name on
your firmware, that flag silently does nothing.

## "No space left on device"

- The **image file** must stay below **4096 MiB** — `/mnt/us` is FAT32 and a 4 GiB+ file cannot
  exist there. Rebuild with a smaller `IMAGESIZE_MB`.
- Inside Alpine, check with `df -h /`. `apk` refuses to install when the image's free space runs
  out; that space is fixed at build time, so rebuild bigger rather than deleting things.

## Network doesn't work inside the chroot

`alpine.sh` copies the Kindle's live `/etc/resolv.conf` in at mount time. If DNS is stale,
inside the chroot:

```sh
echo 'nameserver 1.1.1.1' > /etc/resolv.conf
```

`apk` uses `http` repositories by default here (a bare minirootfs has no CA bundle until
`ca-certificates` is installed) — packages are still signature-verified via the keys in
`/etc/apk/keys`.

## Recovering from a corrupted image

The image is disposable — the Kindle OS is untouched by it:

```sh
# on the PC
scp release/alpine.ext3 root@kindle:/mnt/us/     # just re-copy it
```

If the *userstore* itself is damaged (rare; mostly a legacy mass-storage-era hazard), that is a
filesystem-level problem, not an Alpine one. Fix it from a shell with the device's own tools,
or restore from a backup of your books.

## Reporting a bug

Include: `uname -m`, `uname -r`, firmware version, jailbreak, model, the build options used,
and the full output of `cat /mnt/us/alpine.log` plus any error from `sh alpine.sh`.
