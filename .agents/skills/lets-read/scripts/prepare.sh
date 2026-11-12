#!/usr/bin/env bash
set -euo pipefail
umask 022

if [ ! -x .agents/skills/lets-read/.bin/lets-read ] || [ .agents/skills/lets-read/scripts/LetsRead.hs -nt .agents/skills/lets-read/.bin/lets-read ]; then
  mkdir -p .agents/skills/lets-read/.bin
  ghc -O2 -outputdir .agents/skills/lets-read/.bin -o .agents/skills/lets-read/.bin/lets-read .agents/skills/lets-read/scripts/LetsRead.hs
fi
