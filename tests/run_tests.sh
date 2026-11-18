#!/usr/bin/env bash
set -euo pipefail
umask 022

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
SCRIPTS_DIR="$REPO_DIR/skills/lets-read/scripts"
BIN_PATH="$REPO_DIR/skills/lets-read/.bin/lets-read"

"$SCRIPTS_DIR/prepare.sh"

TMP_BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_BUILD_DIR"' EXIT

# Compile and run the main modular test suite (Spec.hs + *Spec.hs modules in TESTS_DIR),
# plus any additional standalone Test*.hs entrypoints added to TESTS_DIR.
entrypoints=("$TESTS_DIR/Spec.hs")
for extra in "$TESTS_DIR"/Test*.hs; do
  if [ -f "$extra" ] && [ "$(basename "$extra")" != "TestHarness.hs" ]; then
    entrypoints+=("$extra")
  fi
done

for entry in "${entrypoints[@]}"; do
  name="$(basename "$entry" .hs)"
  ghc -O0 -Wall -Werror \
    -i"$SCRIPTS_DIR" \
    -i"$TESTS_DIR" \
    -outputdir "$TMP_BUILD_DIR/$name" \
    -o "$TMP_BUILD_DIR/$name-bin" \
    "$entry"
  "$TMP_BUILD_DIR/$name-bin" "$BIN_PATH"
done
