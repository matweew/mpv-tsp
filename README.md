# mpv for TrimUI Smart Pro

A build of [mpv](https://mpv.io/) 0.36 for the **TrimUI Smart Pro** handheld (Allwinner A133P, PowerVR
GE8300, stock Tina Linux) with GPU video output and the SoC's **hardware H.264 decoder**.

## Why it exists

Stock mpv can't show anything on this device, and a plain cross-build plays video in software only:

- **No usable video output.** The screen is an fbdev framebuffer driven by TrimUI's own SDL2 build for the
  PowerVR GPU; there is no KMS/DRM, Wayland or X11. mpv 0.36 has no SDL2 OpenGL context, and
  `vo=gpu-next` (libplacebo's own EGL setup) fails on fbdev. This build adds an **SDL2 GPU context**
  (`context_sdl.c`) for `vo=gpu`, on SDL2 built from TrimUI's GE8300 source (`SDL2_POWERVR_GE8300`: EGL
  with a NULL native window, PowerVR's default framebuffer surface).
- **No hardware decoding.** The A133P's "Cedar" video engine isn't supported by FFmpeg. `cedar/` adds an
  FFmpeg decoder, `h264_cedar`, on top of Allwinner's libcedarc: H.264 at about a third of the CPU of
  software decoding (720p30: 14% instead of 34%; 1080p30 without dropped frames).
- **The device's libraries are old** (glibc 2.33). Everything is built against TrimUI's SDK sysroot, so
  the binaries run on stock firmware, and the libraries mpv needs are bundled next to it.

It's the video player of [WPE Browser for TrimUI Smart Pro](https://github.com/matweew/wpe-tsp), which plays
YouTube and page videos in it, and it works standalone as well.

**Included:** FFmpeg 6.1 (with `h264_cedar`, dav1d for AV1, libxml2 for DASH, OpenSSL 3.5 for HTTPS),
libass with freetype/harfbuzz/fribidi for subtitles and the OSD, SDL2 2.26 (GE8300) for video, audio and
the gamepad.

## Building

Needs Linux x86-64 with Docker; the first build takes a while (it builds every library from source).

```bash
./build.sh        # builds the Docker image mpv-trimui-builder, then collects dist/
```

`dist/` is then the complete player:

```
dist/
  mpv, launch.sh, mpv.conf       the player, its launcher and configuration
  lib/                           FFmpeg, libass, SDL2, OpenSSL, libcedarc, ... (real files named by
                                 SONAME: the SD card is exFAT, without symlinks)
  fonts/, ca-certificates.crt    DejaVu Sans for OSD/subtitles, CA certificates for HTTPS
```

## Running on the device

Copy `dist/` to the SD card, e.g. as `/mnt/SDCARD/Apps/mpv/`, and run `launch.sh` with a file or URL:

```bash
scp -r dist/* root@<device-ip>:/mnt/SDCARD/Apps/mpv/
ssh root@<device-ip> /mnt/SDCARD/Apps/mpv/launch.sh /mnt/SDCARD/Videos/clip.mp4
```

`launch.sh` sets the library path (`lib/`, then the device's SDL/EGL/GLES), fonts and certificates.
`mpv.conf` selects `vo=gpu`, `gpu-context=sdl`, the hardware decoder with software fallback
(`vd=h264_cedar,`), cheap scalers for the embedded GPU, and SDL audio. For YouTube, resolve the stream
URLs with [yt-dlp](https://github.com/yt-dlp/yt-dlp) and pass them to mpv (`--no-ytdl`; mpv's ytdl hook
isn't set up here); WPE Browser does that for you.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Cross-build environment (Ubuntu 20.04, aarch64 GCC) on TrimUI's SDK sysroot: freetype, fribidi, harfbuzz, libass, dav1d, libxml2, OpenSSL, libcedarc, FFmpeg, SDL2, mpv |
| `build.sh` | Builds the image and collects `dist/` |
| `context_sdl.c`, `patch_mpv.py` | The SDL2 GPU context, and the patch that registers it in mpv 0.36 |
| `cedar/` | The `h264_cedar` FFmpeg decoder and how it's built: see [cedar/README.md](cedar/README.md) |
| `cross.ini`, `toolchain*.cmake`, `pkg-config-wrapper.sh`, `pkgconfig/` | Meson/CMake/pkg-config cross setup; `.pc` files for the PowerVR EGL/GLES |
| `syslibs/` | fontconfig and expat from the device's firmware (libass uses them) |
| `launch.sh`, `mpv.conf` | Launcher and configuration copied into `dist/` |

## Known limitations

- Hardware decoding is H.264 only (up to High profile, 8-bit 4:2:0); everything else is decoded in
  software (dav1d for AV1).
- The OSC (on-screen controller) is off: its Lua code fails with the Lua 5.1 found on the device.
- Frames from the hardware decoder are copied before the GPU shows them; 1080p60 still drops frames.

## Licensing

- **The binaries are an LGPL build**: FFmpeg without `--enable-gpl`/`--enable-nonfree` (LGPL 2.1+) and mpv
  with `-Dgpl=false` (LGPL 2.1+). That lets them link the proprietary libcedarc libraries, and the result
  can be redistributed. The other components keep their licenses: OpenSSL (Apache 2.0), dav1d (BSD),
  libass (ISC), FreeType (FTL), HarfBuzz (MIT), FriBidi (LGPL), libxml2 (MIT), SDL2 (zlib), fontconfig
  and expat (MIT), DejaVu fonts.
- **libcedarc** is Allwinner's (copyright Allwinner Technology, without a published license). It comes
  from [CalvinXu17/libcedarc](https://github.com/CalvinXu17/libcedarc): its decoder framework is built
  from source, `libVE`, `libvideoengine`, `libcwrapper`, `liblogwrapper` and `libawh264` are prebuilt
  binaries from that repository. The same library is part of TrimUI's firmware.
- **This repository:** the build scripts are under the [MIT license](LICENSE); `cedar/cedardec.c` (part of
  FFmpeg) and `context_sdl.c` (part of mpv) are LGPL 2.1 or later, as stated in their headers.

Sources of everything built: the versions and URLs in the `Dockerfile` (FFmpeg 6.1, mpv v0.36.0, OpenSSL
3.5.9, libcedarc commit `e68d4a7`, ...), plus the changes in this repository.
