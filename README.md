# raptor-xm550

[Raptor](https://github.com/johnchia/raptor) on the **Xiongmai IVG-83X50PSA-B**
camera module (Xiongmai **XM550** + SmartSens **SC5332**, 5 MP), built into an
[OpenIPC](https://openipc.org) firmware image.

Raptor had no Xiongmai support, and these modules shipped with vendor firmware
that made them hard to use. This brings Raptor up through a new HAL backend,
`src/xiongmai`, on [openxiongmai](https://github.com/OpenIPC/openxiongmai)'s
open libraries and drivers, and packages the result so a module boots
straight into it. The video path runs no vendor code: the ISP, its 3A, the
MPI and the H.264/JPEG encoder are all open (the encoder's kernel module,
`xm530_h264.ko`, is the one vendor part left).

| | Branch |
|---|---|
| Xiongmai HAL backend | [BlackStump/raptor-hal](https://github.com/BlackStump/raptor-hal/tree/xiongmai) `xiongmai` |
| Raptor (build integration) | [BlackStump/raptor](https://github.com/BlackStump/raptor/tree/xiongmai) `xiongmai` |
| openxiongmai (libxmhost, libxmvenc VUI, ISP queries, SC5332 fixes) | [BlackStump/openxiongmai](https://github.com/BlackStump/openxiongmai/tree/p2a) `p2a` |
| XM550 packaging (this repo) | `xm550pkg/` |

## What works

- **Video:** SC5332 at 15 fps through openxiongmai's open ISP, with its open
  AE and AWB (on by default).
- **Two streams over RTSP:** main 2576x1936 H.264 Main (CABAC) at 4 Mbit/s,
  sub 640x480 H.264 Constrained Baseline at 512 kbit/s, both at exactly 15
  fps with nothing dropped. The SPS carries a VUI: full range, the real frame
  rate, no reordering (ffprobe over RTSP: `r_frame_rate=15/1`,
  `color_range=pc`).
- **Snapshots and MJPEG** from both streams, without costing either stream a
  frame.
- **Day/night:** exposure x gain trigger, the IR-cut filter pulsed from the
  SoC, black-and-white at night.
- **OSD:** timestamp and uptime with an outline, on both streams, drawn by
  VI's own region hardware.
- **Anti-flicker** (50/60 Hz), **mirror and flip** (by the sensor).
- **Web console** on port 8080 (rhd + rcd); stream credentials are left
  empty in the image, to be set there (or not).
- **Boots unattended** from the image into all daemons.

Not yet: H.265 (the chip's
Mali-V550; libxmvenc has it, the backend does not use it yet), audio.

## Hardware notes (IVG-83X50PSA-B)

| Function | Pin / setting |
|---|---|
| IR-cut filter out (night) | GPIO1, pulse 200 ms |
| IR-cut filter in (day) | GPIO2, pulse 200 ms |
| IR LEDs | the LED board's own photosensor; not the SoC's |
| Sensor | SC5332 on I2C 0x60, chip ID 0xce1a, MIPI |
| Flash | 8 MB NOR |

The LED board switches only the IR LEDs. Nothing moves the IR-cut unless the
SoC pulses it: with neither pin pulsed, the filter stays in and night is
black. ric drives both pins (`gpio_ircut = 2`, `gpio_ircut2 = 1`).

Memory: `osmem=72M` (U-Boot), which `load_xiongmai` turns into 56 MB of MMZ
from 0x84800000; VI keeps three buffers a way (`VI_BUFF=3,3`). The image
sets `VI_BUFF`; `osmem` lives in U-Boot's environment, so `S95xm550` sets it
on the first boot after flashing and restarts the camera once.

## Findings worth knowing

These came out of the port and apply to any XM530/XM550 software:

- **The SC5332's clean picture is 2576x1936,** not 2592x1944: outside
  columns 4-2592 and rows 0-1944 of the 2600x1952 frame the ISP's edge
  filtering leaves junk (a bright halo, a white row, pink columns). VI channel
  0 has no scaler, so the main stream is that window at its own size; the sub
  stream is extended channel 1, which the kernel scales.
- **VI hands each frame to one reader.** Two encoders on one VI channel (a
  stream and its snapshots) split its frames between them. The backend feeds
  each VI channel from one thread to every encoder bound there.
- **VI's buffers set what a snapshot costs.** openxiongmai's open VI gives
  each way 2 buffers by default; while a snapshot holds one and the stream's
  encode another, VI has nowhere to capture the next frame and skips it
  silently (its `RecvCnt` falls behind, `Dropped` stays 0). Three a way, with
  the MMZ to hold them, costs nothing.
- **Encoder budget at 5 MP/15 fps:** main H.264 takes 44 ms of the 67 a frame
  has, sub 2.4 ms, a 5 MP JPEG 35 ms. A snapshot runs on its own thread so it
  never stands between the stream and its next frame.
- **Setting VI channel 0's attributes takes about 3 s;** the backend sets
  them only when they change. rvd needs about 8 s to its first ring, so the
  packaged init script waits 20 s, not Raptor's 5.
- **The OSD is VI's:** up to 8 overlays a channel of 1 or 2 bits a pixel in
  8 KiB of bitmap memory. Text is packed to 2 bits (text and outline); when
  memory runs short the largest overlays fall back to 1 bit.
- **libmpi's region calls are unfinished,** so the backend speaks
  openxiongmai's `open_rgn` driver directly.
- **OpenIPC builds this tree with per-package directories:** every `make`
  rebuilds the target from each package's files, so a file replaced in
  `output/target` is put back. The packaging goes through
  `BR2_ROOTFS_OVERLAY`, which Buildroot applies after the packages.

## Building

Needs an OpenIPC tree built for `xm530_lite` (the XM550 uses the xm530
family's build), the Raptor repos side by side, compy built with mbedTLS by
the same compiler, and openxiongmai:

```
Cams/
  openipc-firmware/firmware-xm550/output/  OpenIPC Buildroot output (xm530_lite)
  openxiongmai/libraries                   BlackStump/openxiongmai, branch p2a
  XM550/raptor/raptor                      BlackStump/raptor,     branch xiongmai
  XM550/raptor/raptor-hal                  BlackStump/raptor-hal, branch xiongmai
  XM550/raptor/raptor-common               johnchia/raptor-common @ 2a2fc69
  XM550/raptor/raptor-ipc                  johnchia/raptor-ipc    @ a8cd4ca
  XM550/raptor/compy                       compy (built by the script)
  XM550/raptor-xm550/                      this repo
```

The firmware tree, once:

```
git worktree add -b xm550 ../firmware-xm550 origin/master   # in openipc-firmware/firmware
cd ../firmware-xm550 && make BOARD=xm530_lite
```

Then:

```
cd XM550/raptor-xm550
sh xm550pkg/mkxm550.sh overlay   # build the daemons, assemble the overlay tree
sh xm550pkg/mkxm550.sh image     # ...and put it into the image: Majestic
                                 # deselected, overlay via BR2_ROOTFS_OVERLAY,
                                 # images rebuilt and checked file by file
```

`mkxm550.sh` builds libschrift (for the OSD, from `xm550pkg/src/libschrift`)
and compy with the firmware tree's own compiler, so nothing comes from a
different toolchain. The checked images land in `XM550/images/` as
`raptor-xm550-uImage` and `raptor-xm550-rootfs.squashfs`, with their md5s.
Edit the paths at the top of `mkxm550.sh` to match your tree.

## Flashing

From the camera, with the two images copied to `/tmp`:

```
sysupgrade --kernel=/tmp/raptor-xm550-uImage --rootfs=/tmp/raptor-xm550-rootfs.squashfs -f
```

`-f` is needed: local builds share one version name. The modules keep the
OpenIPC U-Boot they already run.

Before flashing a module that has been worked on by hand, list its overlay:
on this image the overlay's upper directory is `/overlay` itself
(`find /overlay -xdev -type f`). Files there hide the image's copies; a
sensor library left from Majestic-era fixes, for one, predates the open AE
and leaves the picture dark (`get-exposure` all zeros). Remove old ones from
`/overlay/...`, never from `/etc` or `/usr` directly. `S95xm550` logs any
library or program in the overlay that shadows the image at every boot. To
go back to the image's `raptor.conf`, `rm /overlay/etc/raptor.conf`.

## ONVIF

On by default, so NVRs can find the
camera with auto search (WS-Discovery) or add it by IP on port 80.

It is OpenIPC's `onvif-simple-server` package: `onvif_simple_server` as CGI
under a busybox httpd of its own, serving only `/onvif/`, and
`wsd_simple_server` for discovery. `onvif-conf` writes its config from
`raptor.conf` on every change: the two streams (`rtsp://<ip>/stream0`,
`/stream1`), snapshots from rhd (`:8080/snap.jpg`), and the stream account
from `[rtsp]` as the ONVIF login. While that account is unset, ONVIF is as
open as the streams. The stream URIs carry no credentials.

The stock firmware's ONVIF (inside `Sofia`, gSOAP) also offered motion
events and encoder changes; this covers what an NVR needs to record:
discovery, device information, profiles, stream and snapshot URIs.

## Motion events

On by default. The XM550 has no motion engine Raptor can use, so `rvd`
compares the sub-stream's frames itself (`algorithm = soft`, chosen
automatically here) and `rmd` keeps `/tmp/onvif_notify_server/motion_alarm`
while there is motion. With ONVIF on, `onvif_notify_server` turns that file
into ONVIF motion events, as the stock PB4 sends them
(`RuleEngine/CellMotionDetector/Motion`, `IsMotion`), so the NVR and its app
can alert on them.

To turn it off: `[motion] enabled = false` in `/etc/raptor.conf`, then
`/etc/init.d/S96raptor restart` and `/etc/init.d/S96onvifserver restart`.
`sensitivity` (0-4, default 2) and `cooldown_sec` (default 10) are in the
same section. Whole-scene changes (the IR-cut switching, a light) are
ignored rather than reported.

## In a PB4 housing (IR and white LEDs)

The PB4 housing's LED board has no light sensor wire the XM550 reads, and
its lamps switch on a plain level. Wiring (2026-11-17):

| LED board wire | XM550             | GPIO | on   |
|----------------|-------------------|------|------|
| IR             | J7 IR_CTRL        | 41   | high |
| white          | J4 pin 3 (PWM)    | 39   | high |

Both pins float high until driven, which the board takes as on.

    housing pb4       # this module is in a PB4 housing
    housing ceiling   # back to the ceiling housing (ADC light sensor)

`housing pb4` sets ric to switch by sensor gain with the IR on GPIO 41,
writes `/etc/lamp.conf` (so S95xm550 switches both lamps off at boot) and
`/etc/wlight.conf` (so S97wlight starts the motion white light), then
restarts Raptor. `lamp white|ir <0-100>`, `lamp off` and `lamp status`
drive the lamps by hand. White is on/off for now; GPIO 39 has a PWM mode
in the stock firmware, so dimming can come later.

## Files

- `xm550pkg/overlay/etc/raptor.conf` - XM550 config: streams, OSD, IR-cut
  pins, gain thresholds, 50 Hz.
- `xm550pkg/overlay/etc/init.d/S96onvifserver`, `usr/sbin/onvif-conf`,
  `usr/sbin/onvif-cgi`, `usr/share/onvif-www/` - ONVIF, see above.
- `xm550pkg/overlay/etc/init.d/S95xm550` - osmem on first boot, the X50
  sensor library link, a warning for anything in the overlay that shadows
  the image.
- `xm550pkg/overlay/etc/TZ`, `etc/timezone` - Australia/Melbourne.
- `xm550pkg/overlay/usr/share/fonts/default.ttf` - DejaVu Sans Mono, for the
  OSD.
- `xm550pkg/src/libschrift/` - libschrift (ISC), built for rod.
- `xm550pkg/mkxm550.sh` - build and package.
- `tools/expolog.sh` - log what rvd reports for day/night, every 2 s.
- `tools/grab.sh` - pull both streams and snapshots out of rvd's rings and
  count frames (the snapshot-cost test).
- `tools/gpiowatch.c` - record every change in the GPIO registers (static,
  read-only), for finding pins.

## Credits

- **Raptor** and its HAL design: [johnchia](https://github.com/johnchia)'s
  Raptor fork (from [gtxaspec](https://github.com/gtxaspec)'s Raptor).
- **openxiongmai:** the open XM530/XM550 libraries and drivers this runs on
  ([OpenIPC/openxiongmai](https://github.com/OpenIPC/openxiongmai)).
- **libschrift:** [tomolt/libschrift](https://github.com/tomolt/libschrift).
- **DejaVu fonts:** [dejavu-fonts](https://dejavu-fonts.github.io/); licence
  in `xm550pkg/src/fonts/DejaVu-LICENSE`.
- **Bench work, testing and the modules:** BlackStump.
- Developed with Claude (Anthropic).
