#!/usr/bin/env python3
"""Exited threads give back their exception-registry row and x18 trampoline slot.

The registry (512 rows) and the trampoline slots (256) were never recycled.
Ren'Py starts a thread per sound, so after ~70 minutes the 512th thread went
unregistered, the lock census took it for the dead owner of its recycled TEB
and released its FEX lock, and the game hung (The Tribe, 2026-11-03). Threads
past the 256th were also all handed trampoline slot 0, the first thread's.

Compiles the production ios_thread_port_dead, ios_thread_registry_reuse_dead
and ios_alloc_thread_trampoline from build/ntdll-unix/signal_arm64_ios.c
against stubbed Mach calls, and checks the call sites textually. No Wine runs.
Needs python3 and a C compiler (AddressSanitizer/UBSan when available).
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]  # testrepos/Madeira
source = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text()
virtual = (root / 'build/ntdll-unix/virtual_ios.c').read_text()


def function(text, signature):
    start = text.index(signature)
    return text[start:text.index('\n}', start) + 2] + '\n'


# registration: same-TEB reuse first, then append, then reuse when full
setup = function(source, 'static void ios_setup_mach_exception_handler(')
assert 'ios_thread_registry_reuse_dead( reg_count, teb, pe_thread )' in setup
assert 'ios_thread_registry_reuse_dead( IOS_MAX_WINE_THREADS, 0, pe_thread )' in setup
assert setup.index('reuse_dead( reg_count, teb') < setup.index('__sync_fetch_and_add(&ios_thread_count, 1)')
# the real port is stored last, after teb/trampoline
fill = setup[setup.index('ios_thread_registry[idx].teb = teb;'):]
assert fill.index('ios_thread_registry[idx].trampoline = trampoline;') < fill.index('ios_thread_registry[idx].mach_thread = pe_thread;')
# trampoline allocation goes through the reusing allocator
assert 'ios_my_slot = ios_alloc_thread_trampoline( pthread_mach_thread_np( pthread_self() ) );' in source
alloc = function(virtual, 'int ios_jit_alloc_trampoline_slot(void)')
assert 'return -1;' in alloc and 'return 0;  /* fallback to slot 0 */' not in alloc
assert re.search(r'#define IOS_JIT_MAX_SLOTS 256\b', virtual)
assert 'static thread_t ios_tramp_owner[256];' in source

define = re.search(r'#define IOS_THREAD_ROW_CLAIMED [^\n]+', source).group(0)

code = r'''
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
typedef unsigned int thread_t;
typedef int kern_return_t;
typedef unsigned int mach_msg_type_number_t;
typedef int *thread_info_t;
struct thread_basic_info { int dummy[10]; };
#define THREAD_BASIC_INFO 3
#define THREAD_BASIC_INFO_COUNT 10
#define KERN_SUCCESS 0
#define KERN_INVALID_ARGUMENT 4
#define KERN_TERMINATED 37
#define MACH_SEND_INVALID_DEST 0x10000003
#define ERR(...) ((void)0)
#define IOS_MAX_WINE_THREADS 512
struct ios_thread_entry { thread_t mach_thread; uintptr_t teb; void *trampoline; };
static struct ios_thread_entry ios_thread_registry[IOS_MAX_WINE_THREADS];
static unsigned char dead[100000];
static int alive_query_status = KERN_SUCCESS;
static kern_return_t thread_info( thread_t port, int flavor, thread_info_t out, mach_msg_type_number_t *n )
{
    (void)flavor; (void)out; (void)n;
    if (port == (thread_t)~0u) return MACH_SEND_INVALID_DEST;
    if (port < sizeof(dead) && dead[port]) return port & 1 ? MACH_SEND_INVALID_DEST : KERN_INVALID_ARGUMENT;
    return alive_query_status;
}
static int next_fresh_slot, slot_limit = 256;
static int ios_jit_alloc_trampoline_slot(void) { return next_fresh_slot < slot_limit ? next_fresh_slot++ : -1; }
static int ios_jit_trampoline_slot_limit(void) { return slot_limit; }
static thread_t ios_tramp_owner[256];
'''
code += define + '\n'
code += function(source, 'static int ios_thread_port_dead(')
code += function(source, 'static int ios_thread_registry_reuse_dead(')
code += function(source, 'static int ios_alloc_thread_trampoline(')
code += r'''
#define FAIL(...) do { fprintf( stderr, __VA_ARGS__ ); return 1; } while (0)
int main( void )
{
    int i, row;
    /* full registry: row i = port 1000+i, teb 0x71ff000000 + i*0x10000 */
    for (i = 0; i < IOS_MAX_WINE_THREADS; i++)
    {
        ios_thread_registry[i].mach_thread = 1000 + i;
        ios_thread_registry[i].teb = 0x71ff000000ull + i * 0x10000ull;
    }
    /* nobody dead: no row */
    if (ios_thread_registry_reuse_dead( IOS_MAX_WINE_THREADS, 0, 5000 ) != -1) FAIL( "live row taken\n" );
    /* any query result other than the dead ones counts as alive */
    alive_query_status = 5; dead[1000 + 7] = 0;
    if (ios_thread_registry_reuse_dead( IOS_MAX_WINE_THREADS, 0, 5000 ) != -1) FAIL( "unknown status taken as dead\n" );
    alive_query_status = KERN_SUCCESS;
    /* row 0 is never taken, even if dead */
    dead[1000] = 1;
    if (ios_thread_registry_reuse_dead( IOS_MAX_WINE_THREADS, 0, 5000 ) != -1) FAIL( "row 0 taken\n" );
    /* same-TEB preference: rows 10 and 20 dead, new thread recycles row 20's TEB */
    dead[1010] = 1; dead[1020] = 1;
    row = ios_thread_registry_reuse_dead( IOS_MAX_WINE_THREADS, ios_thread_registry[20].teb, 5001 );
    if (row != 20) FAIL( "same-teb reuse picked row %d\n", row );
    if (ios_thread_registry[20].mach_thread != (thread_t)~0u || ios_thread_registry[20].teb)
        FAIL( "claimed row not marked/cleared\n" );
    /* a claimed row is not taken again */
    if (ios_thread_registry_reuse_dead( IOS_MAX_WINE_THREADS, 0, 5002 ) != 10) FAIL( "claimed row reused or row 10 missed\n" );
    if (ios_thread_registry_reuse_dead( IOS_MAX_WINE_THREADS, 0, 5003 ) != -1) FAIL( "third reuse with no dead rows\n" );
    /* a purged row (port 0, teb 0) can be taken */
    ios_thread_registry[30].mach_thread = 0; ios_thread_registry[30].teb = 0;
    if (ios_thread_registry_reuse_dead( IOS_MAX_WINE_THREADS, 0, 5004 ) != 30) FAIL( "purged row not reused\n" );
    /* the registering thread's own row is never taken */
    dead[1040] = 1;
    if (ios_thread_registry_reuse_dead( IOS_MAX_WINE_THREADS, 0, 1040 ) != -1) FAIL( "own row taken\n" );
    /* 515 short-lived threads, as in the hang: each exits before the next starts */
    memset( ios_thread_registry, 0, sizeof(ios_thread_registry) );
    memset( dead, 0, sizeof(dead) );
    {
        int count = 1, t;
        ios_thread_registry[0].mach_thread = 1; ios_thread_registry[0].teb = 0x71fffe0000ull;
        for (t = 0; t < 2000; t++)
        {
            thread_t port = 2000 + t;
            uintptr_t teb = 0x71fff10000ull + (t % 5) * 0x10000ull;
            row = ios_thread_registry_reuse_dead( count, teb, port );
            if (row < 0)
            {
                if (count < IOS_MAX_WINE_THREADS) row = count++;
                else row = ios_thread_registry_reuse_dead( IOS_MAX_WINE_THREADS, 0, port );
            }
            if (row < 0) FAIL( "thread %d not registered\n", t );
            ios_thread_registry[row].teb = teb;
            ios_thread_registry[row].mach_thread = port;
            dead[port] = 1;   /* exits */
        }
        if (count > 8) FAIL( "registry grew to %d rows for 5 recycled TEBs\n", count );
    }
    /* trampoline slots: 255 fresh (slot 0 is the first thread's), then reuse */
    {
        int s0 = ios_alloc_thread_trampoline( 1 ), s;
        if (s0 != 0) FAIL( "first slot %d\n", s0 );
        for (i = 1; i < 256; i++)
            if ((s = ios_alloc_thread_trampoline( 50000 + i )) != i) FAIL( "fresh slot %d got %d\n", i, s );
        if (ios_alloc_thread_trampoline( 60000 ) != -1) FAIL( "slot handed out with all owners alive\n" );
        dead[1] = 1;   /* slot 0's owner dead: still never reused */
        if (ios_alloc_thread_trampoline( 60001 ) != -1) FAIL( "slot 0 reused\n" );
        dead[50000 + 77] = 1;
        if ((s = ios_alloc_thread_trampoline( 60002 )) != 77) FAIL( "dead owner's slot not reused (%d)\n", s );
        if (ios_tramp_owner[77] != 60002) FAIL( "owner not recorded\n" );
        if (ios_alloc_thread_trampoline( 60003 ) != -1) FAIL( "slot reused twice\n" );
    }
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-thread-slots-') as directory:
    folder = Path(directory)
    src = folder / 'check.c'
    src.write_text(code)
    exe = folder / 'check'
    cc = os.environ.get('CC', 'cc')
    flags = [cc, '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function',
             '-Wno-unused-parameter', '-Wno-unused-variable', '-g', str(src), '-o', str(exe)]
    sanitize = ['-fsanitize=address,undefined', '-fno-sanitize-recover=all']
    if subprocess.run(flags[:1] + sanitize + flags[1:], capture_output=True).returncode != 0:
        r = subprocess.run(flags, capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
    r = subprocess.run([str(exe)], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
print('PASS: exited threads give back registry rows (same TEB first, then any when full) and trampoline slots; row/slot 0 kept')
