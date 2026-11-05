#!/usr/bin/env python3
"""The pointer area follows the virtual monitor, not a fixed 1024x768.

On the games path the server seeds the desktop's cursor clip when it creates
the detached desktop window, and that seed was a constant 1024x768. A game at a
larger Display Resolution then lost every touch beyond x=1023 or y=767 (Ren'Py
at 1280x720: the right part of its window could not be pressed). The only reset
is win32u's ios_publish_screen_size_once(), which runs on the first
SM_C{X,Y}SCREEN query made once the thread has the desktop window, and a game
may never make one after that point.

Checks the source: the seed reads MADEIRA_SCREEN_W/H with the same 1024x768
default and bounds, and the publish also runs from monitor enumeration and the
virtual-screen metrics. No Wine, SDK or device needed.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
window = (ROOT / "build/wineserver/window_ios.c").read_text(encoding="utf-8")
sysp = (ROOT / "build/win32u-unix/sysparams_ios.c").read_text(encoding="utf-8")

seed = window[window.index("monitors_get_union_rect returns (0,0,0,0)"):]
seed = seed[:seed.index("SHARED_WRITE_END;")]
assert "getenv( \"MADEIRA_SCREEN_W\" )" in seed and "getenv( \"MADEIRA_SCREEN_H\" )" in seed, \
    "the detached desktop's clip is seeded from MADEIRA_SCREEN_W/H"
assert re.search(r": 1024;", seed) and re.search(r": 768;", seed), "1024x768 stays the default when unset"
assert "cursor.clip.right = scr_w" in seed and "cursor.clip.bottom = scr_h" in seed
assert "cursor.clip.right = 1024" not in seed and "cursor.clip.bottom = 768" not in seed, \
    "no fixed clip is written any more"
assert "#include <stdlib.h>" in window, "getenv and atoi are declared"

# win32u publishes the size from every early monitor/screen query, once.
enum = sysp[sysp.index("BOOL WINAPI NtUserEnumDisplayMonitors("):]
enum = enum[:enum.index("lock_display_devices( FALSE )")]
assert "ios_publish_screen_size_once();" in enum, "EnumDisplayMonitors publishes the size"
for metric in ("SM_CXVIRTUALSCREEN", "SM_CYVIRTUALSCREEN"):
    case = sysp[sysp.index(f"    case {metric}:\n#ifdef WINE_IOS"):]
    case = case[:case.index("return rect.")]
    assert "ios_publish_screen_size_once();" in case, f"{metric} publishes the size"
once = sysp[sysp.index("static void ios_publish_screen_size_once(void)"):]
once = once[:once.index("\n}\n")]
assert "if (done) return;" in once, "publishing stays a once-only step"

print("PASS pointer clip follows MADEIRA_SCREEN_W/H")
