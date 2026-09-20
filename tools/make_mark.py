# Draws examples/showcase/mark.png, the one image the showcase loads.
# Committed so ResourceImage has something real to decode; run to regenerate.
import struct, zlib, math, pathlib

SIZE = 64
INK, CUP, FOAM = (0x2f, 0x6f, 0x4f), (0xff, 0xff, 0xff), (0xd5, 0xa6, 0x65)

rows = []
for y in range(SIZE):
    row = bytearray([0])
    for x in range(SIZE):
        dx, dy = x - SIZE / 2 + 0.5, y - SIZE / 2 + 0.5
        d = math.hypot(dx, dy)
        if d > 30:
            row += bytes((0, 0, 0, 0))
        elif d > 25:
            row += bytes(INK + (255,))
        elif dy < -6 and abs(dx) < 17:
            row += bytes(FOAM + (255,))
        else:
            row += bytes(CUP + (255,))
    rows.append(bytes(row))

raw = zlib.compress(b"".join(rows), 9)

def chunk(tag, body):
    return (struct.pack(">I", len(body)) + tag + body
            + struct.pack(">I", zlib.crc32(tag + body) & 0xffffffff))

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
       + chunk(b"IDAT", raw)
       + chunk(b"IEND", b""))

out = pathlib.Path(__file__).resolve().parent.parent / "examples/showcase/mark.png"
out.write_bytes(png)
print(f"{out.name}: {len(png)} bytes")
