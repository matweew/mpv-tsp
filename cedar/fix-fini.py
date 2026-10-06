#!/usr/bin/env python3
"""Disable broken finalizers in libcedarc's A133 libraries that were converted from Android.

The conversion (libVE.so, libawavs2.so, libawvp9HwAL.so) lost the relocations of the .fini_array
entries, so the dynamic loader calls raw offsets when a program exits and every program that
loaded them crashes at the end. The entries are compiler cleanup stubs: when a .fini_array entry
has no relocation, DT_FINI_ARRAYSZ is set to 0 so they are skipped. Libraries built normally
are left alone.
Usage: fix-fini.py lib.so...
"""
import struct
import sys

DT_NULL, DT_FINI_ARRAYSZ = 0, 28
SHT_RELA, SHT_DYNAMIC = 4, 6


def sections(data):
    shoff, = struct.unpack_from('<Q', data, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', data, 0x3a)
    headers = [struct.unpack_from('<IIQQQQIIQQ', data, shoff + i * shentsize) for i in range(shnum)]
    strtab = headers[shstrndx][4]
    out = []
    for h in headers:
        name = data[strtab + h[0]:data.index(b'\0', strtab + h[0])].decode()
        out.append({'name': name, 'type': h[1], 'addr': h[3], 'offset': h[4], 'size': h[5]})
    return out


def fix(path):
    data = bytearray(open(path, 'rb').read())
    if data[:4] != b'\x7fELF' or data[4] != 2 or data[5] != 1:
        print(f'{path}: not a little-endian 64-bit ELF file, skipped')
        return
    secs = sections(data)
    fini = next((s for s in secs if s['name'] == '.fini_array'), None)
    if not fini or not fini['size']:
        print(f'{path}: no finalizers')
        return
    relocated = set()
    for s in secs:
        if s['type'] == SHT_RELA:
            for r in range(s['offset'], s['offset'] + s['size'], 24):
                r_offset, = struct.unpack_from('<Q', data, r)
                relocated.add(r_offset)
    entries = range(fini['addr'], fini['addr'] + fini['size'], 8)
    if all(e in relocated for e in entries):
        print(f'{path}: finalizers are relocated, left alone')
        return
    dyn = next(s for s in secs if s['type'] == SHT_DYNAMIC)
    for entry in range(dyn['offset'], dyn['offset'] + dyn['size'], 16):
        tag, value = struct.unpack_from('<qQ', data, entry)
        if tag == DT_NULL:
            break
        if tag == DT_FINI_ARRAYSZ and value:
            struct.pack_into('<Q', data, entry + 8, 0)
            open(path, 'wb').write(data)
            print(f'{path}: unrelocated finalizers disabled (DT_FINI_ARRAYSZ {value} -> 0)')
            return
    print(f'{path}: finalizers already disabled')


for p in sys.argv[1:]:
    fix(p)
