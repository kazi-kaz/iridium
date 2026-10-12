#!/usr/bin/env python3
"""opengl32's x18 STORES are patched; every other image is patched as before.

Wine's opengl32 thunks write NtCurrentTeb() into each params struct
(`str x18, [sp, #n]`, 3,102 sites). On iOS x18 is not the TEB, so every GL
call reached the unix side with teb == NULL. The x18 patcher (from
c-gow/Madeira 40276fe and 69c5f8a) now also rewrites 64-bit STR/STUR/STP of
x18, only in the image named opengl32.dll, and moves SP-based offsets past the
trampoline's 16-byte scratch push.

Compiles the production instruction classifier, register replacement and SP
fixup from build/ntdll-unix/virtual_ios.c and checks real encodings. No Wine,
SDK or device needed.
"""
import os, shutil, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CC = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")

source = (ROOT / "build/ntdll-unix/virtual_ios.c").read_text(encoding="utf-8").replace("\r\n", "\n")
start = source.index("#define X18_ROLE_NONE 0")
end = source.index("/* Patch all x18 references in a PE .text section.")
block = source[start:end]
stores = source[source.index("int ios_x18_patch_stores( const void *image, size_t image_size )"):]
stores = stores[:stores.index("\n}\n")]
assert '!strcasecmp( name, "opengl32.dll" )' in stores, "only opengl32 gets its stores patched"
patch = source[source.index("int ios_jit_patch_x18(char *text_rw"):]
patch = patch[:patch.index("\n}\n")]
assert "if (role == X18_ROLE_RT && !ios_insn_x18_store_sp_fixup( &replaced ))" in patch
assert "*(uint32_t *)(tramp_rw + tramp_off) = replaced;" in patch
for caller in ("tramp_rw, tramp_rx, tramp_alloc, x18_stores);", "ios_x18_patch_stores(m->pe_base, m->size));"):
    assert caller in source, caller

harness = r'''
#include <stdint.h>
#include <stdio.h>
typedef int BOOL;
#define TRUE 1
#define FALSE 0
''' + block + r'''
static int fails;
static void expect( const char *what, uint32_t got, uint32_t want )
{
    if (got != want) { printf( "FAIL %s: got %08x want %08x\n", what, got, want ); fails++; }
}
static uint32_t patched( uint32_t insn, int scratch, int *ok )
{
    int role = ios_insn_x18_role( insn, 1 );
    uint32_t r = ios_insn_replace_x18( insn, role, scratch );
    *ok = role != X18_ROLE_RT || ios_insn_x18_store_sp_fixup( &r );
    return r;
}
int main( void )
{
    int ok;
    /* str x18, [sp, #16] */
    expect( "str role (opengl32)", ios_insn_x18_role( 0xF9000BF2, 1 ), X18_ROLE_RT );
    expect( "str role (other image)", ios_insn_x18_role( 0xF9000BF2, 0 ), X18_ROLE_NONE );
    expect( "str x17, [sp, #32]", patched( 0xF9000BF2, 17, &ok ), 0xF90013F1 ); expect( "str ok", ok, 1 );
    /* stur x18, [x0, #-8]: not SP-based, offset unchanged */
    expect( "stur x17, [x0, #-8]", patched( 0xF81F8012, 17, &ok ), 0xF81F8011 ); expect( "stur ok", ok, 1 );
    /* stur x18, [sp, #-16] -> [sp, #0] */
    expect( "stur x17, [sp, #0]", patched( 0xF81F03F2, 17, &ok ), 0xF80003F1 ); expect( "stur sp ok", ok, 1 );
    /* stp x18, x19, [sp, #16] -> stp x17, x19, [sp, #32] */
    expect( "stp x17, x19, [sp, #32]", patched( 0xA9014FF2, 17, &ok ), 0xA9024FF1 ); expect( "stp ok", ok, 1 );
    /* an offset that no longer encodes is left unpatched */
    patched( 0xF93FFFF2, 17, &ok ); expect( "str [sp, #max] refused", ok, 0 );
    /* loads INTO x18 are never patched; uses of x18 as a base still are */
    expect( "ldr x18, [x0]", ios_insn_x18_role( 0xF9400012, 1 ), X18_ROLE_NONE );
    expect( "str x0, [x18, #8]", ios_insn_x18_role( 0xF9000640, 0 ), X18_ROLE_RN );
    expect( "str x0, [x18, #8] (opengl32)", ios_insn_x18_role( 0xF9000640, 1 ), X18_ROLE_RN );
    /* a 32-bit store of w18 is not a TEB store */
    expect( "str w18, [sp, #8]", ios_insn_x18_role( 0xB9000BF2, 1 ), X18_ROLE_NONE );
    return fails;
}
'''

with tempfile.TemporaryDirectory() as tmp:
    src = Path(tmp) / "check.c"
    exe = Path(tmp) / "check"
    src.write_text(harness)
    subprocess.run([CC, "-std=gnu11", "-Wall", "-Werror", "-Wno-unused-function", "-Wno-tautological-compare", "-o", str(exe), str(src)], check=True)
    subprocess.run([str(exe)], check=True)
print("PASS x18-store")
