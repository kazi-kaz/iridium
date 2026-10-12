#!/usr/bin/env python3
"""A reused JIT-pool range retires the dead copy FEX still has there.

When a pseudo-process exits, its pool copies are tombstoned in virtual_ios.c's
table and their ranges go to the freelist. FEX's alias table, filled through
ios_jit_alias_pushback_cb, is not told: it only retires an entry when a new
image overlaps that entry's PE range. A new image placed in a reused range
therefore sat behind the dead entry, and FEX's reverse lookup (pool address ->
PE address) returned the dead module (Madeira Dock, 2026-10-11: winhttp.dll's
copy reused a finished winedevice's ntoskrnl.exe range; Valve's client called a
winhttp export, FEX redirected to ntoskrnl, NoExec, the process exited 1).

Compiles the production stale-alias block from build/ntdll-unix/virtual_ios.c
against a model of FEX's documented add/reverse semantics (retire PE overlaps,
reuse a retired slot, first match wins) and checks: the new image wins after
reuse; with the switch off the old failure reproduces; an image that is live
again at the dead PE address is not retired; reclaim records every tombstoned
copy and add_mapping retires before it pushes. No Wine, SDK or device needed.
"""
import os, shutil, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CC = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")

source = (ROOT / "build/ntdll-unix/virtual_ios.c").read_text(encoding="utf-8").replace("\r\n", "\n")
start = source.index("#define IOS_STALE_ALIAS_MAX 512")
block = source[start:source.index("void ios_jit_add_mapping(void *pe_base, void *jit_base, size_t size)")]

add = source[source.index("void ios_jit_add_mapping(void *pe_base, void *jit_base, size_t size)"):]
add = add[:add.index("\n}\n")]
assert add.index("ios_stale_alias_retire( jit_base, size );") < add.index("ios_jit_alias_pushback_cb((unsigned long long)(uintptr_t)pe_base,"), \
    "dead aliases must be retired before the new copy is pushed"
reclaim = source[source.index("void ios_jit_reclaim_process( void *peb )"):]
reclaim = reclaim[:reclaim.index("\n}\n")]
assert reclaim.index("ios_stale_alias_record( ios_jit_mappings[j].pe_base, jb, ios_jit_mappings[j].size );") < \
    reclaim.index("ios_jit_mappings[j].pe_base = NULL;"), "record each copy before it is tombstoned"

harness = r'''
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define dprintf(fd, ...) fprintf(stderr, __VA_ARGS__)
static struct { void *pe_base; void *jit_base; size_t size; } ios_jit_mappings[16];
static int ios_jit_mapping_count;
static void (*ios_jit_alias_pushback_cb)(unsigned long long, unsigned long long, unsigned long long);

/* Model of FEX's IosAliasEntries add and reverse lookup. */
static struct { uint64_t pe, jit, size; } fex[64];
static int fex_count;
static void fex_add( unsigned long long pe, unsigned long long jit, unsigned long long size )
{
    int i;
    for (i = 0; i < fex_count; i++)
        if (fex[i].pe == pe && fex[i].jit == jit && fex[i].size == size) return;
    for (i = 0; i < fex_count; i++)
        if (fex[i].size && fex[i].pe < pe + size && pe < fex[i].pe + fex[i].size) fex[i].size = 0;
    for (i = 0; i < fex_count; i++)
        if (!fex[i].size) { fex[i].pe = pe; fex[i].jit = jit; fex[i].size = size; return; }
    fex[fex_count].pe = pe; fex[fex_count].jit = jit; fex[fex_count].size = size; fex_count++;
}
static int low_pushes;
static void counting_add( unsigned long long pe, unsigned long long jit, unsigned long long size )
{
    if (pe < 0x100000000ull) low_pushes++;
    fex_add( pe, jit, size );
}
static uint64_t fex_reverse( uint64_t a )
{
    int i;
    for (i = 0; i < fex_count; i++)
        if (a >= fex[i].jit && a < fex[i].jit + fex[i].size) return fex[i].pe + (a - fex[i].jit);
    return a;
}
''' + block + r'''
static void load( uint64_t pe, uint64_t jit, size_t size )
{
    ios_jit_mappings[ios_jit_mapping_count].pe_base = (void *)pe;
    ios_jit_mappings[ios_jit_mapping_count].jit_base = (void *)jit;
    ios_jit_mappings[ios_jit_mapping_count].size = size;
    ios_jit_mapping_count++;
    ios_stale_alias_retire( (void *)jit, size );   /* as in ios_jit_add_mapping */
    fex_add( pe, jit, size );
}
static void unload( int i )   /* as in ios_jit_reclaim_process */
{
    ios_stale_alias_record( ios_jit_mappings[i].pe_base, ios_jit_mappings[i].jit_base, ios_jit_mappings[i].size );
    ios_jit_mappings[i].size = 0;
    ios_jit_mappings[i].pe_base = NULL;
}
static void reset( void )
{
    memset( fex, 0, sizeof(fex) ); fex_count = 0;
    memset( ios_jit_mappings, 0, sizeof(ios_jit_mappings) ); ios_jit_mapping_count = 0;
    ios_stale_alias_count = ios_stale_alias_next = 0;
}
int main( int argc, char **argv )
{
    int fails = 0;
    ios_jit_alias_pushback_cb = fex_add;
    if (argc > 1) { setenv( "MADEIRA_NO_FEX_ALIAS_RETIRE", "1", 1 ); }

    reset();
    load( 0xbb49c0000ull, 0x32b9dc000ull, 0x120000 );      /* ntoskrnl.exe, winedevice */
    unload( 0 );                                            /* winedevice exits */
    load( 0xbb27c0000ull, 0x32b9dc000ull, 0xe0000 );       /* winhttp.dll reuses the range */
    uint64_t pe = fex_reverse( 0x32ba25cd6ull );
    if (argc > 1)
    {
        if (pe != 0xbb4a09cd6ull) { printf( "FAIL control: dead entry did not win (%llx)\n", (unsigned long long)pe ); fails++; }
        return fails;
    }
    if (pe != 0xbb2809cd6ull) { printf( "FAIL reused range reversed to %llx\n", (unsigned long long)pe ); fails++; }
    if (fex_reverse( 0xbb49c0000ull ) != 0xbb49c0000ull) { printf( "FAIL retired entry is not identity\n" ); fails++; }
    if (ios_stale_alias_count) { printf( "FAIL stale record kept\n" ); fails++; }

    /* An image live again at the dead PE address keeps its entry. */
    reset();
    load( 0xbb49c0000ull, 0x32b000000ull, 0x10000 );       /* A */
    unload( 0 );
    load( 0xbb49c0000ull, 0x32c000000ull, 0x10000 );       /* B at A's PE address, new range */
    load( 0xbb5000000ull, 0x32b000000ull, 0x10000 );       /* C reuses A's range */
    if (fex_reverse( 0x32c000010ull ) != 0xbb49c0010ull) { printf( "FAIL live image lost its entry\n" ); fails++; }
    if (fex_reverse( 0x32b000010ull ) != 0xbb5000010ull) { printf( "FAIL C does not win its range\n" ); fails++; }

    /* Below 4 GB is FEX's sub-floor table: never pushed as a retirement. */
    reset();
    load( 0x80000000ull, 0x32b000000ull, 0x10000 );
    unload( 0 );
    ios_jit_alias_pushback_cb = counting_add;
    load( 0xbb5000000ull, 0x32b000000ull, 0x10000 );
    if (low_pushes) { printf( "FAIL sub-floor base pushed as a retirement\n" ); fails++; }
    return fails;
}
'''

with tempfile.TemporaryDirectory() as tmp:
    src = Path(tmp) / "check.c"
    exe = Path(tmp) / "check"
    src.write_text(harness)
    subprocess.run([CC, "-std=gnu11", "-Wall", "-Werror", "-Wno-unused-function", "-o", str(exe), str(src), "-lpthread"],
                   check=True)
    subprocess.run([str(exe)], check=True)
    control = subprocess.run([str(exe), "off"])
    assert control.returncode == 0, "with the switch off the dead entry must still win (the reproduced failure)"
print("PASS fex-alias-retire")
