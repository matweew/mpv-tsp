#!/bin/sh
DIR="$(dirname "$(readlink -f "$0")")"

# Generate a minimal fonts.conf pointing fontconfig at our bundled fonts.
# This is regenerated each launch so the path is always correct.
cat > "$DIR/fonts.conf" << EOF
<?xml version="1.0"?>
<fontconfig>
  <dir>$DIR/fonts</dir>
  <cachedir>/tmp/mpv-fc-cache</cachedir>
</fontconfig>
EOF

export FONTCONFIG_FILE="$DIR/fonts.conf"
export LD_LIBRARY_PATH="$DIR/lib:/usr/trimui/lib:/usr/lib64:/usr/lib:$LD_LIBRARY_PATH"
[ -f "$DIR/ca-certificates.crt" ] && export SSL_CERT_FILE="$DIR/ca-certificates.crt"
exec "$DIR/mpv" --config-dir="$DIR" --sub-fonts-dir="$DIR/fonts" "$@"
