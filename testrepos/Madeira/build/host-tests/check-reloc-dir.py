#!/usr/bin/env python3
"""A bogus base-relocation directory is refused before the JIT copy applies it.

Ren'Py's launcher stub and pythonw.exe (IMAGE_FILE_RELOCS_STRIPPED, directory
RVA 0x1e000 or 0x1f000, size 0x68, inside .rsrc) made the JIT-pool copy read
resource bytes as relocation blocks and write through wild block RVAs, which
killed the process right after "Starting the game process".

Compiles the production helper ios_reloc_dir_valid, extracted from
ntdll-unix/virtual_ios.c, and checks it on synthetic PE images: a well-formed
table is accepted (also with a zero terminator and trailing padding); a
directory inside .rsrc, outside the image, with a malformed block size or a
block RVA outside the image is refused. It then checks that the three apply
sites bound every DIR64 write to the image and that the stored relocation info
is the validated one. No Wine, SDK or device needed.
"""
import os, re, shutil, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CC = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")

src = (ROOT / "build/ntdll-unix/virtual_ios.c").read_text(encoding="utf-8").replace("\r\n", "\n")

start = src.index("static int ios_reloc_dir_valid(")
end = src.index("\n}\n", start) + 3
helper = src[start:end]

# The first apply site: validate, then clear the directory, then apply and store it.
call = src.index("ios_reloc_dir_valid(rw_image, image_size, pe_off, reloc_rva, reloc_sz, &reloc_why)")
clear = src.index("reloc_rva = 0;", call)
apply_ = src.index("if (reloc_rva && reloc_sz && delta)", clear)
store = src.index("ios_jit_set_reloc_info(image_base, pe_image_base, delta,", apply_)
assert call < clear < apply_ < store, "validate, clear, apply, then store the validated directory"
assert "[reloc-skip]" in src[call:clear], "a refused directory is logged"

# Every DIR64 write at the three sites is bounded by the image size.
assert re.search(r"block_rva \+ off \+ 8 > image_size\) continue;", src[apply_:store]), \
    "JIT copy: fixup must lie inside the image"
child = src[src.index("DIR64 relocations with the child's delta."):]
child = child[:child.index("[child-ntdll] applied")]
assert "+ 8 > m->size) continue;" in child, "child ntdll copy: fixup must lie inside the image"
iat = src[src.index("Re-apply DIR64 relocations within the synced region."):]
iat = iat[:iat.index("dir64_count++;")]
assert "fixup_rva + 8 > img_size" in iat, "IAT sync: fixup must lie inside the image"

harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
''' + helper + r'''
#define IMG 0x30000
#define PE 0x80
static unsigned char img[IMG];

static void sec(int i, const char *name, unsigned rva, unsigned vsz)
{
    unsigned char *s = img + PE + 0x18 + 0xF0 + 40 * i;
    memset(s, 0, 40);
    memcpy(s, name, strlen(name));
    *(unsigned *)(s + 8) = vsz;
    *(unsigned *)(s + 12) = rva;
}

static void fresh(void)
{
    memset(img, 0, sizeof img);
    *(unsigned short *)(img + PE + 6) = 3;      /* sections */
    *(unsigned short *)(img + PE + 0x14) = 0xF0; /* optional header size */
    sec(0, ".text", 0x1000, 0x10000);
    sec(1, ".reloc", 0x20000, 0x1000);
    sec(2, ".rsrc", 0x21000, 0x8000);
}

static void block(unsigned at, unsigned page, unsigned size, int entries)
{
    int i;
    *(unsigned *)(img + at) = page;
    *(unsigned *)(img + at + 4) = size;
    for (i = 0; i < entries; i++) *(unsigned short *)(img + at + 8 + 2 * i) = 0xA000 | (i * 8);
}

static int fails;
static void expect(const char *what, int got, int want, const char *why)
{
    if (got != want) { printf("FAIL %s: got %d (%s), want %d\n", what, got, why, want); fails++; }
}

int main(void)
{
    const char *why = "";
    int r;

    fresh(); block(0x20000, 0x1000, 16, 4); block(0x20010, 0x2000, 12, 2);
    r = ios_reloc_dir_valid((char *)img, IMG, PE, 0x20000, 0x1c, &why);
    expect("two well-formed blocks", r, 1, why);

    fresh(); block(0x20000, 0x1000, 16, 4);
    r = ios_reloc_dir_valid((char *)img, IMG, PE, 0x20000, 0x100, &why);
    expect("block then zero padding", r, 1, why);

    fresh();
    r = ios_reloc_dir_valid((char *)img, IMG, PE, 0x20000, 0x20, &why);
    expect("all-zero table (terminator first)", r, 1, why);

    fresh(); block(0x21000, 0x1000, 16, 4);
    r = ios_reloc_dir_valid((char *)img, IMG, PE, 0x21000, 0x10, &why);
    expect("well-formed bytes but inside .rsrc", r, 0, why);

    /* The shape of the Ren'Py stub: RVA 0x1e000 size 0x68 over resource bytes. */
    fresh();
    *(unsigned *)(img + 0x21000) = 0xffce0be6; *(unsigned *)(img + 0x21004) = 0x7bfd95bb;
    r = ios_reloc_dir_valid((char *)img, IMG, PE, 0x21000, 0x68, &why);
    expect("garbage in .rsrc", r, 0, why);

    fresh(); *(unsigned *)(img + 0x20000) = 0xffce0be6; *(unsigned *)(img + 0x20004) = 0x7bfd95bb;
    r = ios_reloc_dir_valid((char *)img, IMG, PE, 0x20000, 0x68, &why);
    expect("garbage block size outside .rsrc", r, 0, why);

    fresh(); block(0x20000, 0x1000, 6, 0);
    r = ios_reloc_dir_valid((char *)img, IMG, PE, 0x20000, 0x20, &why);
    expect("block size below 8", r, 0, why);

    fresh(); block(0x20000, 0x1000, 17, 4);
    r = ios_reloc_dir_valid((char *)img, IMG, PE, 0x20000, 0x20, &why);
    expect("odd block size", r, 0, why);

    fresh(); block(0x20000, 0x1000, 0x400, 4);
    r = ios_reloc_dir_valid((char *)img, IMG, PE, 0x20000, 0x20, &why);
    expect("block longer than the directory", r, 0, why);

    fresh(); block(0x20000, 0x70000000, 16, 4);
    r = ios_reloc_dir_valid((char *)img, IMG, PE, 0x20000, 0x10, &why);
    expect("block RVA outside the image", r, 0, why);

    fresh(); block(0x20000, 0x1000, 16, 4);
    r = ios_reloc_dir_valid((char *)img, IMG, PE, 0x2fff8, 0x20, &why);
    expect("directory runs past the image", r, 0, why);

    r = ios_reloc_dir_valid((char *)img, IMG, PE, 0xfffffff0u, 0x20, &why);
    expect("RVA + size overflows", r, 0, why);

    r = ios_reloc_dir_valid((char *)img, IMG, PE, 0x20000, 0, &why);
    expect("size 0", r, 0, why);

    printf(fails ? "FAILED\n" : "ok\n");
    return fails != 0;
}
'''

with tempfile.TemporaryDirectory(prefix="madeira-reloc-dir-") as tmp:
    tmp = Path(tmp)
    (tmp / "c.c").write_text(harness, encoding="utf-8")
    subprocess.run([CC, "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                    str(tmp / "c.c"), "-o", str(tmp / "c")], check=True)
    r = subprocess.run([str(tmp / "c")], capture_output=True, text=True)
    print(r.stdout, end="")
    assert r.returncode == 0

print("PASS bogus base-relocation directories are refused")
