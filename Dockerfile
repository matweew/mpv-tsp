FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    wget tar make xz-utils \
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
    pkg-config zlib1g-dev \
    python3 python3-pip cmake ninja-build \
    git nasm autoconf automake libtool \
    texinfo gettext autopoint \
    fonts-dejavu-core \
    && pip3 install meson==1.3.0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /sdk

# Download and extract SDK usr (sysroot)
RUN wget -q https://github.com/trimui/toolchain_sdk_smartpro/releases/download/20231018/SDK_usr_tg5040_a133p.tgz && \
    tar -xzf SDK_usr_tg5040_a133p.tgz -C /sdk && \
    rm SDK_usr_tg5040_a133p.tgz

# Download and extract specialized SDL2
RUN wget -q https://github.com/trimui/toolchain_sdk_smartpro/releases/download/20231018/SDL2-2.26.1.GE8300.tgz && \
    tar -xzf SDL2-2.26.1.GE8300.tgz -C /sdk && \
    rm SDL2-2.26.1.GE8300.tgz

ENV SYSROOT="/sdk/usr"
ENV SDL_DIR="/sdk/SDL2-2.26.1"
ENV PREFIX="/sdk/prefix"

# Remove glibc libraries (both shared and static) from sysroot to avoid conflicts with toolchain glibc
RUN rm -f $SYSROOT/lib/libc.* $SYSROOT/lib/libpthread.* $SYSROOT/lib/libm.* $SYSROOT/lib/libdl.* $SYSROOT/lib/librt.* $SYSROOT/lib/libutil.* $SYSROOT/lib/libcrypt.* $SYSROOT/lib/libresolv.*

RUN mkdir -p $PREFIX/lib/pkgconfig $PREFIX/include $PREFIX/bin $PREFIX/share/pkgconfig

# Install pkg-config wrapper and cross files
COPY pkg-config-wrapper.sh /usr/local/bin/aarch64-linux-gnu-pkg-config
RUN chmod +x /usr/local/bin/aarch64-linux-gnu-pkg-config
COPY cross.ini /sdk/cross.ini
COPY toolchain.cmake /sdk/toolchain.cmake
COPY toolchain_sdl2.cmake /sdk/toolchain_sdl2.cmake

# Install missing .pc files for PowerVR EGL/GLES
COPY pkgconfig/egl.pc $SYSROOT/lib/pkgconfig/egl.pc
COPY pkgconfig/glesv2.pc $SYSROOT/lib/pkgconfig/glesv2.pc

WORKDIR /build

# ===== 1. freetype (font rendering for libass) =====
RUN git clone --depth 1 --branch VER-2-13-2 https://github.com/freetype/freetype.git freetype-2.13.2 && \
    cmake -S freetype-2.13.2 -B freetype-2.13.2/build \
        -DCMAKE_TOOLCHAIN_FILE=/sdk/toolchain.cmake \
        -DCMAKE_INSTALL_PREFIX=$PREFIX \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DFT_DISABLE_BZIP2=ON \
        -DFT_DISABLE_PNG=ON \
        -DFT_DISABLE_HARFBUZZ=ON \
        -DFT_DISABLE_BROTLI=ON && \
    cmake --build freetype-2.13.2/build -j$(nproc) && \
    cmake --install freetype-2.13.2/build --prefix $PREFIX && \
    rm -rf freetype-2.13.2*

# ===== 2. fribidi (bidirectional text for libass) =====
RUN wget -q https://github.com/fribidi/fribidi/releases/download/v1.0.13/fribidi-1.0.13.tar.xz && \
    tar xf fribidi-1.0.13.tar.xz && cd fribidi-1.0.13 && \
    meson setup builddir --cross-file /sdk/cross.ini --prefix=$PREFIX --libdir=lib --buildtype=release \
        -Ddocs=false -Dbin=false -Dtests=false && \
    meson compile -C builddir -j$(nproc) && \
    meson install -C builddir && \
    cd /build && rm -rf fribidi-1.0.13*

# ===== 3. harfbuzz (text shaping for libass) =====
RUN wget -q https://github.com/harfbuzz/harfbuzz/releases/download/8.3.0/harfbuzz-8.3.0.tar.xz && \
    tar xf harfbuzz-8.3.0.tar.xz && cd harfbuzz-8.3.0 && \
    meson setup builddir --cross-file /sdk/cross.ini --prefix=$PREFIX --libdir=lib --buildtype=release \
        -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
        -Dicu=disabled -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled -Dbenchmark=disabled && \
    meson compile -C builddir -j$(nproc) && \
    meson install -C builddir && \
    cd /build && rm -rf harfbuzz-8.3.0*

# ===== 4. libass (subtitle/OSD rendering, with fontconfig) =====
COPY syslibs/libfontconfig.so.1 $PREFIX/lib/libfontconfig.so.1
COPY syslibs/libexpat.so.1 $PREFIX/lib/libexpat.so.1
RUN ln -sf libfontconfig.so.1 $PREFIX/lib/libfontconfig.so && \
    ln -sf libexpat.so.1 $PREFIX/lib/libexpat.so

# Fontconfig headers
RUN mkdir -p $PREFIX/include/fontconfig && \
    for hdr in fontconfig.h fcfreetype.h fcprivate.h; do \
        wget -q "https://gitlab.freedesktop.org/fontconfig/fontconfig/-/raw/2.13.1/fontconfig/$hdr" \
             -O $PREFIX/include/fontconfig/$hdr; \
    done && \
    printf 'prefix=%s\nexec_prefix=${prefix}\nlibdir=${exec_prefix}/lib\nincludedir=${prefix}/include\nName: Fontconfig\nDescription: Font configuration\nVersion: 2.13.1\nLibs: -L${libdir} -lfontconfig\nCflags: -I${includedir}\n' "$PREFIX" \
        > $PREFIX/lib/pkgconfig/fontconfig.pc

# Expat header
RUN wget -q "https://github.com/libexpat/libexpat/raw/R_2_5_0/expat/lib/expat.h" \
         -O $PREFIX/include/expat.h && \
    wget -q "https://github.com/libexpat/libexpat/raw/R_2_5_0/expat/lib/expat_external.h" \
         -O $PREFIX/include/expat_external.h

RUN git clone --depth 1 --branch 0.17.1 https://github.com/libass/libass.git && \
    cd libass && \
    ./autogen.sh && \
    PKG_CONFIG=/usr/local/bin/aarch64-linux-gnu-pkg-config \
    ./configure \
        --prefix=$PREFIX \
        --libdir=$PREFIX/lib \
        --host=aarch64-linux-gnu \
        --enable-shared \
        --disable-static \
        --disable-asm \
        CC=aarch64-linux-gnu-gcc \
        CFLAGS="-I$PREFIX/include -I$PREFIX/include/freetype2 -I$SYSROOT/include -O2" \
        LDFLAGS="-L$PREFIX/lib -L$SYSROOT/lib" \
        FONTCONFIG_CFLAGS="-I$PREFIX/include" \
        FONTCONFIG_LIBS="-L$PREFIX/lib -lfontconfig" && \
    make -j$(nproc) && \
    make install && \
    cd /build && rm -rf libass


# ===== 5. dav1d (fast AV1 software decoder) =====
RUN git clone --depth 1 --branch 1.3.0 https://github.com/videolan/dav1d.git && \
    cd dav1d && \
    meson setup builddir --cross-file /sdk/cross.ini --prefix=$PREFIX --libdir=lib --buildtype=release \
        -Denable_tools=false \
        -Denable_tests=false \
        -Denable_docs=false \
        -Denable_examples=false && \
    meson compile -C builddir -j$(nproc) && \
    meson install -C builddir && \
    cd /build && rm -rf dav1d

# ===== 6. libxml2 (required for DASH) =====
RUN wget -q https://download.gnome.org/sources/libxml2/2.10/libxml2-2.10.3.tar.xz && \
    tar xf libxml2-2.10.3.tar.xz && cd libxml2-2.10.3 && \
    PKG_CONFIG=/usr/local/bin/aarch64-linux-gnu-pkg-config \
    ./configure \
        --prefix=$PREFIX \
        --libdir=$PREFIX/lib \
        --host=aarch64-linux-gnu \
        --with-python=no \
        --with-zlib=yes \
        --with-lzma=no \
        --enable-shared \
        --disable-static \
        CC=aarch64-linux-gnu-gcc \
        CFLAGS="-I$PREFIX/include -I$SYSROOT/include -O2" \
        LDFLAGS="-L$PREFIX/lib -L$SYSROOT/lib -Wl,-rpath-link,$SYSROOT/lib" \
        LIBS="-lz" && \
    make -j$(nproc) && \
    make install && \
    cd /build && rm -rf libxml2-2.10.3*

# ===== 7. OpenSSL 3.5 LTS (HTTPS streams in FFmpeg) =====
# OpenSSL 3 is Apache-2.0 licensed: usable with the LGPL FFmpeg below (1.1.1 is end-of-life, and
# its license would have required FFmpeg's "nonfree", i.e. unredistributable, configuration).
RUN wget -q https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz && \
    tar xf openssl-3.5.9.tar.gz && cd openssl-3.5.9 && \
    ./Configure linux-aarch64 --prefix=$PREFIX --libdir=lib --cross-compile-prefix=aarch64-linux-gnu- \
        no-tests no-docs shared && \
    make -j$(nproc) && \
    make install_sw && \
    cd /build && rm -rf openssl-3.5.9*

# ===== 7b. libcedarc: Allwinner Cedar hardware video decoder (H.264) =====
# CalvinXu17/libcedarc is libcedarc for the A133 with glibc: the decoder framework is built
# from source (its headers then match exactly); libVE (VE access, converted from Android for
# the A133), libvideoengine and the H.264 plugin are its prebuilt binaries. Only the H.264
# plugin is installed: the decoder loads every plugin it finds next to libvideoengine.so.
# fix-fini.py disables the broken finalizers of the Android-converted libVE.so, which
# otherwise crash every program using it at exit.
COPY cedar /sdk/cedar
RUN git clone https://github.com/CalvinXu17/libcedarc.git && cd libcedarc && \
    git checkout e68d4a7 && \
    ./bootstrap && \
    CC=aarch64-linux-gnu-gcc CXX=aarch64-linux-gnu-g++ ./configure \
        --prefix=/build/cedarc-out --host=aarch64-linux-gnu \
        CFLAGS="-O2 -Wno-error -DCONF_KERNEL_VERSION_4_9 -DCONF_IMG_GPU_USE_COMMON_STRUCT \
                -DCONF_USE_IOMMU -DCONF_KERN_BITWIDE=64 -DCONFIG_VE_IPC_ENABLE -DGPU_ALIGN_STRIDE=32 \
                -DCONF_VE_FREQ_ENABLE_SETUP -DCONF_CERES_VE_FREQ_ENABLE_SETUP -DCONF_PIE_AND_NEWER \
                -DCONF_ARMV7_A_NEON" \
        CXXFLAGS="-O2 -Wno-error" \
        LDFLAGS="-L/build/libcedarc/library/aarch64-linux-gnu" && \
    make -j$(nproc) && make install && \
    cp /build/cedarc-out/lib/libvdecoder.so /build/cedarc-out/lib/libMemAdapter.so \
       /build/cedarc-out/lib/libcdc_base.so $PREFIX/lib/ && \
    cd library/aarch64-linux-gnu && \
    cp libVE.so libvideoengine.so libcwrapper.so liblogwrapper.so libawh264.so $PREFIX/lib/ && \
    python3 /sdk/cedar/fix-fini.py $PREFIX/lib/libVE.so && \
    mkdir -p $PREFIX/include/cedarc && cp /build/libcedarc/include/*.h $PREFIX/include/cedarc/ && \
    cd /build && rm -rf libcedarc cedarc-out

# ===== 8. FFmpeg 6.1 (with dav1d AV1 decoder, OpenSSL, libxml2, Cedar H.264 decoder) =====
# LGPL build (no --enable-gpl / --enable-nonfree): it may then link the proprietary libcedarc
# libraries, and the result can be redistributed. mpv doesn't need FFmpeg's GPL-only parts.
RUN wget -q https://ffmpeg.org/releases/ffmpeg-6.1.tar.xz && \
    tar xf ffmpeg-6.1.tar.xz && /sdk/cedar/apply.sh ffmpeg-6.1 && cd ffmpeg-6.1 && \
    PKG_CONFIG=/usr/local/bin/aarch64-linux-gnu-pkg-config \
    ./configure \
        --prefix=$PREFIX \
        --enable-cross-compile \
        --cross-prefix=aarch64-linux-gnu- \
        --target-os=linux \
        --arch=aarch64 \
        --extra-cflags="-I$PREFIX/include -I$PREFIX/include/cedarc -I$SYSROOT/include -O2" \
        --extra-ldflags="-L$PREFIX/lib -L$SYSROOT/lib -Wl,-rpath-link,$PREFIX/lib -Wl,-rpath-link,$SYSROOT/lib" \
        --pkg-config=/usr/local/bin/aarch64-linux-gnu-pkg-config \
        --enable-shared \
        --disable-static \
        --disable-debug \
        --disable-doc \
        --enable-libdav1d \
        --enable-openssl \
        --enable-libxml2 \
        --enable-zlib \
        --enable-cedar && \
    make -j$(nproc) && \
    make install && \
    cd /build && rm -rf ffmpeg-6.1*

# ===== 9. SDL2 from GE8300 source (PowerVR-compatible) =====
RUN cmake -S /sdk/SDL2-2.26.1 -B /build/sdl2-build \
        -DCMAKE_TOOLCHAIN_FILE=/sdk/toolchain_sdl2.cmake \
        -DCMAKE_INSTALL_PREFIX=$PREFIX \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DSDL_SHARED=ON \
        -DSDL_STATIC=OFF \
        -DSDL_VIDEO=ON \
        -DSDL_AUDIO=ON \
        -DSDL_MALI=ON \
        -DHAVE_MALI_EGL_FB=ON \
        -DSDL_OPENGL=OFF \
        -DSDL_OPENGLES=ON \
        -DSDL_RENDER=OFF \
        -DSDL_JOYSTICK=ON \
        -DSDL_HAPTIC=OFF \
        -DSDL_POWER=OFF \
        -DSDL_FILESYSTEM=OFF \
        -DSDL_SENSOR=OFF \
        -DSDL_LOADSO=ON \
        -DSDL_DLOPEN=ON \
        -DSDL_THREADS=ON \
        -DSDL_TIMERS=ON \
        -DSDL_X11=OFF \
        -DSDL_WAYLAND=OFF \
        -DSDL_KMSDRM=OFF \
        -DSDL_OFFSCREEN=OFF \
        -DSDL_DBUS=OFF \
        -DSDL_IBUS=OFF \
        -DSDL_PULSEAUDIO=OFF \
        -DSDL_JACK=OFF \
        -DSDL_ESD=OFF \
        -DSDL_ARTS=OFF \
        -DSDL_NAS=OFF \
        -DSDL_SNDIO=OFF \
        -DSDL_FUSIONSOUND=OFF \
        -DSDL_DISKAUDIO=OFF \
        -DSDL_DUMMYAUDIO=ON \
        -DSDL_ALSA=ON \
        -DALSA_SHARED=ON \
        -DSDL_OSS=OFF \
        -DSDL_DIRECTFB=OFF \
        -DSDL_RPI=OFF \
        -DSDL_VIVANTE=OFF && \
    cmake --build /build/sdl2-build -j$(nproc) && \
    cmake --install /build/sdl2-build --prefix $PREFIX && \
    rm -rf /build/sdl2-build

# ===== 10. mpv 0.36.0 (SDL2 gpu context + GLES) =====
# LGPL build (-Dgpl=false): the features it disables (X11, OSS, JACK, DVD, CDDA, DVB, caca) are
# disabled here anyway.
COPY context_sdl.c /build/context_sdl.c
COPY patch_mpv.py /build/patch_mpv.py

RUN git clone --depth 1 --branch v0.36.0 https://github.com/mpv-player/mpv.git

RUN cp /build/context_sdl.c mpv/video/out/opengl/context_sdl.c && \
    python3 /build/patch_mpv.py && \
    cd mpv && \
    PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:$SDL_DIR/lib/pkgconfig:$SYSROOT/lib/pkgconfig" \
    meson setup builddir --cross-file /sdk/cross.ini --prefix=$PREFIX --libdir=lib --buildtype=release \
        -Dcplayer=true \
        -Dlibmpv=false \
        -Dtests=false \
        -Dgpl=false \
        -Dsdl2=enabled \
        -Dsdl2-video=enabled \
        -Dsdl2-audio=enabled \
        -Dsdl2-gamepad=enabled \
        -Dgl=enabled \
        -Degl=enabled \
        -Dvulkan=disabled \
        -Ddrm=disabled \
        -Degl-drm=disabled \
        -Dgbm=disabled \
        -Dx11=disabled \
        -Dxv=disabled \
        -Dgl-x11=disabled \
        -Degl-x11=disabled \
        -Dwayland=disabled \
        -Degl-wayland=disabled \
        -Dvdpau=disabled \
        -Dvaapi=disabled \
        -Dcaca=disabled \
        -Dsixel=disabled \
        -Dd3d11=disabled \
        -Ddirect3d=disabled \
        -Dcocoa=disabled \
        -Dalsa=disabled \
        -Dpulse=disabled \
        -Dpipewire=disabled \
        -Djack=disabled \
        -Dopenal=disabled \
        -Dsndio=disabled \
        -Doss-audio=disabled \
        -Dlua=auto \
        -Djavascript=disabled \
        -Dlibarchive=disabled \
        -Dlibbluray=disabled \
        -Ddvdnav=disabled \
        -Ddvbin=disabled \
        -Dcdda=disabled \
        -Duchardet=disabled \
        -Drubberband=disabled \
        -Dvapoursynth=disabled \
        -Dzimg=disabled \
        -Dlcms2=disabled \
        -Djpeg=disabled \
        -Dmanpage-build=disabled && \
    meson compile -C builddir -j$(nproc) && \
    meson install -C builddir

WORKDIR /app
