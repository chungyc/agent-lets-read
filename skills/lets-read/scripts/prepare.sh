#!/usr/bin/env bash
set -euo pipefail
umask 022

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPTS_DIR")"
BIN_DIR="$SKILL_DIR/.bin"
BIN_PATH="$BIN_DIR/lets-read"

need_build=0
if [ ! -x "$BIN_PATH" ]; then
  need_build=1
else
  for src in "$SCRIPTS_DIR"/LetsRead.hs "$SCRIPTS_DIR"/LetsRead/*.hs "$SCRIPTS_DIR"/LetsRead/Chunker/*.hs "$SCRIPTS_DIR"/LetsRead/Command/*.hs; do
    if [ -f "$src" ] && [ "$src" -nt "$BIN_PATH" ]; then
      need_build=1
      break
    fi
  done
fi

if [ "$need_build" -eq 1 ]; then
  mkdir -p "$BIN_DIR"
  ghc -O2 -Wall -i"$SCRIPTS_DIR" -outputdir "$BIN_DIR" -o "$BIN_PATH" "$SCRIPTS_DIR/LetsRead.hs"
fi
