#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
for arch in x64 x86 arm64ec; do
  compiler=x86_64-w64-mingw32-gcc
  [ "$arch" != x86 ] || compiler=i686-w64-mingw32-gcc
  if [ "$arch" = arm64ec ]; then
    compiler="$root/../../../testrepos/Madeira/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/arm64ec-w64-mingw32-clang"
  fi
  mkdir -p "$root/ControllerRuntime/$arch"
  "$compiler" -shared -O2 -static-libgcc "$root/MadeiraSupport/xinput.c" \
    "$root/MadeiraSupport/xinput.def" -o "$root/ControllerRuntime/$arch/xinput.dll"
done
# The service manager and MSI host are native ARM64. Start the installer
# session natively; Wine selects WoW64 or ARM64EC for each child executable.
compiler="$root/../../../testrepos/Madeira/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/aarch64-w64-mingw32-clang"
mkdir -p "$root/ControllerRuntime/aarch64"
"$compiler" -O2 -municode -static-libgcc "$root/MadeiraSupport/prerequisites.c" \
  -o "$root/ControllerRuntime/aarch64/iridium-prerequisites.exe" -ladvapi32 -lgdi32 -luser32
# Madeira Dock host (testrepos/madeira-dock, GPL-3.0-or-later with the Madeira
# Converter Exception). x86-64 like the client library it loads; the runtime
# runs it through ARM64EC emulation. Stripped, with its licence and the static
# LLVM/MinGW-w64 runtime notices beside it. No Valve binary is bundled.
dock="$root/../../../testrepos/madeira-dock"
compiler="$root/../../../testrepos/Madeira/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang"
[ -z "${DOCK_CC:-}" ] || compiler="$DOCK_CC"
mkdir -p "$root/ControllerRuntime/x64"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -Wno-cast-function-type -static \
  -Wl,--strip-all -Wl,--no-insert-timestamp -o "$root/ControllerRuntime/x64/dockhost.exe" \
  "$dock/src/main.c" "$dock/src/probe.c" "$dock/src/session.c" "$dock/src/launch.c" \
  "$dock/src/validation.c" "$dock/src/auth.c" "$dock/src/client_layout.c" "$dock/src/scm.c" -ladvapi32
{
  cat "$dock/LICENSE"
  printf '\n\n==== %s ====\n\n' 'LICENSE-EXCEPTION.md (Madeira Converter Exception)'
  cat "$dock/LICENSE-EXCEPTION.md"
  printf '\n\n==== %s ====\n\n' 'COPYING (GNU General Public License, version 3)'
  cat "$dock/COPYING"
  printf '\n\n==== %s ====\n\n' 'MinGW-w64 runtime notice (statically linked runtime)'
  cat "$dock/notices/MinGW-w64-runtime.txt"
  printf '\n\n==== %s ====\n\n' 'LLVM runtime notice'
  cat "$dock/notices/LLVM.txt"
  printf '\n\nCorresponding source: testrepos/madeira-dock in this repository (upstream https://github.com/willfaust/madeira-dock).\n'
} > "$root/ControllerRuntime/x64/dock-notices.txt"
