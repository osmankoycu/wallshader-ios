#!/usr/bin/env python3
"""Tolerance compare for the iOS render harness (spec C10).

Usage: compare-renders.py <golden-dir> <candidate-dir>
No golden dir yet -> adopt the candidate as the golden set (first run).
Pass criteria per image: max per-channel delta <= 2 AND >= 99.9% of
channel samples exact. GPU/driver rounding differs across Metal devices,
so byte-exactness is deliberately NOT required.
"""
import os, struct, sys, zlib

def read_png(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', f"not a PNG: {path}"
    pos, width, height, bitdepth, color, idat = 8, 0, 0, 0, 0, b''
    while pos < len(data):
        length, ctype = struct.unpack('>I4s', data[pos:pos+8])
        chunk = data[pos+8:pos+8+length]
        if ctype == b'IHDR':
            width, height, bitdepth, color = struct.unpack('>IIBB', chunk[:10])
        elif ctype == b'IDAT':
            idat += chunk
        pos += 12 + length
    raw = zlib.decompress(idat)
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[color]
    stride = width * channels
    out = bytearray()
    prev = bytearray(stride)
    pos = 0
    for _ in range(height):
        filt = raw[pos]; pos += 1
        line = bytearray(raw[pos:pos+stride]); pos += stride
        if filt == 1:
            for i in range(channels, stride): line[i] = (line[i] + line[i-channels]) & 0xff
        elif filt == 2:
            for i in range(stride): line[i] = (line[i] + prev[i]) & 0xff
        elif filt == 3:
            for i in range(stride):
                a = line[i-channels] if i >= channels else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xff
        elif filt == 4:
            for i in range(stride):
                a = line[i-channels] if i >= channels else 0
                b = prev[i]
                c = prev[i-channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xff
        out += line
        prev = line
    return width, height, channels, bytes(out)

golden_dir, candidate_dir = sys.argv[1], sys.argv[2]
if not os.path.isdir(golden_dir) or not os.listdir(golden_dir):
    os.makedirs(golden_dir, exist_ok=True)
    import shutil
    for name in sorted(os.listdir(candidate_dir)):
        shutil.copy(os.path.join(candidate_dir, name), os.path.join(golden_dir, name))
    print(f"render-test: no goldens found — ADOPTED {len(os.listdir(golden_dir))} images into {golden_dir}. Commit them.")
    sys.exit(0)

failures = []
names = sorted(os.listdir(golden_dir))
for name in names:
    cand_path = os.path.join(candidate_dir, name)
    if not os.path.exists(cand_path):
        failures.append(f"{name}: missing from candidate run")
        continue
    gw, gh, gc, g = read_png(os.path.join(golden_dir, name))
    cw, ch, cc, c = read_png(cand_path)
    if (gw, gh) != (cw, ch):
        failures.append(f"{name}: size {cw}x{ch} != {gw}x{gh}")
        continue
    n = min(len(g), len(c))
    max_delta, exact = 0, 0
    for i in range(n):
        d = abs(g[i] - c[i])
        if d > max_delta: max_delta = d
        if d == 0: exact += 1
    frac = exact / n
    if max_delta > 2 or frac < 0.999:
        failures.append(f"{name}: maxΔ={max_delta} exact={frac:.4%}")
for extra in sorted(set(os.listdir(candidate_dir)) - set(names)):
    print(f"render-test: note — new render {extra} has no golden")
if failures:
    print("render-test: FAILED")
    for f in failures: print("  " + f)
    sys.exit(1)
print(f"render-test: {len(names)} images within tolerance")
