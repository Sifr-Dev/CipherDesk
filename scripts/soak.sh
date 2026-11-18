#!/bin/bash
# Soak + footprint evidence for Cipher apps (headless umbriel compositor).
# Requires: built binaries (./zig-out/bin here + ../sifr-native/zig-out/bin for
# cipher-hello), python3, flac; regenerates the FLAC fixture library if missing.
# usage: scripts/soak.sh [frames]   (default 600 = 10 s at 60 fps)
set -euo pipefail
FRAMES="${1:-600}"
ROOT_APPS="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE="${SIFR_NATIVE:-$(cd "$ROOT_APPS/../sifr-native" && pwd)}"
APP_BIN="$ROOT_APPS/zig-out/bin"
NAT_BIN="$NATIVE/zig-out/bin"
LIB=/tmp/opencode/nocturne-lib

echo "frames=$FRAMES  native=$NAT_BIN  apps=$APP_BIN"
[ -x "$NAT_BIN/cipher-hello" ] || { echo "missing $NAT_BIN/cipher-hello (build sifr-native)"; exit 1; }
[ -x "$APP_BIN/janus" ] || { echo "missing $APP_BIN/janus (build sifr-apps)"; exit 1; }
[ -x "$APP_BIN/nocturne" ] || { echo "missing $APP_BIN/nocturne (build sifr-apps)"; exit 1; }

mkdir -p "$LIB"
if [ ! -f "$LIB/track1.flac" ]; then
  echo "generating FLAC fixtures in $LIB..."
  command -v flac >/dev/null || { echo "flac CLI required to generate fixtures"; exit 1; }
  python3 - <<'PY'
import wave, struct, math
for i, (name, f1, f2) in enumerate((('track1', 220, 330), ('track2', 440, 550), ('track3', 110, 660))):
    n = 132300
    with wave.open(f'/tmp/opencode/nocturne-lib/{name}.wav', 'wb') as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100)
        for j in range(n):
            t = j / 44100.0
            v = int(16000 * (0.6 * math.sin(2 * math.pi * f1 * t) + 0.4 * math.sin(2 * math.pi * f2 * t)))
            w.writeframesraw(struct.pack('<hh', v, v))
PY
  flac -f -s -8 --tag=TITLE="Fixture One" --tag=ARTIST="Tester" -o "$LIB/track1.flac" "$LIB/track1.wav"
  flac -f -s -8 --tag=TITLE="Fixture Two" --tag=ARTIST="Tester" -o "$LIB/track2.flac" "$LIB/track2.wav"
  flac -f -s -8 --tag=TITLE="Fixture Three" -o "$LIB/track3.flac" "$LIB/track3.wav"
  rm -f "$LIB"/*.wav
fi

python3 - "$FRAMES" "$NAT_BIN" "$APP_BIN" "$LIB" <<'PY'
import os, subprocess, sys, time, resource
frames, nat_bin, app_bin, lib = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]

def run(name, cmd, env_extra=None):
    e = dict(os.environ, CIPHER_MAX_FRAMES=str(frames))
    if env_extra: e.update(env_extra)
    t = time.time()
    p = subprocess.run(cmd, env=e, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    wall = time.time() - t
    ru = resource.getrusage(resource.RUSAGE_CHILDREN)
    tail = [l for l in (p.stdout + p.stderr).splitlines() if 'PROTOCOL' in l or 'EXIT' in l][-2:]
    print(f'{name}: rc={p.returncode} wall={wall:.1f}s rss_child_max_kb={ru.ru_maxrss}')
    for l in tail: print('    ', l)

run('cipher-hello  (gpu)   ', [f'{nat_bin}/cipher-hello'])
run('cipher-hello  (sw)    ', [f'{nat_bin}/cipher-hello'], {'CIPHER_FORCE_SOFTWARE': '1'})
run('nocturne      (gpu)   ', [f'{app_bin}/nocturne', lib])
run('nocturne      (sw)    ', [f'{app_bin}/nocturne', lib], {'CIPHER_FORCE_SOFTWARE': '1'})
PY
