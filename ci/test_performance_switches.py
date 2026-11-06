"""The opt-in performance switches: Settings, iridium.cfg, environment, status line."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'iridium/apps/ios'


class PerformanceSwitchTests(unittest.TestCase):
    def test_switches_are_applied_before_the_wine_server_starts(self):
        source = (IOS / 'MadeiraSupport/MadeiraRuntimeAdapter.swift').read_text()
        start = source.index('static func start(')
        config = source.index('MadeiraGameConfig.locate(gameRoot:', start)
        apply = source.index('MadeiraPerformance.apply(MadeiraPerformance.settings(gameConfig: gameConfig))', start)
        jit = source.index('jit_install_trap_handler()', start)
        self.assertLess(config, apply, 'the game config must be located first, it overrides Settings')
        self.assertLess(apply, jit, 'the environment must be set before JIT and Wine start')
        self.assertIn('RuntimeLogCapture.writeLine(MadeiraPerformance.apply(', source,
                      'the choice is logged, so a log says what the launch ran with')

    def test_status_line_is_written_from_the_monitor_loop(self):
        source = (IOS / 'MadeiraSupport/MadeiraRuntimeAdapter.swift').read_text()
        loop = source[source.index('monitorTask = Task { @MainActor in'):]
        loop = loop[:loop.index('guard !Task.isCancelled, launchID == token else { return }')]
        self.assertIn('MadeiraStatusLine.format(', loop)
        self.assertIn('ProcessInfo.processInfo.thermalState', loop)
        self.assertIn('ProcessInfo.processInfo.isLowPowerModeEnabled', loop)
        self.assertIn('RuntimeMemorySnapshot.sample()', loop)
        self.assertIn('MadeiraStatusLine.interval', loop)

    def test_settings_screen_has_both_toggles_off_by_default(self):
        source = (IOS / 'Iridium/Views/SettingsView.swift').read_text()
        self.assertIn('@AppStorage(MadeiraPerformance.relaxedOrderingKey) private var relaxedOrdering = false', source)
        self.assertIn('@AppStorage(MadeiraPerformance.quietDiagnosticsKey) private var quietDiagnostics = false', source)
        self.assertIn('Section("Relaxed CPU Ordering (Experimental)")', source)
        self.assertIn('Section("Quiet Diagnostics")', source)

    def test_quiet_diagnostics_uses_the_variable_the_native_side_reads(self):
        swift = (IOS / 'MadeiraSupport/MadeiraPerformance.swift').read_text()
        c = (ROOT / 'testrepos/Madeira/build/ntdll-unix/server_ios.c').read_text()
        self.assertIn('("MADEIRA_NO_PROBES", "1")', swift)
        self.assertIn('("FEX_TSOENABLED", "0")', swift)
        self.assertGreaterEqual(c.count('getenv( "MADEIRA_NO_PROBES" )'), 2)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler is not installed')
    def test_switch_logic_and_status_line(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'performance-switches'
            subprocess.run([
                shutil.which('swiftc'),
                str(IOS / 'MadeiraSupport/MadeiraPerformance.swift'),
                str(IOS / 'MadeiraSupport/MadeiraStatusLine.swift'),
                str(IOS / 'MadeiraSupport/MadeiraGameConfig.swift'),
                str(IOS / 'MadeiraSupportTests/PerformanceSwitchCheck.swift'),
                '-o', str(binary),
            ], check=True, capture_output=True, text=True, timeout=180)
            result = subprocess.run(
                [str(binary)], check=True, capture_output=True, text=True, timeout=30)
            self.assertIn('Performance switch checks passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
