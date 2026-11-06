#!/usr/bin/env python3
"""MADEIRA_NO_PROBES stops the two thread-suspending samplers and nothing else.

The task-wide thread sampler (a burst of four passes every 20 s) and the [wprof]
burst profiler thread_suspend the game's threads. With MADEIRA_NO_PROBES set
(Settings > Quiet Diagnostics, or quiet-diagnostics = on in a game's iridium.cfg)
they are not started. The [xp] probe only reads counters and must keep running,
because it is how the CPU split of a run is read. With the variable unset
nothing changes. Checks the source; no Wine, SDK or device needed.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
src = (ROOT / "build/ntdll-unix/server_ios.c").read_text(encoding="utf-8")

arm = src[src.index("if (__sync_bool_compare_and_swap(&ios_ts_armed, 0, 1))"):]
arm = arm[:arm.index("if (!getenv(\"MADEIRA_QUIET\"))")]

sampler = arm.index("ios_thread_sampler_main(); }")
xprobe = arm.index("ios_xprobe_main(); }")
wprof = arm.index("ios_wprof_main(); }")

# Each suspending sampler is only reached through the NO_PROBES test.
head = arm[:sampler]
assert 'if (getenv( "MADEIRA_NO_PROBES" ))' in head, "the sampler start is guarded"
assert head.count("else") >= 1 and "dispatch_async" in arm[head.rindex("else"):sampler + 40]
wprof_guard = arm[xprobe:wprof]
assert '!getenv( "MADEIRA_NO_PROBES" )' in wprof_guard, "the [wprof] start is guarded"

# The [xp] probe is not behind any NO_PROBES test: no condition between the
# sampler start and its own dispatch other than the shared else branch.
between = arm[sampler:xprobe]
assert "NO_PROBES" not in between, "the [xp] probe is not guarded"
assert "[thread-sample] samplers off" in arm, "a quiet launch says so in the log"
print("quiet-probes ok")
