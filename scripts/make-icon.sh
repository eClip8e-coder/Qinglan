#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift -module-cache-path .build/swift-cache scripts/Icon.swift .build/AppIcon.iconset
python3 - <<'PY'
from pathlib import Path
import struct
representations = [('icp4','16x16'), ('icp5','32x32'), ('icp6','32x32@2x'),
                   ('ic07','128x128'), ('ic08','256x256'), ('ic09','512x512'), ('ic10','512x512@2x')]
chunks = b''
for kind, size in representations:
    png = Path(f'.build/AppIcon.iconset/icon_{size}.png').read_bytes()
    chunks += kind.encode() + struct.pack('>I', len(png) + 8) + png
Path('Resources/AppIcon.icns').write_bytes(b'icns' + struct.pack('>I', len(chunks) + 8) + chunks)
PY
