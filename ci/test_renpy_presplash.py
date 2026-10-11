"""Ren'Py games start without the generic launch defaults or OpenGL splash.

pygame_sdl2 adds SDL_WINDOW_OPENGL to every window unless the
PYGAME_SDL2_AVOID_GL hint (read from the environment too) is set. Madeira has
no OpenGL driver, so Ren'Py's presplash window failed and the game quit with
"pygame_sdl2.error.error: Invalid window" (The Sea Wolves, 2026-10-11).
Ren'Py's own renderer passes pygame.OPENGL explicitly, so only windows that
never needed OpenGL change. Wine copies the variable into the Windows
environment (env_ios.c ignores only a fixed list of host variables).

Ren'Py also rejects unknown command-line options, so Iridium's generic
compatibility default "--windowed" ended the game ("unrecognized arguments:
--windowed"). AppViewModel skips those defaults for a Ren'Py folder layout.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / "iridium/apps/ios/MadeiraSupport/MadeiraRuntimeAdapter.swift"
ENV = ROOT / "testrepos/Madeira/build/ntdll-unix/env_ios.c"
VIEW_MODEL = ROOT / "iridium/apps/ios/Iridium/AppViewModel.swift"


class RenPyPresplashTests(unittest.TestCase):
    def test_hint_is_set_for_every_launch_before_boot(self):
        adapter = ADAPTER.read_text()
        hint = adapter.index('setenv("PYGAME_SDL2_AVOID_GL", "1", 1)')
        # Same per-launch block as the controller DLL overrides, before the
        # executable is chosen and before the runtime reserves memory.
        self.assertLess(adapter.index('setenv("WINEDLLOVERRIDES"'), hint)
        self.assertLess(hint, adapter.index('RuntimeLogCapture.writeLine("[Launch] Reserving memory'))

    def test_wine_passes_the_variable_to_windows_programs(self):
        env = ENV.read_text()
        body = env[env.index("static BOOL is_ignored_env_var"):]
        body = body[:body.index("\n}\n")]
        self.assertNotIn("PYGAME", body)
        self.assertIsNone(re.search(r'STARTS_WITH\( var, "P', body))

    def test_renpy_games_get_no_generic_launch_defaults(self):
        model = VIEW_MODEL.read_text()
        body = model[model.index("private func gameApplyingCompatibilityLaunchDefaults("):]
        body = body[:body.index("\n    }\n")]
        guard = body.index("if Self.isRenPyGame(installPath: game.installPath)")
        # Before both the Unity OpenGL arguments and the profile defaults.
        self.assertLess(guard, body.index("metalOpenGLFallbackArguments("))
        self.assertLess(guard, body.index("compatibility.launchArguments"))
        self.assertEqual(body[guard:].split("\n")[1].strip(), "return game")
        detector = model[model.index("static func isRenPyGame(installPath: String) -> Bool"):]
        detector = detector[:detector.index("\n    }\n")]
        self.assertIn('isDirectory("renpy") && isDirectory("game")', detector)


if __name__ == "__main__":
    unittest.main()
