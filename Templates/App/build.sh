#!/bin/zsh
cd "${0:A:h}" && exec "${HUDKIT_DIR:-../hudkit}/scripts/hud-build.sh" __PRODUCT__ "$@"
