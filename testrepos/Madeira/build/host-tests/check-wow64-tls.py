#!/usr/bin/env python3
"""A WoW64 thread's 64-bit TLS block exists before init_wow64() takes over.

The 64-bit ntdll's init_wow64() never returns, so loader_init()'s ordinary
alloc_thread_tls() never ran for WoW64 threads. alloc_tls_slot() skips threads
whose ThreadLocalStoragePointer is NULL, so the CPU backend's own TLS
(libwow64fex.dll has a TLS directory) was never allocated, and its first
thread_local access read NULL[index] (UNDERTALE, i386, 2026-10-11).
Checks wine/dlls/ntdll/loader.c textually; no Wine runs.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
source = (root / 'wine/dlls/ntdll/loader.c').read_text()
start = source.index('void loader_init( CONTEXT *context, void **entry )')
body = source[start:source.index('\n}\n', start)]

calls = [m.start() for m in re.finditer(r'init_wow64\( context \)', body)]
assert len(calls) == 2, calls
for call in calls:
    before = body[:call]
    guard = before.rindex('#ifdef _WIN64')
    tls = before.rfind('alloc_thread_tls()')
    assert tls > guard, 'alloc_thread_tls() must run, under _WIN64, right before init_wow64()'
    assert '#endif' not in body[guard:tls], 'the TLS allocation must stay inside the _WIN64 block'
    # nothing else that could return or skip the allocation sits between them
    assert body[tls:call].count('return') == 0
print('PASS: WoW64 threads get their 64-bit TLS block before init_wow64()')
