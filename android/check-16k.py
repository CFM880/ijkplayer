#!/usr/bin/env python3
"""Validate all ELF PT_LOAD segment alignments without third-party packages."""
import pathlib
import struct
import sys

root = pathlib.Path(sys.argv[1])
files = sorted(root.rglob('*.so'))
if not files:
    sys.exit(f'No shared libraries found: {root}')
failed = False
for path in files:
    data = path.read_bytes()
    if data[:5] != b'\x7fELF\x02' or data[5] != 1:
        sys.exit(f'Expected little-endian ELF64: {path}')
    phoff = struct.unpack_from('<Q', data, 32)[0]
    entsize, count = struct.unpack_from('<HH', data, 54)
    segments = []
    for i in range(count):
        ptype, flags, offset, vaddr, paddr, filesz, memsz, align = struct.unpack_from(
            '<IIQQQQQQ', data, phoff + i * entsize)
        if ptype == 1:
            segments.append((align, (vaddr - offset) % 16384 == 0))
    ok = bool(segments) and all(a >= 16384 and congruent for a, congruent in segments)
    failed |= not ok
    print(f'{"PASS" if ok else "FAIL"} {path.relative_to(root)} LOAD align: '
          + ', '.join(hex(a) for a, _ in segments))
sys.exit(1 if failed else 0)
