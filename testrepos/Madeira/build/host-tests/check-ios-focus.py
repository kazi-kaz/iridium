#!/usr/bin/env python3
"""A game's window gets the foreground even when GA_ROOT cannot name it.

On iOS GetAncestor(GA_ROOT) answered 0 for the game's own window and nothing
made that window foreground, so no window was active or focused and Wine dropped
every key press (Ren'Py: taps worked, the keyboard did not). Two changes:

* message_ios.c: a click's activation falls back to ios_top_level_window(),
  which walks GA_PARENT, when GA_ROOT answers 0.
* driver_ios.c: when input arrives and no window is foreground, the window
  input would go to is made foreground, from its own thread.

Compiles the production ios_top_level_window, extracted from message_ios.c,
against a stub window tree and checks the wiring of both changes in the source.
No Wine, SDK or device needed.
"""
import os, re, shutil, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CC = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")

msg = (ROOT / "build/win32u-unix/message_ios.c").read_text(encoding="utf-8").replace("\r\n", "\n")
drv = (ROOT / "build/win32u-unix/driver_ios.c").read_text(encoding="utf-8").replace("\r\n", "\n")

start = msg.index("static HWND ios_top_level_window(")
helper = msg[start:msg.index("\n}\n", start) + 3]

# message_ios.c: the fallback runs right after GA_ROOT and before the style test.
root = msg.index("HWND hwndTop = NtUserGetAncestor( msg->hwnd, GA_ROOT );")
fallback = msg.index("hwndTop = ios_top_level_window( msg->hwnd );", root)
style = msg.index("get_window_long( hwndTop, GWL_STYLE )", fallback)
assert root < fallback < style, "fallback sits between GA_ROOT and the style test"

# driver_ios.c: both input paths try to focus the game window before delivering.
helper_def = drv.index("static HWND winios_focus_game_window(void)")
mouse = drv[drv.index("void winios_drv_post_mouse("):]
assert mouse.index("winios_focus_game_window()") < mouse.index("send_hardware_message"), \
    "mouse: focus before delivery"
key = drv[drv.index("void winios_drv_post_key("):]
key = key[:key.index("winios_log_input(\"key\"")]
assert key.index("winios_focus_game_window()") < key.index("send_hardware_message"), \
    "key: focus before delivery"
body = drv[helper_def:drv.index("\n}\n", helper_def)]
assert "get_window_thread( target, NULL ) != GetCurrentThreadId()" in body, \
    "only the window's own thread changes the foreground"
assert "failures >= 16" in body, "gives up after repeated failures"
assert "winios_desktop_mode" in key and "winios_desktop_mode" in mouse, "desktop mode is left alone"

harness = r'''
#include <stdio.h>
typedef void *HWND;
#define GA_PARENT 1
#define H(n) ((HWND)(long)(n))
#define DESKTOP H(0x10)
static HWND parent_of[64];          /* index = window number; 0 = unknown/invalid */
HWND get_desktop_window(void) { return DESKTOP; }
HWND get_full_window_handle(HWND h) { return h; }
HWND NtUserGetAncestor(HWND h, int type)
{
    long n = (long)h;
    (void)type;
    if (n <= 0 || n >= 64) return 0;
    return parent_of[n];
}
''' + helper + r'''
static int fails;
static void expect(const char *what, HWND got, HWND want)
{
    if (got != want) { printf("FAIL %s: got %p, want %p\n", what, got, want); fails++; }
}
int main(void)
{
    parent_of[0x20] = DESKTOP;            /* top-level game window */
    parent_of[0x21] = H(0x20);            /* child of it */
    parent_of[0x22] = H(0x21);            /* grandchild */
    parent_of[0x30] = H(0x31);            /* two windows that name each other */
    parent_of[0x31] = H(0x30);
    expect("top-level window is its own top-level", ios_top_level_window(H(0x20)), H(0x20));
    expect("child walks up", ios_top_level_window(H(0x21)), H(0x20));
    expect("grandchild walks up", ios_top_level_window(H(0x22)), H(0x20));
    expect("desktop gives 0", ios_top_level_window(DESKTOP), 0);
    expect("unknown window is returned as is", ios_top_level_window(H(0x25)), H(0x25));
    expect("null gives 0", ios_top_level_window(0), 0);
    (void)ios_top_level_window(H(0x30));   /* must terminate */
    printf(fails ? "FAILED\n" : "ok\n");
    return fails != 0;
}
'''

with tempfile.TemporaryDirectory(prefix="madeira-ios-focus-") as tmp:
    tmp = Path(tmp)
    (tmp / "c.c").write_text(harness, encoding="utf-8")
    subprocess.run([CC, "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                    str(tmp / "c.c"), "-o", str(tmp / "c")], check=True)
    r = subprocess.run([str(tmp / "c")], capture_output=True, text=True)
    print(r.stdout, end="")
    assert r.returncode == 0

print("PASS game window is made foreground, GA_ROOT fallback walks GA_PARENT")
