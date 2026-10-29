#!/usr/bin/env bash
# Build the checked-out FFmpeg/OpenSSL and ijkplayer with a modern Linux NDK.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
: "${ANDROID_NDK:?Set ANDROID_NDK to an installed Android NDK (r28 or newer)}"
TOOLCHAIN="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64"
export PATH="$TOOLCHAIN/bin:$PATH"
export ANDROID_NDK_ROOT="$ANDROID_NDK"
JOBS=${JOBS:-8}
API=${API:-21}
TARGET=${1:-all}
case "$TARGET" in
    all) TARGETS="arm64 x86_64" ;;
    arm64|x86_64) TARGETS="$TARGET" ;;
    *) echo "Usage: $0 [all|arm64|x86_64]" >&2; exit 1 ;;
esac
ALIGN="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"
for target in $TARGETS; do
    if [[ $target == arm64 ]]; then
        triple=aarch64-linux-android; arch=aarch64; abi=arm64-v8a; ssl_target=android-arm64
    else
        triple=x86_64-linux-android; arch=x86_64; abi=x86_64; ssl_target=android-x86_64
    fi
    cc="$TOOLCHAIN/bin/${triple}${API}-clang"
    build="$ROOT/android/build-16k/$target"
    ssl="$build/openssl/output"
    prefix="$ROOT/android/contrib/build/ffmpeg-$target/output"
    mkdir -p "$build/openssl" "$build/ffmpeg" "$prefix"
    (
        cd "$build/openssl"
        if [[ ! -f Makefile ]]; then
            CC="$cc" AR=llvm-ar RANLIB=llvm-ranlib \
                perl "$ROOT/android/contrib/openssl-$target/Configure" "$ssl_target" \
                -D__ANDROID_API__="$API" no-shared no-tests \
                --prefix="$ssl" --libdir=lib
        fi
        make -j"$JOBS" build_libs
        make install_dev
    )
    (
        cd "$build/ffmpeg"
        # Use the repository's codec/protocol selection, including HTTPS.
        source "$ROOT/config/module.sh"
        "$ROOT/android/contrib/ffmpeg-$target/configure" $COMMON_FF_CFG_FLAGS \
            --prefix="$prefix" --target-os=android --arch="$arch" \
            --enable-cross-compile --enable-pic --enable-static --disable-shared \
            --enable-openssl --enable-small --enable-jni --disable-vulkan \
            --cc="$cc" --cxx="$TOOLCHAIN/bin/${triple}${API}-clang++" \
            --ar=llvm-ar --ranlib=llvm-ranlib --nm=llvm-nm --strip=llvm-strip \
            --extra-cflags="-O3 -fstack-protector-strong -I$ssl/include -Wno-error=incompatible-function-pointer-types -Wno-error=int-conversion" \
            --extra-ldflags="-L$ssl/lib $ALIGN"
        make -j"$JOBS"
        make install
        mkdir -p "$prefix/include/libffmpeg"
        cp config.h "$prefix/include/libffmpeg/config.h"
        "$cc" -shared -o "$prefix/libijkffmpeg.so" \
            -Wl,-soname,libijkffmpeg.so -Wl,--no-undefined -Wl,-Bsymbolic $ALIGN \
            -Wl,--whole-archive "$prefix"/lib/libav{codec,filter,format,util}.a \
            "$prefix"/lib/libsw{resample,scale}.a -Wl,--no-whole-archive \
            "$ssl/lib/libssl.a" "$ssl/lib/libcrypto.a" -lm -lz -ldl -llog
    )
    jni="$ROOT/android/ijkplayer/ijkplayer-$target/src/main/jni"
    ln -sfn ../../../../../../ijkprof/android-ndk-profiler-dummy/jni "$jni/android-ndk-prof"
    "$ANDROID_NDK/ndk-build" -C "$jni" -j"$JOBS" \
        "APP_PLATFORM=android-$API" "APP_LDFLAGS=$ALIGN" \
        'APP_CFLAGS=-O3 -Wall -pipe -ffast-math -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -fstrict-aliasing -Werror=strict-aliasing -Wa,--noexecstack -DANDROID -DNDEBUG -Wno-error=incompatible-function-pointer-types -Wno-error=int-conversion'
    dest="$ROOT/android/build-16k/jniLibs/$abi"
    mkdir -p "$dest"
    cp "$jni/../libs/$abi/"*.so "$dest/"
done
python3 "$ROOT/android/check-16k.py" "$ROOT/android/build-16k/jniLibs"
