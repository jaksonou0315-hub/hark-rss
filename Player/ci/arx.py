#!/usr/bin/env python3
"""Extract every member of a BSD ar archive, keeping same-named members (prefix with index).
usage: arx.py archive.a outdir [skip-name ...]"""
import sys, os
a, out, skip = sys.argv[1], sys.argv[2], set(sys.argv[3:])
d = open(a, 'rb').read()
assert d[:8] == b'!<arch>\n', 'not an ar archive'
os.makedirs(out, exist_ok=True)
i, n, kept = 8, 0, 0
while i + 60 <= len(d):
    h = d[i:i+60]; name = h[:16].decode().strip(); size = int(h[48:58].decode().strip())
    body = d[i+60:i+60+size]
    if name.startswith('#1/'):
        ln = int(name[3:]); name = body[:ln].rstrip(b'\0').decode(); body = body[ln:]
    i += 60 + size + (size & 1); n += 1
    if name.startswith('__.SYMDEF') or name in skip or not name.endswith('.o'): continue
    open(os.path.join(out, f'{n:05d}_{name}'), 'wb').write(body); kept += 1
print(f'{a}: {kept} objects')
