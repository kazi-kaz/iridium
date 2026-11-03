#!/usr/bin/env python3
"""cmd.exe /c ver is refused; any other cmd.exe runs. No Wine runs.

CPython 3.9's platform.win32_ver() starts `cmd.exe /c "ver"` on every call and
Ren'Py 8 calls it three times at startup. Each child cost ~50 MB of the 256 MB
JIT pool that is never given back, so the game crashed loading its own DLLs.
Compiles the production ios_image_name_is / ios_wstr_eq_nocase /
cmd_ver_refuse from build/ntdll-unix/process_ios.c and checks the
NtCreateUserProcess call site textually.
Needs python3 and a C compiler (AddressSanitizer/UBSan when available).
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]  # testrepos/Madeira
source = (root / 'build/ntdll-unix/process_ios.c').read_text()


def function(text, signature):
    start = text.index(signature)
    return text[start:text.index('\n}', start) + 2] + '\n'


create = function(source, 'NTSTATUS WINAPI NtCreateUserProcess(')
call = 'if (cmd_ver_refuse( getenv( "MADEIRA_CMD_VER" ), params->ImagePathName.Buffer,'
assert call in create
gate = create[create.index(call):][:700]
assert 'return STATUS_ACCESS_DENIED;' in gate
# refused before anything is set up for the child
assert create.index(call) < create.index('create_startup_info( attr.ObjectName')

code = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef unsigned short WCHAR;
'''
code += function(source, 'static int ios_image_name_is(')
code += function(source, 'static int ios_wstr_eq_nocase(')
code += function(source, 'static int cmd_ver_refuse(')
code += r'''
static WCHAR buf[2][256];
static int w( int slot, const char *s )
{
    int i;
    for (i = 0; s[i]; i++) buf[slot][i] = (unsigned char)s[i];
    return i;
}
static int refused( const char *env, const char *image, const char *cmdline )
{
    int il = w( 0, image ), cl = w( 1, cmdline );
    return cmd_ver_refuse( env, buf[0], il, buf[1], cl );
}
#define CMD "C:\\windows\\system32\\cmd.exe"
#define FAIL(m) do { fputs( m, stderr ); return 1; } while (0)
int main( void )
{
    /* what CPython 3.9's _syscmd_ver runs, with COMSPEC set (subprocess shell=True) */
    if (!refused( NULL, CMD, CMD " /c \"ver\"" )) FAIL( "cmd /c \"ver\" allowed\n" );
    if (!refused( NULL, CMD, CMD " /c \"command /c ver\"" )) FAIL( "command /c ver allowed\n" );
    if (!refused( NULL, CMD, CMD " /c \"cmd /c ver\"" )) FAIL( "cmd /c ver fallback allowed\n" );
    if (!refused( "", CMD, "\"" CMD "\" /C ver " )) FAIL( "quoted argv0 /C ver allowed\n" );
    if (!refused( "0", "\\??\\C:\\Windows\\System32\\CMD.EXE", "cmd.exe /c VER" )) FAIL( "upper case allowed\n" );
    /* anything else runs */
    if (refused( "1", CMD, CMD " /c \"ver\"" )) FAIL( "MADEIRA_CMD_VER=1 refused\n" );
    if (refused( NULL, CMD, CMD " /c \"ver > out.txt\"" )) FAIL( "ver with redirect refused\n" );
    if (refused( NULL, CMD, CMD " /c \"version.bat\"" )) FAIL( "version.bat refused\n" );
    if (refused( NULL, CMD, CMD " /k ver" )) FAIL( "/k refused\n" );
    if (refused( NULL, CMD, CMD " /c" )) FAIL( "empty /c refused\n" );
    if (refused( NULL, CMD, CMD )) FAIL( "bare cmd refused\n" );
    if (refused( NULL, CMD, CMD " /cver" )) FAIL( "/cver refused\n" );
    if (refused( NULL, "C:\\x\\notcmd.exe", "notcmd.exe /c ver" )) FAIL( "other image refused\n" );
    if (cmd_ver_refuse( NULL, NULL, 0, NULL, 0 )) FAIL( "NULL refused\n" );
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-cmd-ver-') as directory:
    folder = Path(directory)
    src = folder / 'check.c'
    src.write_text(code)
    exe = folder / 'check'
    cc = os.environ.get('CC', 'cc')
    flags = [cc, '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function', '-g', str(src), '-o', str(exe)]
    sanitize = ['-fsanitize=address,undefined', '-fno-sanitize-recover=all']
    if subprocess.run(flags[:1] + sanitize + flags[1:], capture_output=True).returncode != 0:
        r = subprocess.run(flags, capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
    r = subprocess.run([str(exe)], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
print('PASS: cmd.exe /c ver (and its two fallback spellings) is refused unless MADEIRA_CMD_VER=1; other cmd.exe runs')
