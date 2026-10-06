#!/bin/sh
export PKG_CONFIG_DIR=
export PKG_CONFIG_SYSROOT_DIR=""
export PKG_CONFIG_LIBDIR="/sdk/prefix/lib/pkgconfig:/sdk/prefix/share/pkgconfig:/sdk/SDL2-2.26.1/lib/pkgconfig:/sdk/usr/lib/pkgconfig:/sdk/usr/share/pkgconfig"
exec pkg-config "$@"
