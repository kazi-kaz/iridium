#!/usr/bin/env python3
"""Native ARM64 DLL entry points run in the module's JIT-pool copy.

Every call into a native ARM64 module lands in its JIT-pool copy, which has its
own .data and .bss. The loader called entry points and TLS callbacks at their
original-view address, and the native ARM64 ntdll had no forward translator.
xtajit.dll's CRT startup ran in the original view (UNDERTALE, i386,
2026-10-11: [x18-emul3] pc=libwow64fex+0x10a8), so the pool copy's globals kept
zeros: FEX's WoW64 thread map had max_load_factor 0, the first
BTCpuThreadInit threw std::overflow_error from __next_prime, and the process
ended with 0xfe63002c (FEX's RaiseException stub, WinAPI/Misc.cpp:44).

Checks the native ARM64 ntdll exports and defines the forward hook the Unix
side already installs, then compiles the production call_dll_entry_point,
extracted from wine/dlls/ntdll/loader.c, against a stub translator: a module
with a pool copy is entered there, one without (identity) or with a NULL hook
result keeps its address. No Wine, SDK or device needed.
"""
import os, re, shutil, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CC = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")

def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8").replace("\r\n", "\n")

spec = read("wine/dlls/ntdll/ntdll.spec")
assert re.search(r"^@ extern -private -arch=arm64,arm64ec p_ios_jit_translate_addr$", spec, re.M), \
    "the native ARM64 ntdll must export p_ios_jit_translate_addr for the Unix side to fill"

sig = read("wine/dlls/ntdll/signal_arm64.c")
block = sig[sig.index("#ifndef __arm64ec__\nvoid *p_ios_jit_reverse_translate_addr"):]
block = block[:block.index("#else")]
assert "void *p_ios_jit_translate_addr = NULL;" in block
fwd = block[block.index("void *__attribute__((naked)) xlate_ios_jit( void *ptr )"):]
for needle in ("cbz x0, 1f", "adrp x16, p_ios_jit_translate_addr",
               "ldr x16, [x16, #:lo12:p_ios_jit_translate_addr]", "cbz x16, 1f", "br x16"):
    assert needle in fwd, needle

loader = read("wine/dlls/ntdll/loader.c")
generic = loader.index("static inline BOOL call_dll_entry_point( DLLENTRYPROC proc, void *module,")
end = loader.index("\n}\n", generic) + 3
helper = loader[generic:end]
guard = "#if defined(__aarch64__) && !defined(__arm64ec__)"
assert guard in helper, "translation is limited to the native ARM64 ntdll"
assert helper.index("xlate_ios_jit") > helper.index(guard)
assert helper.rstrip().endswith("return proc( module, reason, reserved );\n}"), "entry still called once"

# Both users of call_dll_entry_point go through the helper.
assert "call_dll_entry_point( (DLLENTRYPROC)*callback, module, reason, NULL );" in loader
assert "retv = call_dll_entry_point( entry, module, reason, lpReserved );" in loader

harness = r'''
#include <stdio.h>
typedef int BOOL;
typedef unsigned int UINT;
typedef BOOL (*DLLENTRYPROC)( void *, UINT, void * );
#define ERR(...) fprintf(stderr, __VA_ARGS__)

static int where;        /* 1 = original view ran, 2 = pool copy ran */
static int mode;         /* 0 = pool copy exists, 1 = identity, 2 = NULL */
static BOOL original_entry( void *m, UINT r, void *x ) { (void)m; (void)r; (void)x; where = 1; return 1; }
static BOOL pool_entry( void *m, UINT r, void *x ) { (void)m; (void)r; (void)x; where = 2; return 1; }
void *xlate_ios_jit( void *ptr )
{
    if (mode == 2) return NULL;
    if (mode == 0 && ptr == (void *)original_entry) return (void *)pool_entry;
    return ptr;
}
''' + helper.replace(guard, "#if 1") + r'''
int main(void)
{
    int fails = 0;
    mode = 0; where = 0;
    call_dll_entry_point( original_entry, (void *)0x1000, 1, NULL );
    if (where != 2) { printf("FAIL entry with a pool copy did not run there\n"); fails++; }
    mode = 1; where = 0;
    call_dll_entry_point( original_entry, (void *)0x1000, 1, NULL );
    if (where != 1) { printf("FAIL identity translation changed the entry\n"); fails++; }
    mode = 2; where = 0;
    call_dll_entry_point( original_entry, (void *)0x1000, 1, NULL );
    if (where != 1) { printf("FAIL a NULL translation replaced the entry\n"); fails++; }
    printf(fails ? "FAILED\n" : "ok\n");
    return fails != 0;
}
'''

with tempfile.TemporaryDirectory(prefix="madeira-entry-pool-") as tmp:
    tmp = Path(tmp)
    (tmp / "c.c").write_text(harness, encoding="utf-8")
    subprocess.run([CC, "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
                    str(tmp / "c.c"), "-o", str(tmp / "c")], check=True)
    r = subprocess.run([str(tmp / "c")], capture_output=True, text=True)
    print(r.stdout, end="")
    assert r.returncode == 0

print("PASS native ARM64 entry points run in the JIT-pool copy")
