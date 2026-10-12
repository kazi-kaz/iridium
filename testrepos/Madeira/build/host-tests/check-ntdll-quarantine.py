#!/usr/bin/env python3
"""A reclaimed child ntdll copy is kept out of the pool freelist.

2026-10-12, MX Bikes and Pseudoregalia: the range of an exited child's ntdll
copy went back on the freelist, and the next image placed there (wevtsvc.dll, a
winedevice driver, nsi.dll) faulted in pages that had been the dead child's
ntdll .data, in two sessions. The copy now stays quarantined unless
MADEIRA_POOL_REUSE_NTDLL=1.

Checks the production reclaim in build/ntdll-unix/virtual_ios.c: the child
ntdll copy names its module, reclaim detects that module before it tombstones
the mapping, and a range holding it is counted as quarantined instead of being
added to the freelist. No Wine, SDK or device needed.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / "build/ntdll-unix/virtual_ios.c").read_text(encoding="utf-8").replace("\r\n", "\n")

reclaim = source[source.index("void ios_jit_reclaim_process( void *peb )"):]
reclaim = reclaim[:reclaim.index("\n}\n")]
detect = reclaim.index("if (ios_child_ntdll_pe && ios_jit_mappings[j].pe_base == ios_child_ntdll_pe)")
assert detect < reclaim.index("ios_jit_mappings[j].pe_base = NULL;"), "detect ntdll before the mapping is tombstoned"
assert reclaim.index("int holds_ntdll = 0;") < detect, "reset per ledger range"
quarantine = reclaim.index("if (holds_ntdll && !reuse_ntdll)")
freelist = reclaim.index("ios_pool_freelist[ios_pool_free_count].off = off;")
assert quarantine < freelist and "else if (ios_pool_free_count < IOS_POOL_FREE_MAX)" in reclaim[quarantine:freelist], \
    "a quarantined range must not reach the freelist"
assert 'getenv( "MADEIRA_POOL_REUSE_NTDLL" )' in reclaim
# The ledger entry is still removed, so the range is not reclaimed twice.
assert reclaim.index("ios_pool_ledger[i] = ios_pool_ledger[--ios_pool_ledger_count];") > freelist

child = source[source.index('dprintf(2, "[child-ntdll] JIT pool exhausted'):]
child = child[:child.index('dprintf(2, "[child-ntdll] copied')]
assert child.index("ios_child_ntdll_pe = m->pe_base;") < child.index("memcpy(rw_dest, src, m->size);")
print("PASS ntdll-quarantine")
