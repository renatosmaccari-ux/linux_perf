#!/usr/bin/env python3
"""Write LZW .Z files in the classic compress(1) format.

STOR2RRD packages ship their payload as stor2rrd.tar.Z and the installer
decompresses it with uncompress(1), falling back to gunzip(1). A real .Z is
the only form both accept, and compress(1) is often absent on build hosts,
so produce the format directly.

Format: magic 1f 9d, flags byte (0x80 block mode | maxbits), then LZW codes
packed LSB-first with a width that grows from 9 to maxbits. Both a width
increase and a CLEAR are padded so the number of codes emitted at the old
width is a multiple of 8 - the alignment quirk uncompress(1) relies on.
Once the dictionary fills, compress(1)'s ratio heuristic decides when to
reset it; without that a large input compresses badly, so it is kept here.
"""

import sys

CLEAR = 256
FIRST = 257          # first dictionary code in block mode
INIT_BITS = 9
CHECK_GAP = 10000    # input chars between compression-ratio checks


def compress(data, maxbits=16):
    out = bytearray([0x1F, 0x9D, 0x80 | maxbits])

    bitbuf = 0      # pending bits, LSB first
    bitcnt = 0
    nbits = INIT_BITS
    emitted = 0     # codes written at the current width, for 8-code padding
    out_count = 0   # codes written in total, for the ratio heuristic

    def put(code):
        nonlocal bitbuf, bitcnt, emitted, out_count
        bitbuf |= code << bitcnt
        bitcnt += nbits
        while bitcnt >= 8:
            out.append(bitbuf & 0xFF)
            bitbuf >>= 8
            bitcnt -= 8
        emitted += 1
        out_count += 1

    def pad():
        """Flush to a whole-byte boundary and to a multiple of 8 codes."""
        nonlocal bitbuf, bitcnt, emitted
        while emitted % 8:
            put(0)
        if bitcnt:
            out.append(bitbuf & 0xFF)
            bitbuf = 0
            bitcnt = 0
        emitted = 0

    table = {bytes([i]): i for i in range(256)}
    nextcode = FIRST
    maxcode = 1 << maxbits

    ratio = 0
    checkpoint = CHECK_GAP
    in_count = 1

    w = b""
    for ch in data:
        in_count += 1
        wk = w + bytes([ch])
        if wk in table:
            w = wk
            continue
        put(table[w])
        if nextcode < maxcode:
            table[wk] = nextcode
            nextcode += 1
            if nextcode > (1 << nbits) and nbits < maxbits:
                pad()
                nbits += 1
        elif in_count >= checkpoint:
            # table is full: keep it only while it still pays for itself
            checkpoint = in_count + CHECK_GAP
            rat = (in_count << 8) // out_count if out_count else 0
            if rat > ratio:
                ratio = rat
            else:
                ratio = 0
                put(CLEAR)
                pad()
                table = {bytes([i]): i for i in range(256)}
                nextcode = FIRST
                nbits = INIT_BITS
        w = bytes([ch])

    if w:
        put(table[w])

    # flush residual bits
    if bitcnt:
        out.append(bitbuf & 0xFF)
    return bytes(out)


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: lzw_compress.py <infile> <outfile.Z>")
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    with open(sys.argv[2], "wb") as f:
        f.write(compress(data))


if __name__ == "__main__":
    main()
