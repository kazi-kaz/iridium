#!/usr/bin/env python3
"""A 32-bit-truncated stack pointer is recovered from the guest RSP.

2026-10-12, MX Bikes: the game loads a stack address into a 32-bit slot
(`mov ecx,[rax]`) and the callee dereferences it. rcx was 0x3083d320 for the
stack address 0x13083d320, in two runs, and iOS has no memory below 4 GB, so
the read faulted. ios_trunc_ptr_candidate() rebuilds the address from the
guest RSP.

Compiles the production function (the text between the ios-trunc-ptr markers
in build/ntdll-unix/signal_arm64_ios.c) with the host C compiler and runs it
against the values from the two crash logs, plus the cases it must refuse.
Also checks that the fault path calls it only for a JIT-pool PC.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / "build/ntdll-unix/signal_arm64_ios.c").read_text(encoding="utf-8").replace("\r\n", "\n")

begin = source.index("/* ios-trunc-ptr:begin")
end = source.index("/* ios-trunc-ptr:end */")
function = source[begin:end]
assert "ios_trunc_ptr_candidate" in function

harness = r'''
#include <stdint.h>
#include <stdio.h>
''' + function + r'''
static int failures;
#define CHECK(rsp, addr, want) do { \
    uint64_t got = ios_trunc_ptr_candidate((rsp), (addr)); \
    if (got != (want)) { printf("FAIL rsp=%#llx addr=%#llx got=%#llx want=%#llx\n", \
        (unsigned long long)(rsp), (unsigned long long)(addr), \
        (unsigned long long)got, (unsigned long long)(want)); failures++; } } while (0)

int main(void)
{
    /* The two crash logs: same function, different stack placement. */
    CHECK(0x13083d028ull, 0x3083d320ull, 0x13083d320ull);
    CHECK(0xb8508d028ull, 0x8508d320ull, 0xb8508d320ull);
    /* A 4 GB boundary between RSP and the object, in both directions. */
    CHECK(0x1ffffff00ull, 0x00000100ull + 0x10000ull, 0x200010100ull);
    CHECK(0x200000100ull, 0xffffff00ull, 0x1ffffff00ull);
    /* Refused: null-ish, already high, no high bits in RSP, far from RSP. */
    CHECK(0x13083d028ull, 0x10ull, 0);
    CHECK(0x13083d028ull, 0xffffull, 0);
    CHECK(0x13083d028ull, 0x13083d320ull, 0);
    CHECK(0x13083d028ull, 0x4083d320ull, 0);      /* ~256 MB above RSP */
    CHECK(0x13083d028ull, 0x3073d320ull, 0);      /* ~1 MB below RSP */
    CHECK(0x7ffe0000ull, 0x7ffe0320ull, 0);       /* RSP is not a host address */
    CHECK(0, 0x3083d320ull, 0);
    if (failures) return 1;
    puts("ok");
    return 0;
}
'''

with tempfile.TemporaryDirectory() as tmp:
    src = Path(tmp) / "trunc.c"
    exe = Path(tmp) / "trunc"
    src.write_text(harness)
    subprocess.run(["cc", "-std=c99", "-Wall", "-Werror", "-o", str(exe), str(src)], check=True)
    run = subprocess.run([str(exe)], capture_output=True, text=True)
    if run.returncode != 0:
        print(run.stdout + run.stderr)
        sys.exit(1)

# The Mach gate and the service function both reach it, and the service
# function only acts on a PC inside the JIT pool (x23 is RSP only in translated code).
service = source[source.index("static int ios_subfloor_service( ucontext_t *ctx, void *fault_addr, const char *via )\n{"):]
service = service[:service.index("\n}\n")]
assert "ios_trunc_ptr_candidate( REGn_sig( 23, ctx ), addr )" in service
pool_check = service.index("tp_pc >= tp_rx && tp_pc < tp_rx + ios_jit_pool_size_global")
assert pool_check < service.index("ios_trunc_ptr_candidate( REGn_sig( 23, ctx ), addr )")
assert "ios_trunc_ptr_candidate( (uint64_t)state.__x[23]," in source
assert "if (sf_real || sf_low || sf_trunc)" in source
print("PASS trunc-ptr")
