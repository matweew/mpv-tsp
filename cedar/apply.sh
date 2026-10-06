#!/bin/sh
# Add the Allwinner Cedar H.264 decoder (h264_cedar) to an FFmpeg 6.1 source tree.
# Usage: apply.sh <ffmpeg-source-dir>     then configure with --enable-cedar
set -e
SRC=$1
HERE=$(dirname "$0")
[ -f "$SRC/libavcodec/rkmppdec.c" ] || { echo "not an FFmpeg source tree: $SRC" >&2; exit 1; }
grep -q h264_cedar "$SRC/configure" && { echo "already applied"; exit 0; }

cp "$HERE/cedardec.c" "$SRC/libavcodec/cedardec.c"

# configure: the option, the library check and the decoder's dependencies
sed -i 's#^  --enable-rkmpp           enable Rockchip Media Process Platform code \[no\]#&\n  --enable-cedar           enable Allwinner Cedar (libcedarc) H.264 decoder [no]#' "$SRC/configure"
sed -i 's#^    \$HWACCEL_LIBRARY_NONFREE_LIST$#&\n    cedar#' "$SRC/configure"
sed -i 's#^h264_rkmpp_decoder_deps="rkmpp"#h264_cedar_decoder_deps="cedar"\nh264_cedar_decoder_select="h264_mp4toannexb_bsf"\n&#' "$SRC/configure"
sed -i 's#^enabled rkmpp             \&\& #enabled cedar             \&\& require cedar vdecoder.h CreateVideoDecoder -lvdecoder -lvideoengine -lMemAdapter -lcdc_base\n&#' "$SRC/configure"

# build and registration
sed -i 's#^OBJS-$(CONFIG_H264_RKMPP_DECODER)      += rkmppdec.o#OBJS-$(CONFIG_H264_CEDAR_DECODER)      += cedardec.o\n&#' "$SRC/libavcodec/Makefile"
sed -i 's#^extern const FFCodec ff_h264_rkmpp_decoder;#extern const FFCodec ff_h264_cedar_decoder;\n&#' "$SRC/libavcodec/allcodecs.c"

for f in configure libavcodec/Makefile libavcodec/allcodecs.c; do
    grep -q cedar "$SRC/$f" || { echo "patching $f failed" >&2; exit 1; }
done
echo "h264_cedar added to $SRC"
