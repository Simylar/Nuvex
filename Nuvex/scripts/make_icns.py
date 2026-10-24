#!/usr/bin/env python3
"""Package PNG icon sizes in Apple's ICNS container without changing pixels."""
import sys
from pathlib import Path

folder = Path(sys.argv[1])
output = Path(sys.argv[2])
entries = [
    # IconServices interpreta las entradas icp4/icp5/icp6 de este contenedor
    # artesanal como mapas clásicos, no como los PNG incluidos, y muestra
    # bandas de colores. Las variantes Retina ic11/ic12 cubren los tamaños
    # pequeños y el sistema también puede reducirlas en pantallas 1x.
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png"),
]
chunks = []
for kind, name in entries:
    data = (folder / name).read_bytes()
    chunks.append(kind.encode("ascii") + (len(data) + 8).to_bytes(4, "big") + data)
body = b"".join(chunks)
output.write_bytes(b"icns" + (len(body) + 8).to_bytes(4, "big") + body)
