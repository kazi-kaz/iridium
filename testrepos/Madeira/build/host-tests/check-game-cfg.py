#!/usr/bin/env python3
"""Per-game iridium.cfg and WINEDLLOVERRIDES merging, with the production code.

  1. build/madeira_cfg.h: a key in $MADEIRA_GAME_CFG wins over madeira.cfg; a key
     the game file does not set keeps the global value; the legacy
     madeira-<key>.txt fallback still works and is also overlaid; a missing game
     file changes nothing.
  2. app/Madeira/WineProcessBridge.m (madeira_cfg_env_set/_restore, extracted
     from the source): WINEDLLOVERRIDES is appended after ';' instead of
     replacing the controller-bridge value, an empty value clears it, and the
     next launch restores what a previous launch's cfg set unless the app has
     set that variable again since.

No Wine, SDK, device or credentials are needed. Run with python3.
"""
import os, shutil, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CC = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8").replace("\r\n", "\n")


def between(text, start, end, include_end=False):
    i = text.index(start)
    j = text.index(end, i + len(start))
    return text[i:j + (len(end) if include_end else 0)]


bridge = read("app/Madeira/WineProcessBridge.m")
helpers = between(bridge, "#define MADEIRA_CFG_ENV_MAX", "/* Export MADEIRA_DOCS_DIR before main()")
assert "madeira_cfg_env_restore();" in bridge, "the env block must undo the previous launch first"
assert "madeira_cfg_game_path()" in bridge, "the env block must read the game file"

harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "madeira_cfg.h"
''' + helpers + r'''
static int fails;
static void expect(const char *what, const char *got, const char *want)
{
    int ok = (!got && !want) || (got && want && !strcmp(got, want));
    if (!ok) { fails++; printf("FAIL %s: got [%s] want [%s]\n", what, got ? got : "(unset)", want ? want : "(unset)"); }
}
static const char *cfg(const char *key)
{
    static char v[256];
    return madeira_cfg_get(key, v, sizeof v) ? v : NULL;
}
int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "";
    if (!strcmp(mode, "layer")) {
        expect("global only key", cfg("swap-mb"), "512");
        expect("game wins", cfg("vram-mb"), "2048");
        expect("game only key", cfg("pool"), "big");
        expect("unset key", cfg("nothing"), NULL);
        expect("int reader", madeira_cfg_int("vram-mb", 0) == 2048 ? "ok" : "bad", "ok");
        expect("sync engine from game", madeira_cfg_sync_engine() == MADEIRA_SYNC_WINE ? "wine" : "other", "wine");
    } else if (!strcmp(mode, "nogame")) {
        expect("global value", cfg("vram-mb"), "1024");
        expect("missing game file", cfg("pool"), NULL);
    } else if (!strcmp(mode, "legacy")) {
        expect("legacy file", cfg("swap-mb"), "256");
        expect("game over legacy", cfg("vram-mb"), "2048");
    } else if (!strcmp(mode, "env")) {
        setenv("WINEDLLOVERRIDES", "xinput1_3=n,b", 1);
        madeira_cfg_env_set("WINEDLLOVERRIDES", "d3d9=n");
        madeira_cfg_env_set("WINEDLLOVERRIDES", "xinput1_3=b");
        expect("merged twice", getenv("WINEDLLOVERRIDES"), "xinput1_3=n,b;d3d9=n;xinput1_3=b");
        madeira_cfg_env_set("FEX_MULTIBLOCK", "0");
        expect("plain export", getenv("FEX_MULTIBLOCK"), "0");
        setenv("KEEP_ME", "app", 1);
        madeira_cfg_env_set("KEEP_ME", "cfg");

        /* Next launch: the adapter re-sets WINEDLLOVERRIDES, KEEP_ME is re-set by the app. */
        setenv("WINEDLLOVERRIDES", "xinput1_3=n,b", 1);
        setenv("KEEP_ME", "fresh", 1);
        madeira_cfg_env_restore();
        expect("fresh app value kept", getenv("WINEDLLOVERRIDES"), "xinput1_3=n,b");
        expect("cfg-only var removed", getenv("FEX_MULTIBLOCK"), NULL);
        expect("re-set var kept", getenv("KEEP_ME"), "fresh");

        /* A cfg override of a value the app did not re-set is undone. */
        setenv("ONCE", "app", 1);
        madeira_cfg_env_set("ONCE", "cfg");
        madeira_cfg_env_restore();
        expect("restored prior", getenv("ONCE"), "app");

        /* Empty value clears, no stray ';'. */
        madeira_cfg_env_set("WINEDLLOVERRIDES", "");
        expect("empty clears", getenv("WINEDLLOVERRIDES"), "");
        madeira_cfg_env_restore();
        unsetenv("WINEDLLOVERRIDES");
        madeira_cfg_env_set("WINEDLLOVERRIDES", "d3d9=n");
        expect("no leading ';'", getenv("WINEDLLOVERRIDES"), "d3d9=n");
    }
    printf("%s %s\n", mode, fails ? "FAILED" : "ok");
    return fails ? 1 : 0;
}
'''

with tempfile.TemporaryDirectory(prefix="madeira-game-cfg-") as tmp:
    tmp = Path(tmp)
    (tmp / "c.c").write_text(harness, encoding="utf-8")
    subprocess.run([CC, "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
                    "-I", str(ROOT / "build"), str(tmp / "c.c"), "-o", str(tmp / "c")], check=True)

    docs = tmp / "docs"
    docs.mkdir()
    game = tmp / "Games" / "Some Game"
    game.mkdir(parents=True)
    (game / "iridium.cfg").write_bytes(
        b"\xef\xbb\xbf# per-game\r\nvram-mb = 1500\r\nvram-mb = 2048\r\npool=big\r\nenv.MADEIRA_FASTSYNC = 0\r\n")

    def run(mode, global_cfg=None, legacy=None, game_cfg=str(game / "iridium.cfg")):
        for p in docs.iterdir():
            p.unlink()
        if global_cfg is not None:
            (docs / "madeira.cfg").write_text(global_cfg)
        for k, v in (legacy or {}).items():
            (docs / f"madeira-{k}.txt").write_text(v)
        env = {k: v for k, v in os.environ.items() if k not in ("MADEIRA_GAME_CFG", "WINEDLLOVERRIDES")}
        env["MADEIRA_DOCS_DIR"] = str(docs)
        if game_cfg:
            env["MADEIRA_GAME_CFG"] = game_cfg
        r = subprocess.run([str(tmp / "c"), mode], env=env, capture_output=True, text=True)
        print(r.stdout, end="")
        assert r.returncode == 0, mode

    run("layer", global_cfg="swap-mb = 512\nvram-mb = 1024\ninproc-sync = 0\n")
    run("nogame", global_cfg="vram-mb = 1024\n", game_cfg=str(tmp / "missing.cfg"))
    run("nogame", global_cfg="vram-mb = 1024\n", game_cfg=None)
    run("legacy", legacy={"swap-mb": "256\n", "vram-mb": "1024\n"})
    run("env", global_cfg="")

print("PASS per-game cfg layering and WINEDLLOVERRIDES merge")
