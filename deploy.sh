#!/usr/bin/env bash
# Deploy the mod to a norns device and restart the stack.
# Usage: ./deploy.sh [host]   (default: fates)
#
# Mods load at matron (norns-main) start, so all three units are restarted
# explicitly (norns.target alone does not cycle them). Do NOT run this
# against a device whose SYSTEM>UPDATE script replaces ~/norns — this only
# touches ~/dust/code/marbles-norns-mod.
set -euo pipefail
cd "$(dirname "$0")"

HOST="${1:-fates}"
DIR="marbles-norns-mod"

# Host-side syntax sweep, fail-closed: a syntax error aborts the deploy
# before anything is packed (the device has no lua5.1 to check with; a bad
# mod.lua would blank matron). Plain lua5.1 on Linux, WSL lua5.1 on Windows.
sweep_lua() {
  if command -v lua5.1 >/dev/null 2>&1; then
    lua5.1 -e "assert(loadfile('$1'))"
  else
    wsl -e lua5.1 -e "assert(loadfile('$1'))"
  fi
}
for f in lib/*.lua lib/*/*.lua data/*.lua test-script/*.lua; do
  sweep_lua "$f" || { echo "syntax error: $f" >&2; exit 1; }
done

tar czf "$DIR.tgz" --exclude '.git' --exclude 'reference' --exclude 'test' \
    --exclude '.superpowers' --exclude 'docs' --exclude '*.tgz' .
ssh "$HOST" "mkdir -p ~/dust/code/$DIR"
scp -q "$DIR.tgz" "$HOST:/tmp/$DIR.tgz"
ssh "$HOST" "tar xzf /tmp/$DIR.tgz -C ~/dust/code/$DIR && \
  sudo systemctl restart norns-jack norns-sclang norns-main && \
  sleep 3 && systemctl is-active norns-main"
rm -f "$DIR.tgz"
echo "deployed to $HOST:~/dust/code/$DIR — enable once via SYSTEM > MODS if new"
