#!/usr/bin/env bash
# Run on YOUR machine: downloads the encrypted artifacts of a captures run and decrypts them.
# Usage: bash scripts/collecter-captures.sh <run id> <output folder> [private_key.pem]
set -euo pipefail
RUN=${1:?run id}; OUT=${2:?output folder}
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
PRIV=${3:-$HOME/.mobile-agent-testers/${REPO//\//_}.pem}
mkdir -p "$OUT/enc"
gh run download "$RUN" -D "$OUT/enc"
for key in "$OUT"/enc/*/*.key.bin; do
  name=$(basename "$key" .key.bin); dir=$(dirname "$key")
  pass=$(openssl pkeyutl -decrypt -inkey "$PRIV" -pkeyopt rsa_padding_mode:oaep -in "$key")
  mkdir -p "$OUT/$name"
  openssl enc -d -aes-256-cbc -pbkdf2 -in "$dir/$name.tgz.enc" -pass "pass:$pass" | tar xz -C "$OUT/$name"
done
echo "Captures in $OUT/<name>/results/"
