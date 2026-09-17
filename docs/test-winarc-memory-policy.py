#!/usr/bin/env python3
"""Exercise generated C and patch application against the pinned Madeira tree.

Usage: python3 tests/test-winarc-memory-policy.py /path/to/clean/Madeira
Requires a host C compiler, but no iOS SDK or JIT permission.
"""
import ast
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[1]
patch = repo / 'app/winarc-runtime-patch.py'
base = Path(sys.argv[1]).resolve()
wine_rel = Path('build/ntdll-unix/virtual_ios.c')
original = (base / wine_rel).read_text()
assert 'WINARC_PE_SOURCE_PROTECT_V2' not in original, 'Use a clean pinned base'
tree = ast.parse(patch.read_text())
helper = next(ast.literal_eval(n.value) for n in tree.body
              if isinstance(n, ast.Assign) and any(
                  isinstance(t, ast.Name) and t.id == 'memory_helper' for t in n.targets))
# Compile the real Wine conversion function, not a reimplementation of it.
conversion = re.search(r'static int get_unix_prot\( BYTE vprot \)\n\{.*?\n\}', original, re.S)[0]
defines = '\n'.join(re.findall(r'^#define VPROT_\w+\s+0x[0-9a-fA-F]+.*$', original, re.M))
harness = r'''
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/mman.h>
typedef unsigned char BYTE;
static size_t page_size = 4096, host_page_size = 16384;
static BYTE pages[4];
static BYTE get_page_vprot(const void *p) {
    size_t slot = ((uintptr_t)p - 0x10000) / page_size;
    assert(slot < 4);
    return pages[slot];
}
'''
cases = r'''
int main(void) {
    const BYTE states[] = {
        0x21, 0x23, 0x20, 0x00, 0x31, 0x29, 0x63, 0x25
    };
    unsigned count = 0;
    for (unsigned a=0; a<8; ++a) for (unsigned b=0; b<8; ++b)
    for (unsigned c=0; c<8; ++c) for (unsigned d=0; d<8; ++d) {
        unsigned indices[] = {a,b,c,d};
        int expected_candidate = a < 3 && a == b && b == c && c == d;
        for (unsigned i=0; i<4; ++i) pages[i] = states[indices[i]];
        struct winarc_memory_policy p = winarc_memory_describe_host_page(0x10000);
        assert(p.pages == 4);
        assert((p.reasons == 0) == expected_candidate);
        ++count;
    }
    pages[0]=0x21; pages[1]=0x23; pages[2]=0x20; pages[3]=0x25;
    assert(winarc_memory_describe_host_page(0x10000).reasons & WINARC_MEM_MIXED);
    assert(winarc_memory_describe_host_page(0x10000).reasons & WINARC_MEM_CODE);
    /* A state change is read afresh, not hidden by a stale classification cache. */
    for (unsigned i=0;i<4;++i) pages[i]=0x23;
    assert(!winarc_memory_describe_host_page(0x10000).reasons);
    pages[2]=0x31;
    assert(winarc_memory_describe_host_page(0x10000).reasons & WINARC_MEM_GUARD);
    host_page_size=4096;
    assert(winarc_memory_describe_host_page(0x10000).pages==1);
    assert(winarc_memory_describe_host_page(0x10001).reasons & WINARC_MEM_GEOMETRY);
    host_page_size=6144;
    assert(winarc_memory_describe_host_page(0x10000).reasons & WINARC_MEM_GEOMETRY);
    host_page_size=16384;
    page_size=0;
    assert(winarc_memory_describe_host_page(0x10000).reasons & WINARC_MEM_GEOMETRY);
    assert(count==4096);
    return 0;
}
'''

def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True)

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    c = tmp / 'policy.c'
    c.write_text(harness + defines + '\n' + conversion + '\n' + helper + cases)
    run('cc', '-std=c11', '-Wall', '-Wextra', '-Werror', str(c), '-o', str(tmp/'policy'))
    run(str(tmp/'policy'))
    print('PASS: generated C, 4096 permission combinations, geometry and state changes')
    for name, comment in [('original', 'â'), ('comment-encoding', 'ENCODING_CHANGED')]:
        target = tmp/name
        for rel in [wine_rel] + [Path('app/Madeira')/n for n in
                ('ContentView.swift','StikJITHelper.swift','JITAllocator.c','JITAllocator.h')]:
            (target/rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(base/rel, target/rel)
        # Exercise only comment variation; executable C must be identical.
        s = original.replace('actually granting EXEC â', 'actually granting EXEC '+comment)
        (target/wine_rel).write_text(s)
        run(sys.executable, str(patch), str(target))
        snapshots = {p:p.read_bytes() for p in target.rglob('*') if p.is_file()}
        run(sys.executable, str(patch), str(target))
        assert all(p.read_bytes()==data for p,data in snapshots.items())
        generated = (target/wine_rel).read_text()
        assert 'no direct RW+COPY rev=3' in generated
        assert 'access_checks=disabled' in generated
        print('PASS: full patch, rev3 retained, idempotence:', name)
    # Fail closed when the protected code block changed; no partially patched file.
    bad = tmp/'bad'
    (bad/wine_rel).parent.mkdir(parents=True)
    s = original.replace('mach_vm_address_t addr = (mach_vm_address_t)base;',
                         'mach_vm_address_t addr = 0;')
    (bad/wine_rel).write_text(s)
    result = subprocess.run([sys.executable,str(patch),str(bad),'--wine-only'],
                            text=True,capture_output=True)
    assert result.returncode != 0 and 'normal EXEC' in result.stderr
    assert (bad/wine_rel).read_text()==s
    print('PASS: changed anchor rejected without partial write')
