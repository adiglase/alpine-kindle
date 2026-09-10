# Compatibility notes

Everything below was checked against live sources rather than recalled from memory. Where a
claim is a community report rather than something I could execute, it says so.

## Device matrix

| Device | SoC / kernel | Userspace | Status |
|---|---|---|---|
| **PW5** (Paperwhite 11th gen, 2021) | MediaTek, **4.9.77-lab126** (reported on FW 5.19.2) | armv7l / armhf | **primary target**; package set verified, not yet booted |
| PW5 SE | same family | armhf | expected identical |
| Kindle 10th gen (2019) | i.MX7 / 6SoloLite, kernel 4.1.15 | armv7l, no NEON | community chroot project tested this config on FW 5.18.1 |
| PW3 (7th gen, 2015) | i.MX6SL, 3.0.x-era kernel, 512 MB | armv7l | upstream project's target; smaller image recommended |
| Kindle Touch (2011) | i.MX50, 256 MB | armv7l | reported working but very slow (upstream issue #12) |
| Kindle gen 3 | i.MX35 (ARMv6) | — | not supported: no touchscreen, different init |
| aarch64 Kindles | — | — | not covered by this image; would need an `aarch64` build |
| Kindle Fire | — | Android | never — different platform |

## Measured on real PW5 hardware (firmware 5.19.2)

Everything in this section was read off the device, not taken from a spec sheet.

| Fact | Value |
|---|---|
| Model string | `MT8110 Bellatrix device` (Paperwhite 5 / 11th gen) |
| Kernel | `4.9.77-lab126 armv7l` |
| RAM | **474 MB visible -> 512 MB device.** The PW5 is the same 512 MB class as the PW3, *not* 1 GB |
| Stock swap | `/dev/zram0`, 128 MB, priority -1 (the Kindle's own compressed-RAM swap) |
| Loop devices | **`/dev/loop/<N>`, a directory** - not `/dev/loop<N>`. Nodes 0..16 exist; loops 0, 2-11 are used by firmware squashfs images |
| `/tmp` | symlink to `/var/tmp` (so the mount actually lands on `/var/tmp/alpine`) |
| Framebuffer | `/dev/fb0`: 1248x3296, 8bpp grayscale, stride 1248, rotate 3, two 1648-row frames; visible frame = the first 1236x1648 |
| Display daemon | `pillowd` (upstart job `pillow`) pushes the framebuffer to the panel. **It stops with `lab126_gui`** (`stop on stopping lab126_gui`), which freezes the screen |
| X + WM | separate upstart job `x` (Xorg + awesome). They **survive** `stop lab126_gui` |

### The window-title convention (the hard-won bit)

The Kindle WM is a patched awesome (`/etc/xdg/awesome/lab126LayerLogic.lua`) that
parses the window **name** as `key:value` pairs:

```
L:<layer>_N:<role>_ID:<id>_WS:true_O:<orientation>
```

- `L:A` = application layer, `L:D` = dialog layer, `L:C` = chrome layer
- The WM **intercepts ConfigureRequests**: a client cannot size or move itself, and
  `xdotool windowsize` is silently ignored. Only the WM assigns geometry.
- For app-layer windows the WM runs `prv_position_application()`, which sizes the
  window to the screen minus chrome offsets - i.e. fullscreen.
- Upstream 2019's title `L:D_N:application_ID:xephyr` therefore lands in the
  **dialog** layer and the window stays **100x100 forever**.
- Working title: **`L:A_N:application_ID:xephyr_WS:true_O:U`** -> `1236x1648+0+0`.

Real windows from the framework, for comparison:

```
L:A_N:application_ID:com.lab126.booklet.home_..._PC:TSB_RC:true_WT:true_ASR:true_O:U   1236x1270+0+216
L:A_N:application_..._ID:com.lab126.KPPMainApp_..._PC:T_O:UD_S:-1                     1236x1547+0+101
L:A_N:application_module:blankwindow_ID:blankBackground_WS:true                       1236x1648+0+0
```

### Running the desktop needs two things beyond the chroot

1. **Stop the Kindle UI** (`stop lab126_gui`) to free ~100-150 MB - mandatory at 512 MB.
   X and awesome survive; `pillow` does not, so:
2. **Restart `pillow`** (`initctl start pillow`) or the panel freezes.
   Done in `alpine.conf`; this is the same trick KOReader's X-app plugin uses.

### KOReader conflict

KOReader paints the framebuffer directly and suspends the WM, so while it runs,
nothing an X server draws is visible. Its SSH daemon (dropbear) has `ppid 1` and
survives KOReader exiting. KOReader's own X-app plugin uses the same idea:
`killall -CONT awesome` -> run the X app -> `killall -STOP awesome`.

### Seeing the screen without looking at it

`tools/screenshot.sh` dumps `/dev/fb0` over SSH and converts it locally. That is how
every conclusion above was verified; use it after any firmware update, since the
naming convention is proprietary and can change.

## Why `armv7` / `armhf`

- The modern Kindle ecosystem's package format is suffixed **`kindlehf`**, documented in
  KindleModding's KPM docs as *"armhf platforms"*.
- Verified directly: `alpine-minirootfs-3.24.0-armv7.tar.gz` contains
  `ELF 32-bit LSB pie executable, ARM, EABI5 ... interpreter /lib/ld-musl-armhf.so.1`.
- `kindle-userspace` (Scribe, FW 5.19.5) ships **static `linux/arm`** binaries.
- So despite 64-bit SoCs in newer Kindles, the userspace ABI is 32-bit ARM hard-float.

## Why the desktop approach still works on current firmware

The whole design rests on two things being present in the *stock* OS: X11 with the `awesome`
window manager, and upstart's `lab126_gui` job.

- **X11 + awesome:** on a **PW5 SE, firmware 5.18.6**, launching `kterm` from KOReader required
  stopping the WM — reported as *"KOReader stops the WM (awesome) when starting"*
  ([mireq/KOReader-kindle-start-x-app#2](https://github.com/mireq/KOReader-kindle-start-x-app/issues/2)).
- **upstart:** the KindleModding PW6 boot diagram still contains `lab126_gui`,
  `lab126_gui_setup`, `lab126_gui_monitor`, `xinit`, `display_ready`
  ([upstart-diagram](https://github.com/KindleModding/kindlemodding.github.io/blob/main/static/kindle-hacking/upstart-diagram.html)).

Not verified off-device: whether `Xephyr` can still attach to `:0` *after* `lab126_gui` is
stopped on 5.19.x. This is the highest-risk assumption in the project.

## Package audit — 2019 list vs Alpine v3.24 (`armv7`)

| 2019 package | v3.24 `main`+`community` | Action |
|---|---|---|
| `xorg-server-xephyr` | 21.1.24 | keep |
| `xwininfo`, `xinput`, `xdotool` | present | keep (+ `xdpyinfo`, `xset`, `xauth` added for debugging) |
| `caja`, `caja-extensions`, `marco` | 1.28.x | keep |
| `onboard` | 1.4.4.2 | keep |
| `chromium` | 152.x | keep (optional; 127 MiB download / 227 MiB installed) |
| `netsurf` | 3.11 | keep as the light fallback browser |
| `gtk-engines` | **gone** | drop; `mate-themes` covers it |
| `gtk-murrine-engine` | **gone** | drop |
| `gnome-themes-extra` | **gone** | `adwaita-icon-theme` + `mate-themes` |
| `consolekit` | **gone** | `elogind` is the modern session stack |
| `apk search -q ttf-` | matches **1** package (`ttf-liberation`) | fonts renamed to `font-*` (284 packages) |
| `apk search mate` | matches **76** incl. `-dev`/`-doc`/`-lang` | use `mate-desktop-environment` meta |
| APKINDEX from `armhf`, tools from `armv7` | mismatch | single arch throughout |

## Size budget

Resolved for real with `apk --arch armv7` against `v3.24` (`main` + `community`):

| Set | Installed |
|---|---|
| MATE + Xorg + onboard + netsurf + fonts + tooling | **714 MiB** |
| …plus Chromium | **1033 MiB** |

Constraints:

- `/mnt/us` is **FAT32** → the image file must stay **below 4096 MiB**.
- Swap must be a **block image** (`losetup` + `swapon`), because a swap file requires `bmap`
  and vfat has none.
- Script defaults: **2560 MiB image + 512 MiB swap** = 3 GiB on a device reporting 5.6 GiB free.

## Tooling / jailbreak context (external, moves fast)

- **Véra** covers `KT5, PW5, KT6, PW6, CS, KS, KS2` on firmware **≤ 5.19.6**.
- **KUAL is dead on firmware ≥ 5.19.4** → use **KPM**. On 5.19.2 KUAL still works.
- **11th gen uses MTP**, not USB mass storage → the "fill the storage to block OTA" trick does
  not apply, and the old dual-write corruption scenario is largely gone (only one FAT driver).
- Avoid "Toggle USBNet" on newer firmware — it can trap the UI on a gadget page. Use USBNetLite.
- Verified kernel on the development PW5: `4.9.77-lab126` (FW 5.19.2). Kernel ≥ 3.17 means
  `memfd_create` and seccomp-bpf exist, which is what modern Chromium needs — the reason
  Chromium is viable here but was doubtful on a PW3-era 3.0.x kernel.
