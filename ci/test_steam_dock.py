"""Madeira Dock: the vendored host, its build, and Iridium's side of the contract.

The host (testrepos/madeira-dock) loads Valve's genuine Steam client and starts a
game through it. These checks cover the contract between that host and Iridium:
the environment, the one-use sign-in envelope, the numeric report, the helper
plan and the build. They do not run Valve's client, Wine, FEX or a game.
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DOCK = ROOT / "testrepos/madeira-dock"
IOS = ROOT / "iridium/apps/ios"
SUPPORT = IOS / "MadeiraSupport"
SWIFT = SUPPORT / "MadeiraSteamDock.swift"


def swift_set(source, name):
    body = source[source.index("static let %s: Set<String> = [" % name):]
    body = body[:body.index("]")]
    return set(re.findall(r'"([^"]+)"', body))


def host_source():
    return "\n".join(path.read_text() for path in sorted((DOCK / "src").glob("*.c")))


class SteamDockContractTests(unittest.TestCase):
    def setUp(self):
        self.swift = SWIFT.read_text()
        self.adapter = (SUPPORT / "MadeiraRuntimeAdapter.swift").read_text()
        self.plan = (SUPPORT / "IridiumGamePrerequisites.swift").read_text()
        self.helper = (SUPPORT / "prerequisites.c").read_text()
        self.script = (IOS / "Scripts/build_controller_runtime.sh").read_text()

    def test_vendored_host_keeps_its_license_and_every_source_is_built(self):
        for name in ("LICENSE", "COPYING", "LICENSE-EXCEPTION.md", "THIRD-PARTY-NOTICES.md",
                     "notices/LLVM.txt", "notices/MinGW-w64-runtime.txt"):
            self.assertTrue((DOCK / name).is_file(), name)
        sources = sorted(path.name for path in (DOCK / "src").glob("*.c"))
        self.assertTrue(sources)
        for name in sources:
            self.assertIn('"$dock/src/%s"' % name, self.script)
            self.assertIn("SPDX-License-Identifier: GPL-3.0-or-later", (DOCK / "src" / name).read_text())
        for flag in ("-Werror", "-static", "-Wl,--strip-all", "-ladvapi32"):
            self.assertIn(flag, self.script)
        self.assertIn("ControllerRuntime/x64/dock-notices.txt", self.script)
        self.assertIn('Bundle', self.swift)
        self.assertIn('forResource: "dockhost", withExtension: "exe", subdirectory: "ControllerRuntime/x64"', self.swift)
        for listing in ("ci/madeira-package.py", "ci/check-ipa-prerequisites.py"):
            text = (ROOT / listing).read_text()
            self.assertIn("ControllerRuntime/x64/dockhost.exe", text)
            self.assertIn("ControllerRuntime/x64/dock-notices.txt", text)

    def test_pinned_client_is_a_build_the_host_supports(self):
        pinned = re.search(r'static let clientSHA256 = "([0-9a-f]{64})"', self.swift).group(1)
        self.assertIn('"%s"' % pinned, (DOCK / "src/client_layout.c").read_text())
        self.assertIn('static let origin = "https://client-update.akamai.steamstatic.com/"', self.swift)
        self.assertEqual(len(re.findall(r'Package\(file: "[a-z0-9_]+\.zip\.[0-9a-f]{40}", bytes: [0-9_]+,\s*sha256: "[0-9a-f]{64}"\)',
                                        self.swift)), 3)

    def test_report_fields_and_rounds_are_the_hosts(self):
        host = host_source()
        emitted = set(re.findall(r'event\("([a-z0-9-]+)"', host))
        allowed = swift_set(self.swift, "reportAllowed")
        # Built from a variable in scm.c, not a literal.
        self.assertEqual(allowed - emitted - {"ceg-scm-started"}, set())
        main = (DOCK / "src/main.c").read_text()
        rounds = set(re.findall(r'"(ml\d{4})"', main[main.index("static void event("):main.index("static bool enabled(")]))
        self.assertTrue(rounds)
        self.assertLessEqual(rounds, swift_set(self.swift, "reportRounds"))
        for field in ("probe-result", "session-authenticated-online", "launch-game-running"):
            self.assertIn(field, allowed)

    def test_environment_names_are_read_by_the_host_or_runtime(self):
        body = self.swift[self.swift.index("static func environment("):self.swift.index("// MARK: Report")]
        names = set(re.findall(r'set\("([A-Z0-9_]+)"', body)) | set(re.findall(r'"(MADEIRA_STEAM_HOST_[A-Z_]+)"', body))
        host = host_source()
        bridge = (ROOT / "testrepos/Madeira/app/Madeira/WineProcessBridge.m").read_text()
        virtual = (ROOT / "testrepos/Madeira/build/ntdll-unix/virtual_ios.c").read_text()
        for name in names:
            self.assertTrue(name in host or name in bridge or name in virtual, name)
        # The account selection the host would take from the environment is never set.
        self.assertNotIn('set("MADEIRA_STEAM_HOST_ACCOUNT"', body)
        self.assertNotIn('set("MADEIRA_STEAM_HOST_STEAMID"', body)
        keys = self.swift[self.swift.index("static let environmentKeys = ["):]
        keys = keys[:keys.index("]")]
        for name in ("MADEIRA_STEAM_HOST_ACCOUNT", "MADEIRA_STEAM_HOST_STEAMID", "MADEIRA_DOCK_AUTH_FILE"):
            self.assertIn('"%s"' % name, keys)
        self.assertIn("MADEIRA_DOCK_SESSION", bridge)

    def test_plan_keys_are_the_ones_the_helper_reads(self):
        self.assertIn('"dock=\\(dock == nil ? 0 : 1)"', self.plan)
        self.assertIn('"[dock]"', self.plan)
        for key in ("executable", "command", "directory"):
            self.assertIn('"%s=\\(try value(dock.%s))"' % (key, key), self.plan)
            self.assertIn('field(L"dock", L"%s", ' % key, self.helper)
        self.assertIn('GetPrivateProfileIntW(L"plan", L"dock", 0, config)', self.helper)
        self.assertIn('fields == ["dock"]', self.plan)
        entry = self.helper[self.helper.index("int wmain("):]
        dock = entry.index("if (use_dock)")
        # After every installer group, instead of the Steam client and the game.
        self.assertLess(entry.index("record_run(section)"), dock)
        self.assertLess(dock, entry.index("steam_start()"))
        self.assertLess(dock, entry.index('status("game"'))

    def test_adapter_prepares_dock_before_the_plan_and_never_logs_secrets(self):
        boot = self.adapter[self.adapter.index("let mediaProbe ="):self.adapter.index('RuntimeLogCapture.writeLine("[Launch] Game files')]
        order = [boot.index(text) for text in (
            "for key in MadeiraSteamDock.environmentKeys { unsetenv(key) }",
            "MadeiraSteamDock.preparePrefix(", "MadeiraSteamDock.writeHandoff(",
            "MadeiraSteamDock.environment(", "IridiumGamePrerequisites.prepare(")]
        self.assertEqual(order, sorted(order))
        self.assertIn('for key in ["SteamAppId", "SteamGameId", "SteamAppPath"] { unsetenv(key) }', boot)
        failure = self.adapter[self.adapter.index("let failure: (String) -> Void"):self.adapter.index("let boot = {")]
        self.assertIn("MadeiraSteamDock.cleanup()", failure)
        self.assertIn("dockReport.failure", self.adapter)
        for line in re.findall(r'RuntimeLogCapture\.writeLine\((.*)\)', self.adapter):
            self.assertNotIn("token", line)
            self.assertNotIn("account", line.lower())
        self.assertNotIn("writeLine", self.swift)

    def test_view_model_hands_steam_over_only_for_a_dock_launch(self):
        model = (IOS / "Iridium/AppViewModel.swift").read_text()
        play = model[model.index("let steamDock: MadeiraSteamDock.Request?"):model.index("steamDock: steamDock) {")]
        self.assertIn("if steamDock != nil { SteamLibraryModel.shared.releaseForDock() }", play)
        request = model[model.index("private func steamDockRequest("):model.index("private func madeiraLaunchIssue(")]
        for gate in ("bundledHost()", "componentsReady()", "dockCredential()", "SteamLibraryModel.shared.busy"):
            self.assertIn(gate, request)
        steam = (IOS / "Iridium/SteamLibraryModel.swift").read_text()
        release = steam[steam.index("func releaseForDock()"):steam.index("func loadDetails(")]
        self.assertIn('send(["action": "disconnect"])', release)
        self.assertNotIn("SteamKeychain.clear", release)
        engine = (ROOT / "iridium/packages/steam/Iridium.Steam/SteamEngine.cs").read_text()
        disconnect = engine[engine.index('command.Action == "disconnect"'):]
        disconnect = disconnect[:disconnect.index("return true;")]
        self.assertIn("connection?.Dispose(); connection = null;", disconnect)
        self.assertNotIn("pendingSecret = null", disconnect)

    @unittest.skipUnless(shutil.which("cc"), "requires a C compiler")
    def test_host_unit_tests(self):
        with tempfile.TemporaryDirectory() as temp:
            for name in ("probe", "validation", "auth", "client_layout"):
                binary = Path(temp) / name
                subprocess.run(["cc", "-std=c11", "-O1", "-Wall", "-Wextra", "-Werror", "-I", str(DOCK / "src"),
                                str(DOCK / "src" / (name + ".c")), str(DOCK / "tests" / ("test-%s.c" % name)),
                                "-o", str(binary)], check=True, capture_output=True, timeout=60)
                subprocess.run([str(binary)], check=True, capture_output=True, timeout=30)

    @unittest.skipUnless(shutil.which("x86_64-w64-mingw32-clang"), "requires llvm-mingw")
    def test_host_cross_compiles_with_warnings_as_errors(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "dockhost.exe"
            subprocess.run(["x86_64-w64-mingw32-clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                            "-Wno-cast-function-type", "-static", "-Wl,--strip-all", "-o", str(output),
                            *[str(path) for path in sorted((DOCK / "src").glob("*.c"))], "-ladvapi32"],
                           check=True, capture_output=True, timeout=120)
            self.assertEqual(output.read_bytes()[:2], b"MZ")

    @unittest.skipUnless(shutil.which("xcrun") and shutil.which("cc"), "requires Apple Swift compiler")
    def test_swift_side_against_the_hosts_own_envelope_reader(self):
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            payload = ("steam " * 400).encode()
            with zipfile.ZipFile(work / "good.zip", "w") as archive:
                archive.writestr(zipfile.ZipInfo("bin\\stored.dll"), b"stored bytes")
                archive.writestr("deflated.txt", payload, compress_type=zipfile.ZIP_DEFLATED)
                folder = zipfile.ZipInfo("dir/")
                folder.external_attr = (0o40755 << 16) | 0x10
                archive.writestr(folder, b"")
            good = (work / "good.zip").read_bytes()
            stored = good.index(b"stored bytes")
            (work / "crc.zip").write_bytes(good[:stored] + b"X" + good[stored + 1:])
            (work / "truncated.zip").write_bytes(good[:-10])
            with zipfile.ZipFile(work / "traversal.zip", "w") as archive:
                archive.writestr("../evil.txt", b"x")
            with zipfile.ZipFile(work / "duplicate.zip", "w") as archive:
                archive.writestr("A.txt", b"x")
                archive.writestr("a.txt", b"y")
            binary = work / "check"
            subprocess.run(["xcrun", "swiftc", "-swift-version", "5",
                            *[str(SUPPORT / name) for name in ("MadeiraSteamDock.swift", "MadeiraGameConfig.swift",
                                                               "MadeiraSteamClient.swift")],
                            str(IOS / "MadeiraSupportTests/SteamDockCheck.swift"), "-o", str(binary)],
                           check=True, capture_output=True, timeout=180)
            subprocess.run([str(binary), str(work)], check=True, capture_output=True, timeout=60)
            harness = r'''
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "auth.h"
int main(int argc, char **argv) {
    unsigned char bytes[DOCK_AUTH_MAX + 1];
    FILE *file = fopen(argv[1], "rb");
    size_t size = fread(bytes, 1, sizeof(bytes), file);
    struct dock_auth auth;
    assert(dock_auth_parse(bytes, size, &auth));
    assert(auth.steam_id == 76561197960389184ULL && auth.app_id == 480);
    assert(!strcmp(auth.account, "fixture_account") && !strncmp(auth.token, "eyJ", 3));
    bytes[0] = 'X';
    assert(!dock_auth_parse(bytes, size, &auth));
    return 0;
}
'''
            (work / "envelope.c").write_text(harness)
            reader = work / "envelope"
            subprocess.run(["cc", "-std=c11", "-I", str(DOCK / "src"), str(work / "envelope.c"), str(DOCK / "src/auth.c"),
                            "-o", str(reader)], check=True, capture_output=True, timeout=60)
            subprocess.run([str(reader), str(work / "envelope.bin")], check=True, capture_output=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
