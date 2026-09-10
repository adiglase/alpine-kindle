# Alpine Linux for modern Kindles (armhf / `kindlehf`)

Run a full Alpine Linux desktop on a jailbroken Kindle via `chroot` — no flashing, no
repartitioning, no risk to the stock firmware. Everything lives inside one `.ext3` image
file on the userstore.

This is a modernization of [schuhumi/alpine_kindle](https://github.com/schuhumi/alpine_kindle)
(2019), rebuilt for current Alpine and current Kindle firmware, and for the
**Paperwhite 5 / 11th generation** in particular.

## Status

| | |
|---|---|
| **Target device** | Kindle Paperwhite 5 (11th gen), firmware 5.19.x, Véra jailbreak |
| **Build verified** | package set resolves against Alpine **v3.24** `armv7`; image builds cleanly |
| **Runtime verified** | ✅ **end-to-end on PW5 / firmware 5.19.2**: chroot, 512 MB swap, and the MATE desktop fullscreen on the e-ink panel |
| **Also expected to work** | any `armhf` Kindle with a touchscreen and ≥512 MB RAM |

## What's different from upstream

| | upstream (2019) | here |
|---|---|---|
| Alpine | `edge` as of Aug 2019 | pinned **v3.24** (`main` + `community`) |
| Bootstrap | scrape APKINDEX + `apk-tools-static`, mixed `armhf`/`armv7` | official **minirootfs** tarball, one arch throughout |
| Desktop | `apk search mate` wildcard, `consolekit`, `gtk-engines`, `gnome-themes-extra` | **`mate-desktop-environment`** meta (those 4 packages no longer exist upstream) |
| Fonts | `apk search ttf-` — matches 1 package today | explicit `font-dejavu font-liberation font-noto` |
| Image | 2 GB | configurable, **2.5 GB** default for an 8 GB device |
| Swap | none | optional **block swap** image (a swap *file* can't live on vfat) |
| Screen locking | unaddressed | lock/blanking disabled via dconf (locking e-ink is a footgun) |
| Default account | `alpine` / `alpine` | **no password baked in** — `passwd alpine` on first run |

## Quick start

### On the Kindle — check compatibility first

```sh
uname -m        # must be: armv7l
uname -r        # e.g. 4.9.77-lab126
df -h /mnt/us   # image + swap must fit, and stay under 4 GB per file (FAT32)
```

### On the build host

```sh
sudo apt install qemu-user-static
git clone <this repo> && cd alpine-kindle
sudo IMAGESIZE_MB=2560 SWAP_MB=512 ./build-image.sh
```

Options (environment variables):

```sh
sudo WITH_CHROMIUM=no ./build-image.sh     # netsurf only: ~700 MiB instead of ~1.0 GiB
sudo SWAP_MB=0 ./build-image.sh            # no swap image
sudo IMAGESIZE_MB=4095 ./build-image.sh    # hard ceiling: /mnt/us is FAT32, so < 4 GiB per file
sudo ALPINE_BRANCH=v3.23 ./build-image.sh  # pin a different stable branch
```

Output: `release/alpine.zip`.

### On the Kindle

```sh
cd /mnt/us
unzip alpine.zip
sh alpine.sh                              # a shell inside Alpine (you land in it as root)
passwd alpine                             # do this first - no password is baked into the image
exit
sh alpine.sh startgui                     # + MATE desktop (Xephyr on the Kindle's X server)
```

Or install the upstart job so the Kindle UI is stopped first (frees a lot of RAM):

```sh
mntroot rw
cp /mnt/us/alpine.conf /etc/upstart/
mntroot r
start alpine
```

## How it works

The Kindle already runs Linux with X11. We mount the Alpine rootfs from a loop-mounted
image file, graft the kernel's live interfaces into it, and `chroot`:

```
mount -o loop,noatime -t ext3 /mnt/us/alpine.ext3 /tmp/alpine
mount -o bind /dev /dev/pts /proc /sys  ->  inside the chroot
mount -o bind /var/run/dbus             ->  inside the chroot
chroot /tmp/alpine /bin/sh
```

The desktop runs as a **nested X server**: `Xephyr :1` displays inside a window on the
Kindle's own X server (`:0`), fullscreened by the Kindle's `awesome` window manager via the
lab126 window-title hint `L:D_N:application_ID:xephyr`. See
[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) for the evidence that this stack is still
present on current firmware.

## Project layout

```
build-image.sh        build alpine.ext3 + swap.img, pack the release (run as root on the host)
create-release.sh     packs release/alpine.zip (called by build-image.sh)
alpine.sh             Kindle side: mount, swap, chroot, clean unmount, `cleanup` recovery mode
alpine.conf           upstart job: stop lab126_gui -> restart pillow -> desktop -> restore the UI
docs/COMPATIBILITY.md what was verified, on which firmware, and why the choices were made
docs/TROUBLESHOOTING.md  what to do when it doesn't come up
docs/KNOWN-ISSUES.md     open problems, with the evidence gathered so far
docs/DEVELOPMENT.md      test device, SSH access, and the device quirks that bite
tools/diag.sh         on-Kindle loop/swap diagnostics (self-cleaning)
tools/screenshot.sh   dump the panel over SSH, so you can see the screen from your PC
```

## Two things the desktop needs (512 MB devices)

The Kindle and MATE cannot both have the RAM, and the display path has a trap:

- `stop lab126_gui` frees ~100-150 MB. X and `awesome` are a **separate** upstart job and survive.
- Stopping the UI also stops **`pillowd`** (`stop on stopping lab126_gui`), which is what pushes
  the framebuffer to the panel. Without `initctl start pillow` the screen freezes even though X
  is fine. `alpine.conf` does both, in that order.
- The desktop window must be titled `L:A_N:application_ID:xephyr_WS:true_O:U`. The Kindle WM
  parses window names and refuses to let clients size themselves; the 2019 title lands in the
  *dialog* layer and the window stays 100x100. Details in docs/COMPATIBILITY.md.

## Gotchas

- **Never connect USB while Alpine is mounted.** On 11th gen you get MTP (file-level) instead of
  raw mass storage, so it's less catastrophic than it was on a PW3 — but the rule stands.
- **4 GB ceiling** — `/mnt/us` is FAT32. Keep `IMAGESIZE_MB` below 4096.
- **Swap is a block image**, not a swap file: swap files need `bmap`, and vfat has none.
- **Chromium runs with `--no-sandbox`** because Kindle kernels lack user namespaces. No default
  password is baked into the image, so set one (`passwd alpine`) before browsing anything —
  otherwise an unsandboxed browser bug is one `sudo` away from root on the Kindle.
- Don't use "Toggle USBNet" on newer firmware (it can trap the UI). Use USBNetLite.
- See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) when something hangs.

## Roadmap

- [ ] Confirm end-to-end on real hardware (PW5, 5.19.2)
- [ ] `aarch64` variant if any Kindle reports `uname -m` = `aarch64`
- [ ] Verify/repair the `--touch-devices` hint for modern Chromium
- [ ] Optional: XFCE / openbox profile for 512 MB devices
- [ ] CI: build the image on every push (it's just `apk` + `tar`; no hardware needed)

## License & credits

Derivative work of [schuhumi/alpine_kindle](https://github.com/schuhumi/alpine_kindle),
which designed the original chroot + Xephyr approach and is **GPL-3.0**. This project is
therefore **GPL-3.0** as well. See [LICENSE](LICENSE).

Additional credit for the ecosystem this leans on:
[KindleModding](https://kindlemodding.org/) (jailbreaks, KPM, docs),
[bfabiszewski/kterm](https://github.com/bfabiszewski/kterm).
