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

Download the prebuilt image on a computer, verify it there, and then copy it to the Kindle.
The Kindle does not need QEMU or any build tools. Avoid downloading the large archive over
the Kindle's Wi-Fi.

### On the Kindle — check compatibility first

```sh
uname -m        # must be: armv7l
uname -r        # e.g. 4.9.77-lab126
df -h /mnt/us   # image + swap must fit, and stay under 4 GB per file (FAT32)
```

### On a computer — download and verify

```sh
curl -fLO https://github.com/adiglase/alpine-kindle/releases/latest/download/alpine.zip
curl -fLO https://github.com/adiglase/alpine-kindle/releases/latest/download/alpine.zip.sha256
sha256sum --check alpine.zip.sha256
```

The checksum command must report `alpine.zip: OK`. You can instead download both files from
the [GitHub Releases page](https://github.com/adiglase/alpine-kindle/releases); use assets
from the same release. Each release also has a human-readable `BUILD-INFO.txt` recording the
source commit, exact Alpine point release, image size, and build options.

Copy the zip while Alpine is **not mounted**. Use MTP, or SSH if your jailbreak provides it:

```sh
scp alpine.zip root@KINDLE_IP:/mnt/us/
```

If SSH uses a non-default port, `scp` spells the port option with an uppercase `-P`, for
example `scp -P 2222 alpine.zip root@KINDLE_IP:/mnt/us/`.

### Custom local builds

Build locally when you want a different image size, swap size, Alpine stable branch, or
browser selection. On a Debian/Ubuntu Linux host:

```sh
sudo apt install curl e2fsprogs git qemu-user-static unzip util-linux zip
git clone https://github.com/adiglase/alpine-kindle.git
cd alpine-kindle
sudo IMAGESIZE_MB=2560 SWAP_MB=512 ./build-image.sh
sha256sum --check release/alpine.zip.sha256
```

The build needs about 8 GB of free disk space and produces `release/alpine.zip` plus its
checksum and build metadata.

Options (environment variables):

```sh
sudo WITH_CHROMIUM=no ./build-image.sh     # netsurf only: ~700 MiB instead of ~1.0 GiB
sudo SWAP_MB=0 ./build-image.sh            # no swap image
sudo IMAGESIZE_MB=4095 ./build-image.sh    # hard ceiling: /mnt/us is FAT32, so < 4 GiB per file
sudo ALPINE_BRANCH=v3.23 ./build-image.sh  # pin a different stable branch
```

For a local build, copy the resulting archive to the Kindle while Alpine is not mounted:

```sh
scp release/alpine.zip root@KINDLE_IP:/mnt/us/
```

### On the Kindle

```sh
cd /mnt/us
unzip alpine.zip
sh install.sh                             # accept the default: do not install the experimental job
rm alpine.zip                             # recover about 500 MB after extraction
sh alpine.sh                              # a shell inside Alpine (you land in it as root)
passwd alpine                             # do this first - no password is baked into the image
exit
sh alpine.sh startgui                     # MATE desktop (Xephyr on the Kindle's X server)
```

`startgui` leaves the Kindle UI running. It is the safest first test, but with only 512 MB
RAM it is tight and may swap heavily.

There is also an experimental upstart job that stops the Kindle UI first and frees about
150 MB. Its teardown now unmounts cleanly, but restarting Amazon's UI can briefly trigger
its own crash-recovery screen. Do not install it on a first run. If you deliberately want
to test it, read
[`docs/KNOWN-ISSUES.md`](docs/KNOWN-ISSUES.md#1-stop-alpine-fails-to-tear-down-cleanly),
then run `sh install.sh` again and answer `y`.

Recovery if `stop alpine` fails:

```sh
sh /mnt/us/alpine.sh cleanup
initctl start lab126_gui
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
lab126 window-title hint `L:A_N:application_ID:xephyr_WS:true_O:U`. See
[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) for the evidence that this stack is still
present on current firmware.

## Project layout

```
build-image.sh        build alpine.ext3 + swap.img, pack the release (run as root on the host)
create-release.sh     packs the zip, checksum, and build metadata (called by build-image.sh)
alpine.sh             Kindle side: mount, swap, chroot, clean unmount, `cleanup` recovery mode
contrib/alpine.conf   experimental upstart job: stop UI -> desktop -> restore the UI
docs/COMPATIBILITY.md what was verified, on which firmware, and why the choices were made
docs/TROUBLESHOOTING.md  what to do when it doesn't come up
docs/KNOWN-ISSUES.md     open problems, with the evidence gathered so far
tools/diag.sh         on-Kindle loop/swap diagnostics (self-cleaning)
tools/install.sh      validates an extracted release and optionally installs the upstart job
tools/uninstall.sh    removes Alpine runtime state, installed files, and userstore files
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
  raw mass storage, but unmount Alpine before any USB transfer.
- **4 GB ceiling** — `/mnt/us` is FAT32. Keep `IMAGESIZE_MB` below 4096.
- **Swap is a block image**, not a swap file: swap files need `bmap`, and vfat has none.
- **Chromium runs with `--no-sandbox`** because Kindle kernels lack user namespaces. No default
  password is baked into the image, so set one (`passwd alpine`) before browsing anything —
  otherwise an unsandboxed browser bug is one `sudo` away from root on the Kindle.
- Don't use "Toggle USBNet" on newer firmware (it can trap the UI). Use USBNetLite.
- See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) when something hangs.

## Uninstall

Preview every change, then uninstall while keeping the large image for a quick reinstall:

```sh
sh /mnt/us/uninstall.sh --dry-run --keep-image
sh /mnt/us/uninstall.sh --keep-image
```

Omit `--keep-image` to remove the image and swap too. A reboot afterwards is recommended.
The jailbreak, KOReader, books, and Kindle settings are not touched.

## Roadmap

Open work is tracked in the repository's [GitHub issues](https://github.com/adiglase/alpine-kindle/issues).
The teardown fix for [#1](https://github.com/adiglase/alpine-kindle/issues/1) is verified in
this tree; the manual shell and `startgui` paths also work on the PW5 test device.

## License & credits

Derivative work of [schuhumi/alpine_kindle](https://github.com/schuhumi/alpine_kindle),
which designed the original chroot + Xephyr approach and is **GPL-3.0**. This project is
therefore **GPL-3.0** as well. See [LICENSE](LICENSE).

Additional credit for the ecosystem this leans on:
[KindleModding](https://kindlemodding.org/) (jailbreaks, KPM, docs),
[bfabiszewski/kterm](https://github.com/bfabiszewski/kterm).
