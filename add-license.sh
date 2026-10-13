#!/bin/sh
# Keep a component's license files before its source tree is deleted: build.sh collects
# $PREFIX/share/licenses/* into dist/licenses/third-party.txt.
# Usage: add-license.sh <id> <name and version> <license> <source URL> [license file]...
set -e
dir=$PREFIX/share/licenses/$1
mkdir -p "$dir"
printf '%s\nLicense: %s\nSource: %s\n' "$2" "$3" "$4" > "$dir/ABOUT"
shift 4
for f in "$@"; do cp "$f" "$dir/"; done
