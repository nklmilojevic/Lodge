#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE_DIR="${SPARKLE_UPDATE_DIR:-$ROOT_DIR/build/updates}"
APPCAST_PATH="$ROOT_DIR/appcast.xml"

DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:?Set DOWNLOAD_URL_PREFIX}"
SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:?Set SPARKLE_PRIVATE_KEY}"
SPARKLE_BIN="${SPARKLE_BIN:-}"

if [ -z "$SPARKLE_BIN" ]; then
  SPARKLE_GENERATOR="$(command -v generate_appcast || true)"
  if [ -n "$SPARKLE_GENERATOR" ]; then
    SPARKLE_BIN="$(dirname "$SPARKLE_GENERATOR")"
  elif [ -d "/opt/homebrew/bin" ]; then
    SPARKLE_BIN="/opt/homebrew/bin"
  else
    SPARKLE_BIN="/usr/local/bin"
  fi
fi

"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --ed-key-file "$SPARKLE_PRIVATE_KEY" \
  -o "$APPCAST_PATH" \
  "$UPDATE_DIR"
