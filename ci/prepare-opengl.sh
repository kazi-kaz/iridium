#!/bin/bash
# Build desktop OpenGL for the winios WGL driver from pinned sources:
# MoltenVK (Vulkan on Metal) and Mesa's OSMesa with the Zink driver (OpenGL on
# Vulkan), staged at testrepos/Madeira/app/Madeira/gl/. Without them the driver
# offers only Apple's OpenGL ES 3.0, which desktop-GL games reject.
# The build recipes are testrepos/Madeira/build/{moltenvk-ios,mesa-ios}/build.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/testrepos/Madeira"
SOURCES="$ROOT/.build/runtime-sources"
VENV="$ROOT/.build/mesa-venv"
OUT="$M/app/Madeira/gl"
MESA_VERSION=25.0.7
MESA_SHA256=592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6
MOLTENVK_REV=db66022459ffb663aa2b50f6b018bc2e124f5edf   # tag v1.4.2
MESA="$SOURCES/mesa-$MESA_VERSION"
MVK="$SOURCES/MoltenVK"
[ "$#" = 0 ] || { echo 'Usage: prepare-opengl.sh' >&2; exit 2; }
# Fail instead of replacing a developer's existing checkout or build.
for target in "$MESA" "$MVK" "$VENV" "$OUT" "$M/build/mesa-ios/obj"; do
    [ ! -e "$target" ] || { echo "Existing OpenGL build input or output: $target" >&2; exit 1; }
done
mkdir -p "$SOURCES"

curl -fsSL --retry 3 -o "$SOURCES/mesa-$MESA_VERSION.tar.xz" \
    "https://archive.mesa3d.org/mesa-$MESA_VERSION.tar.xz"
echo "$MESA_SHA256  $SOURCES/mesa-$MESA_VERSION.tar.xz" | shasum -a 256 -c -
tar -xf "$SOURCES/mesa-$MESA_VERSION.tar.xz" -C "$SOURCES"
test -f "$MESA/meson.build"

mkdir -p "$MVK"
git -C "$MVK" init -q
git -C "$MVK" fetch --depth 1 https://github.com/KhronosGroup/MoltenVK.git "$MOLTENVK_REV"
git -C "$MVK" checkout -q --detach FETCH_HEAD
[ "$(git -C "$MVK" rev-parse HEAD)" = "$MOLTENVK_REV" ]

python3 -m venv "$VENV"
"$VENV/bin/pip" install --disable-pip-version-check -q \
    meson==1.7.2 mako==1.3.10 pyyaml==6.0.2 packaging==25.0 ninja==1.11.1.4

MOLTENVK_SRC="$MVK" bash "$M/build/moltenvk-ios/build.sh"
MESA_SRC="$MESA" MOLTENVK_SRC="$MVK" MESA_VENV="$VENV" bash "$M/build/mesa-ios/build.sh"

# Device arm64 dylibs, found by @rpath name, linking only system libraries and
# each other. The driver dlopens both from the bundle's gl/ folder.
for name in libMoltenVK libOSMesa; do
    lib="$OUT/$name.dylib"
    test -s "$lib"
    xcrun lipo -verify_arch arm64 "$lib"
    [ "$(xcrun lipo -archs "$lib")" = arm64 ] || { echo "$name is not arm64 only" >&2; exit 1; }
    commands="$(xcrun otool -l "$lib")"
    grep -q 'platform 2$' <<<"$commands" || { echo "$name is not an iOS device binary" >&2; exit 1; }
    [ "$(xcrun otool -D "$lib" | tail -1)" = "@rpath/$name.dylib" ] || { echo "$name has an unexpected install name" >&2; exit 1; }
    if xcrun otool -L "$lib" | tail -n +3 | awk '{print $1}' | grep -v -E '^(/usr/lib/|/System/Library/|@rpath/lib(MoltenVK|OSMesa)\.dylib$)'; then
        echo "$name links a library the app does not ship" >&2; exit 1
    fi
done
for text in Mesa-license.rst MoltenVK-Apache-2.0.txt SPIRV-Cross-Apache-2.0.txt \
            SPIRV-Tools-Apache-2.0.txt cereal-BSD-3-Clause.txt; do
    test -s "$M/app/Madeira/licenses/$text"
done
python3 "$ROOT/ci/collect-release-source.py" opengl
# The source archives are collected; free the runner's disk for the app build.
rm -rf "$MVK" "$MESA" "$VENV" "$M/build/mesa-ios/obj"
ls -l "$OUT"
