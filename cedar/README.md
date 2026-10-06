# Allwinner Cedar hardware H.264 decoder for FFmpeg / mpv

The A133P has a hardware video decoder ("Cedar" VE, `/dev/cedar_dev`). This folder adds it to the
FFmpeg 6.1 build as the decoder `h264_cedar`, which mpv uses through `vd=h264_cedar,` in `mpv.conf`
(the trailing comma lets mpv fall back to the software decoders for everything else).

## Files

| File | Purpose |
|---|---|
| `cedardec.c` | The FFmpeg decoder (`libavcodec/cedardec.c`), a wrapper around libcedarc's `libvdecoder`. |
| `apply.sh` | Adds it to an FFmpeg 6.1 source tree: `configure` (`--enable-cedar`), `libavcodec/Makefile`, `allcodecs.c`. |
| `fix-fini.py` | Disables the broken finalizers of libcedarc libraries converted from Android (see below). |

The Dockerfile (step 7b) builds libcedarc and installs it into `$PREFIX`; step 8 applies the patch and
configures FFmpeg with `--enable-cedar`; `build.sh` copies the eight libraries to `dist/lib/`.

## libcedarc

[CalvinXu17/libcedarc](https://github.com/CalvinXu17/libcedarc) (commit `e68d4a7`) is libcedarc for the
A133 with glibc. The decoder framework (`libvdecoder`, `libMemAdapter`, `libcdc_base`) is built from source,
so its headers match the library exactly. `libVE` (access to the VE, converted from Allwinner's Android build
because Allwinner's Linux one doesn't support the A133), `libvideoengine`, `libcwrapper`, `liblogwrapper`
and the H.264 plugin `libawh264` are the repository's prebuilt binaries.

Not used: the device's own libcedarc (`/usr/lib`, used by TrimUI's media player). It is a newer, unpublished
version whose structures don't match any public header, and its frame parser discarded the stream.

## Details of the decoder

- **Codecs:** H.264 only. The repository's H.265 plugin doesn't register with this framework, nor does
  the device's (which needs its own `libsbm`/`libfbm`). The hardware has no VP9 (TrimUI's firmware has no
  plugin; the datasheet lists 720p30 only) and no AV1.
- **Profiles:** High 10, 4:2:2 and 4:4:4 (profile_idc > 100) are refused at init, so mpv falls back.
- **Output:** NV21 pictures in ION memory are copied into normal frames (cache flushed first). 1080p is
  decoded as 1920x1088 and cropped.
- **Row alignment:** `nAlignStride = 32` is required. The VE writes rows padded to 32 pixels (libcedarc is
  built with `GPU_ALIGN_STRIDE=32`), but with the default (0) the decoder reports a 16-aligned stride: widths
  whose padded size isn't a multiple of 32 (e.g. 360, 720: common portrait/Shorts sizes) came out with wrong
  colours or no pictures. Verified bit-exact afterwards for 360x640, 480x854, 608x1080, 720x1280,
  1080x1920 and 854x480.
- **Timestamps** are not given to the decoder: with them it drops frames it considers late and treats
  negative ones (MP4 edit-list pre-roll) as missing. Pictures come out in display order, so each gets the
  smallest pending input timestamp, with that packet's discard flag. Discarded pictures (edit-list pre-roll)
  are returned to the decoder without copying. At most 32 packets are in flight.
- **Only the H.264 plugin is shipped:** `AddVDPlugin()` loads every `libaw*.so` next to `libvideoengine.so`.

Verified on the device against FFmpeg's software decoder: every picture and timestamp identical
(`-pix_fmt yuv420p -f framemd5`), including a clip cut with an edit list (236 pre-roll frames).

## The exit crash (`fix-fini.py`)

`libVE.so` (and `libawavs2.so`, `libawvp9HwAL.so`, not shipped) were converted from Android's packed
relocation format, and the conversion lost the relocations of their `.fini_array` entries: at exit the
loader calls raw offsets (`0x6000`, `0x6010`) and every program that loaded `libVE.so` segfaults when it
ends, even if it never used the decoder. The entries are compiler cleanup stubs; `fix-fini.py` sets
`DT_FINI_ARRAYSZ` to 0 in libraries whose `.fini_array` entries have no relocation.

## Measurements (mpv on screen, 20 s clips, whole system, 4 cores)

| H.264 | software | h264_cedar |
|---|---|---|
| 720p30 | 34% CPU | 14% CPU |
| 720p60 | 69% CPU, 44 frames dropped | 28% CPU, 10 dropped |
| 1080p30 | 65% CPU, 4 dropped | 19% CPU, none dropped |
| 1080p60 | 95% CPU, 988 of 1192 dropped | 29% CPU, 309 dropped |

Decode-only: 720p60 at 223 fps, 1080p60 at 105 fps, 2-3% of one core in real time. The remaining drops at
1080p60 come from copying frames and uploading them as textures; handing the decoder's buffers to the GPU
as DMA-bufs (zero-copy) would remove that.
