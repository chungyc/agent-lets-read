#!/usr/bin/env bash
set -euo pipefail
umask 022

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPTS_DIR")"
SRC_DIR="$PLUGIN_DIR/src"
BIN_DIR="$PLUGIN_DIR/.bin"
BIN_PATH="$BIN_DIR/lets-read"

need_build=0
if [ ! -x "$BIN_PATH" ]; then
  need_build=1
else
  for src in "$SRC_DIR"/LetsRead.hs "$SRC_DIR"/LetsRead/*.hs "$SRC_DIR"/LetsRead/Chunker/*.hs "$SRC_DIR"/LetsRead/Command/*.hs; do
    if [ -f "$src" ] && [ "$src" -nt "$BIN_PATH" ]; then
      need_build=1
      break
    fi
  done
fi

if [ "$need_build" -eq 1 ]; then
  mkdir -p "$BIN_DIR"
  ghc -O2 -Wall -i"$SRC_DIR" -outputdir "$BIN_DIR" -o "$BIN_PATH" "$SRC_DIR/LetsRead.hs"
fi
