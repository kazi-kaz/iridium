#!/usr/bin/env python3
"""A module's TLS slot reaches its JIT-pool copy, not only the original view.

Builtin ARM64EC and native ARM64 images run from a pool copy with its own
.data, so their TLS
code reads _tls_index there. alloc_tls_slot (wine/dlls/ntdll/loader.c) used to
store the slot only in the original view, leaving the copy at 0 and sending
those modules' thread_locals into the main executable's TLS block (Kincaid:
_Init_thread_epoch zeroed, an unbuilt static map used, fault at 0x8).

Compiles the production helper, extracted from the source, against a stub
translator and checks: the pool copy receives the slot; a module without a pool
copy (identity translation) and a NULL translation change nothing; and the call
follows the original store inside alloc_tls_slot. No Wine, SDK or device needed.
"""
import os, re, shutil, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CC = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")

loader = (ROOT / "wine/dlls/ntdll/loader.c").read_text(encoding="utf-8").replace("\r\n", "\n")

start = loader.index("static void ios_sync_tls_index_to_pool(")
end = loader.index("\n}\n", start) + 3
helper = loader[start:end]

alloc = loader[loader.index("static BOOL alloc_tls_slot("):]
alloc = alloc[:alloc.index("\n}\n")]
store = alloc.index("*(DWORD *)dir->AddressOfIndex = i;")
sync = alloc.index("ios_sync_tls_index_to_pool( (DWORD *)dir->AddressOfIndex, i, mod->BaseDllName.Buffer );")
assert store < sync, "the pool copy must be synced after the original store"
assert "tls_dirs[i] = *dir;" in alloc[sync:], "sync sits before the slot is published"
assert re.search(r"#if defined\(__arm64ec__\) \|\| defined\(__aarch64__\)\s*\n\s*ios_sync_tls_index_to_pool", alloc), \
    "sync runs in the ARM64EC and native ARM64 ntdlls (both have xlate_ios_jit)"

harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef unsigned int DWORD;
typedef unsigned int ULONG;
typedef unsigned short WCHAR;
static const char *debugstr_w( const WCHAR *w ) { (void)w; return "L\"xtajit64.dll\""; }
#define ERR(...) fprintf(stderr, __VA_ARGS__)

static DWORD original_view, pool_copy;
static int mode;   /* 0 = pool copy exists, 1 = identity (no copy), 2 = NULL */
void *xlate_ios_jit( void *ptr )
{
    if (ptr != &original_view) return ptr;
    if (mode == 0) return &pool_copy;
    if (mode == 1) return ptr;
    return NULL;
}
''' + helper.replace("%lu", "%u") + r'''
int main(void)
{
    int fails = 0;
    /* Pool copy taken before the slot was assigned: holds the file value 0. */
    mode = 0; original_view = 1; pool_copy = 0;
    ios_sync_tls_index_to_pool( &original_view, 1, NULL );
    if (pool_copy != 1 || original_view != 1) { printf("FAIL pool copy not synced (pool=%u)\n", pool_copy); fails++; }

    mode = 1; original_view = 2; pool_copy = 7;
    ios_sync_tls_index_to_pool( &original_view, 2, NULL );
    if (original_view != 2 || pool_copy != 7) { printf("FAIL identity translation changed memory\n"); fails++; }

    mode = 2; original_view = 3; pool_copy = 7;
    ios_sync_tls_index_to_pool( &original_view, 3, NULL );
    if (original_view != 3 || pool_copy != 7) { printf("FAIL NULL translation changed memory\n"); fails++; }

    printf(fails ? "FAILED\n" : "ok\n");
    return fails != 0;
}
'''

with tempfile.TemporaryDirectory(prefix="madeira-tls-index-") as tmp:
    tmp = Path(tmp)
    (tmp / "c.c").write_text(harness, encoding="utf-8")
    subprocess.run([CC, "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
                    str(tmp / "c.c"), "-o", str(tmp / "c")], check=True)
    r = subprocess.run([str(tmp / "c")], capture_output=True, text=True)
    print(r.stdout, end="")
    assert r.returncode == 0

print("PASS TLS slot published to the JIT-pool copy")
