"""Source checks for the experimental Steam client mode.

The Swift side is compiled only on macOS (GamePrerequisitesCheck.swift and the
app build); these checks keep the Swift plan writer, the native helper and
Madeira's proven steam.exe flags in agreement on any host.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "iridium/apps/ios"
SUPPORT = IOS / "MadeiraSupport"


class SteamClientModeSourceTests(unittest.TestCase):
    def setUp(self):
        self.client = (SUPPORT / "MadeiraSteamClient.swift").read_text()
        self.plan = (SUPPORT / "IridiumGamePrerequisites.swift").read_text()
        self.helper = (SUPPORT / "prerequisites.c").read_text()
        self.adapter = (SUPPORT / "MadeiraRuntimeAdapter.swift").read_text()
        self.settings = (IOS / "Iridium/Views/SettingsView.swift").read_text()

    def test_flags_match_madeiras_steam_launch(self):
        madeira = (ROOT / "testrepos/Madeira/app/Madeira/ContentView.swift").read_text()
        line = re.search(r'\\\\steam\.exe" (-[^\r\n]*?)\\r', madeira)
        self.assertIsNotNone(line, "Madeira's generated steam.exe command moved")
        swift = re.search(r"static let defaultArguments = \[(.*?)\]", self.client, re.S).group(1)
        self.assertEqual(re.findall(r'"([^"]+)"', swift), line.group(1).split())

    def test_setting_is_off_by_default_and_only_selects_drm_games(self):
        self.assertIn('static let preferenceKey = "IridiumSteamClient"', self.client)
        self.assertIn("@AppStorage(MadeiraSteamClient.preferenceKey) private var steamClient = false", self.settings)
        self.assertIn('sectionNames(executable).contains(".bind")', self.client)
        body = self.client[self.client.index("static func request("):self.client.index("static func hasSteamDRM(")]
        # The game's own iridium.cfg is read before the global switch.
        self.assertLess(body.index("MadeiraGameConfig.value(configKey"), body.index("guard enabled"))

    def test_adapter_decides_before_writing_the_plan(self):
        boot = self.adapter[self.adapter.index("let mediaProbe ="):self.adapter.index("RuntimeLogCapture.writeLine(\"[Launch] Game files")]
        self.assertLess(boot.index("MadeiraSteamClient.request("), boot.index("IridiumGamePrerequisites.prepare("))
        self.assertIn("steam: steamClient)", boot)
        self.assertIn("enabled: MadeiraSteamClient.isEnabled", boot)
        self.assertIn("if !mediaProbe {", boot)

    def test_plan_keys_are_the_ones_the_helper_reads(self):
        self.assertIn('"steam=\\(steam == nil ? 0 : 1)"', self.plan)
        for key in ("executable", "command", "directory"):
            self.assertIn('"%s=\\(try value(steam.%s))"' % (key, key), self.plan)
            self.assertIn('field(L"steam", L"%s", ' % key, self.helper)
        self.assertIn('GetPrivateProfileIntW(L"plan", L"steam", 0, config)', self.helper)
        self.assertIn('"[steam]"', self.plan)

    def test_every_helper_phase_has_a_message(self):
        phases = set(re.findall(r'status\("([a-z-]+)"', self.helper))
        self.assertTrue({"steam", "steam-login", "steam-exit"} <= phases)
        for phase in phases - {"installer"}:
            self.assertIn('fields == ["%s"]' % phase, self.plan, phase)

    def test_helper_hides_the_games_app_id_from_steam_and_closes_it(self):
        self.assertIn('L"SteamAppId", L"SteamGameId", L"SteamAppPath"', self.helper)
        entry = self.helper[self.helper.index("int wmain("):]
        self.assertLess(entry.index("steam_start()"), entry.index('status("game"'))
        self.assertLess(entry.index("run_process(INFINITE, NULL)"), entry.rindex("steam_stop()"))


if __name__ == "__main__":
    unittest.main()
