"""Run the prerequisite helper's Steam client stage under real Wine.

Requires a MinGW-w64 x86-64 compiler and Wine; skipped otherwise (the source
checks runner has neither). The helper is built for x86-64 here instead of
ARM64, and stand-in programs play Steam and the game, so this checks the
helper's control flow and Win32 use, not Steam, FEX or the iOS runtime.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "iridium/apps/ios/MadeiraSupport/prerequisites.c"
MINGW = shutil.which("x86_64-w64-mingw32-gcc")
WINE = next((p for p in (shutil.which("wine"), shutil.which("wine64"), "/usr/lib/wine/wine64")
             if p and os.access(p, os.X_OK)), None)

# Plays steam.exe: registers its pid, "signs in" after a delay unless told not
# to, starts a helper that ignores shutdown, and exits on "-shutdown".
FAKE_STEAM = r'''
#include <windows.h>
#include <stdio.h>
#include <string.h>
static void set_active(DWORD pid, DWORD user) {
    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Valve\\Steam\\ActiveProcess", 0, NULL, 0,
                        KEY_SET_VALUE, NULL, &key, NULL)) return;
    RegSetValueExW(key, L"pid", 0, REG_DWORD, (const BYTE *)&pid, sizeof(pid));
    RegSetValueExW(key, L"ActiveUser", 0, REG_DWORD, (const BYTE *)&user, sizeof(user));
    RegCloseKey(key);
}
static void note(const char *text) {
    FILE *f = fopen("C:\\steamtest\\steam.log", "a");
    if (f) { fprintf(f, "%s\n", text); fclose(f); }
}
int wmain(int argc, wchar_t **argv) {
    HANDLE quit = CreateEventW(NULL, TRUE, FALSE, L"IridiumFakeSteamQuit");
    if (argc > 1 && !wcscmp(argv[1], L"-shutdown")) {
        note("shutdown-requested");
        SetEvent(quit);
        return 0;
    }
    wchar_t value[64];
    note(GetEnvironmentVariableW(L"SteamAppId", value, 64) ? "steam-saw-appid" : "steam-env-clean");
    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    /* A self-update: the first steam.exe starts its replacement and exits. */
    if (DeleteFileW(L"C:\\steamtest\\restart-once")) {
        wchar_t again[] = L"C:\\steamtest\\Steam\\steam.exe -relaunched";
        Sleep(2000);
        if (CreateProcessW(L"C:\\steamtest\\Steam\\steam.exe", again, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
            CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
        }
        note("restarting");
        return 0;
    }
    wchar_t cmd[] = L"C:\\steamtest\\Steam\\steamwebhelper.exe";
    if (CreateProcessW(cmd, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
        CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    }
    Sleep(1000);
    set_active(GetCurrentProcessId(), 0);
    if (GetFileAttributesW(L"C:\\steamtest\\crash") != INVALID_FILE_ATTRIBUTES) {
        note("crashed");
        return 3;
    }
    if (GetFileAttributesW(L"C:\\steamtest\\never-sign-in") == INVALID_FILE_ATTRIBUTES) {
        Sleep(1500);
        set_active(GetCurrentProcessId(), 12345);
        note("signed-in");
    }
    WaitForSingleObject(quit, 120000);
    set_active(0, 0);
    note("steam-exited");
    return 0;
}
'''

# Plays steamwebhelper.exe: never exits on its own.
FAKE_HELPER = r'''
#include <windows.h>
int main(void) { Sleep(INFINITE); return 0; }
'''

# Plays the game: records what it saw, exits with a distinctive code.
FAKE_GAME = r'''
#include <windows.h>
#include <stdio.h>
int main(void) {
    HKEY key;
    DWORD user = 0, size = sizeof(user);
    if (!RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Valve\\Steam\\ActiveProcess", 0, KEY_QUERY_VALUE, &key)) {
        RegQueryValueExW(key, L"ActiveUser", NULL, NULL, (BYTE *)&user, &size);
        RegCloseKey(key);
    }
    char appid[32] = "";
    GetEnvironmentVariableA("SteamAppId", appid, sizeof(appid));
    FILE *f = fopen("C:\\steamtest\\game.log", "w");
    if (f) { fprintf(f, "user=%lu appid=%s\n", user, appid); fclose(f); }
    return 7;
}
'''

# Counts Steam images still running after the helper returned.
COUNT = r'''
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
int main(void) {
    int found = 0;
    HANDLE s = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    PROCESSENTRY32W e; e.dwSize = sizeof(e);
    for (BOOL m = Process32FirstW(s, &e); m; m = Process32NextW(s, &e))
        if (!_wcsicmp(e.szExeFile, L"steam.exe") || !_wcsicmp(e.szExeFile, L"steamwebhelper.exe")) found++;
    printf("steam-processes=%d\n", found);
    return 0;
}
'''


def plan(steam_flag=1, runs=0):
    def v(text):
        return "x" + text + "x"
    steam = "C:\\steamtest\\Steam\\steam.exe"
    game = "C:\\steamtest\\game.exe"
    lines = ["[plan]", "runs=%d" % runs, "steam=%d" % steam_flag,
             "[steam]", "executable=" + v(steam), "command=" + v('"%s" -no-cef-sandbox' % steam),
             "directory=" + v("C:\\steamtest\\Steam"),
             "[game]", "executable=" + v(game), "command=" + v('"%s"' % game),
             "directory=" + v("C:\\steamtest")]
    return b"\xff\xfe" + ("\r\n".join(lines) + "\r\n").encode("utf-16-le")


@unittest.skipUnless(MINGW and WINE, "requires MinGW-w64 x86-64 and Wine")
class SteamClientHelperUnderWine(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        root = Path(cls.temp.name)
        cls.env = dict(os.environ, WINEPREFIX=str(root / "prefix"), WINEDEBUG="-all",
                       WINEDLLOVERRIDES="mscoree,mshtml=", DISPLAY="")
        subprocess.run([WINE, "wineboot", "-i"], env=cls.env, check=True,
                       capture_output=True, timeout=300)
        cls.drive = root / "prefix/drive_c"
        work = cls.drive / "steamtest"
        (work / "Steam").mkdir(parents=True)
        (cls.drive / "IridiumPrerequisites").mkdir()
        sources = root / "src"
        sources.mkdir()

        def build(name, text, out, unicode=False, extra=()):
            src = sources / (name + ".c")
            src.write_text(text)
            subprocess.run([MINGW, "-O2", *(["-municode"] if unicode else []), str(src),
                            "-o", str(out), *extra], check=True, capture_output=True, timeout=120)

        build("helper", HELPER.read_text(), cls.drive / "IridiumPrerequisites/iridium-prerequisites.exe",
              unicode=True, extra=("-static-libgcc", "-ladvapi32", "-lgdi32"))
        build("steam", FAKE_STEAM, work / "Steam/steam.exe", unicode=True)
        build("webhelper", FAKE_HELPER, work / "Steam/steamwebhelper.exe")
        build("game", FAKE_GAME, work / "game.exe")
        build("count", COUNT, work / "count.exe")

    @classmethod
    def tearDownClass(cls):
        subprocess.run(["/usr/lib/wine/wineserver" if os.path.exists("/usr/lib/wine/wineserver") else "wineserver", "-k"],
                       env=cls.env, capture_output=True, timeout=60)
        cls.temp.cleanup()

    def setUp(self):
        work = self.drive / "steamtest"
        for name in ("steam.log", "game.log", "never-sign-in", "restart-once", "crash"):
            (work / name).unlink(missing_ok=True)
        for name in ("status.txt", "cancel.flag"):
            (self.drive / "IridiumPrerequisites" / name).unlink(missing_ok=True)

    def run_helper(self, ini, env=None, cancel_after=None):
        (self.drive / "IridiumPrerequisites/installers.ini").write_bytes(ini)
        process = subprocess.Popen([WINE, "C:\\IridiumPrerequisites\\iridium-prerequisites.exe",
                                    "C:\\IridiumPrerequisites\\installers.ini"],
                                   env=dict(self.env, **(env or {})), stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        if cancel_after is not None:
            time.sleep(cancel_after)
            (self.drive / "IridiumPrerequisites/cancel.flag").write_bytes(b"")
        out, err = process.communicate(timeout=180)
        return process.returncode, err

    def steam_left(self):
        out = subprocess.run([WINE, "C:\\steamtest\\count.exe"], env=self.env, capture_output=True,
                             text=True, timeout=120).stdout
        return out.strip()

    def log(self, name):
        path = self.drive / "steamtest" / name
        return path.read_text().split() if path.exists() else []

    def test_signs_in_runs_game_and_closes_steam(self):
        code, err = self.run_helper(plan(), env={"SteamAppId": "655500", "SteamGameId": "655500"})
        self.assertEqual(code, 7, err)
        self.assertIn("Steam account signed in.", err)
        # The first process must own the GDI table before any child is cloned from it.
        self.assertRegex(err, r"\[Prerequisites\] GDI handle table (0x)?0*[1-9a-fA-F][0-9a-fA-F]*")
        self.assertEqual(self.log("game.log"), ["user=12345", "appid=655500"])
        steam = self.log("steam.log")
        self.assertEqual(steam[0], "steam-env-clean")
        self.assertIn("signed-in", steam)
        self.assertIn("shutdown-requested", steam)
        self.assertIn("steam-exited", steam)
        self.assertIn("Ended 1 Steam process(es)", err)  # the webhelper that ignored shutdown
        self.assertEqual(self.steam_left(), "steam-processes=0")
        self.assertEqual((self.drive / "IridiumPrerequisites/status.txt").read_text().strip(), "steam-exit")

    def test_close_while_waiting_for_sign_in_ends_steam_promptly(self):
        (self.drive / "steamtest/never-sign-in").write_bytes(b"")
        started = time.monotonic()
        code, err = self.run_helper(plan(), cancel_after=8)
        self.assertEqual(code, 1223 & 0xff, err)  # ERROR_CANCELLED; Unix keeps 8 bits
        self.assertLess(time.monotonic() - started, 60)
        self.assertEqual(self.log("game.log"), [])
        self.assertNotIn("shutdown-requested", self.log("steam.log"))
        self.assertEqual(self.steam_left(), "steam-processes=0")

    def test_steam_restarting_itself_before_sign_in_is_followed(self):
        (self.drive / "steamtest/restart-once").write_bytes(b"")
        code, err = self.run_helper(plan())
        self.assertEqual(code, 7, err)
        steam = self.log("steam.log")
        self.assertEqual(steam[:2], ["steam-env-clean", "restarting"])
        self.assertIn("signed-in", steam)
        self.assertEqual(self.steam_left(), "steam-processes=0")

    def test_steam_exiting_before_sign_in_fails_the_launch(self):
        (self.drive / "steamtest/crash").write_bytes(b"")
        code, err = self.run_helper(plan())
        self.assertEqual(code, 3, err)  # steam.exe's own exit code
        self.assertIn("Steam exited before sign-in: 3", err)
        self.assertEqual(self.log("game.log"), [])
        self.assertEqual(self.steam_left(), "steam-processes=0")  # its webhelper too

    def test_plan_without_installers_or_steam_is_rejected(self):
        code, _ = self.run_helper(plan(steam_flag=0))
        self.assertEqual(code, 13)  # ERROR_INVALID_DATA
        code, _ = self.run_helper(plan(steam_flag=2))
        self.assertEqual(code, 13)
        self.assertEqual(self.log("steam.log"), [])


if __name__ == "__main__":
    unittest.main()
