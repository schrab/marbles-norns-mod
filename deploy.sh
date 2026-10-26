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

tar czf "$DIR.tgz" --exclude '.git' --exclude 'reference' --exclude 'test' \
    --exclude '.superpowers' --exclude 'docs' --exclude '*.tgz' .
ssh "$HOST" "mkdir -p ~/dust/code/$DIR"
scp -q "$DIR.tgz" "$HOST:/tmp/$DIR.tgz"
ssh "$HOST" "tar xzf /tmp/$DIR.tgz -C ~/dust/code/$DIR && \
  lua5.1 -e \"assert(loadfile('/home/we/dust/code/$DIR/lib/mod.lua'))\" && \
  sudo systemctl restart norns-jack norns-sclang norns-main && \
  sleep 3 && systemctl is-active norns-main"
rm -f "$DIR.tgz"
echo "deployed to $HOST:~/dust/code/$DIR — enable once via SYSTEM > MODS if new"
