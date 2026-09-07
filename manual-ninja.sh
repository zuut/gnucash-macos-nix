#!/bin/bash
# Incremental ninja in the manual webkit workspace with the derivation's
# compile environment (shim include paths etc.). Run via:
#   nix develop ./dev-env#webkitgtk --command bash dev-env/manual-ninja.sh [ninja args]
set -e
export NIX_BUILD_TOP="$(cd "$(dirname "$0")/../webkit-work" && pwd)"
export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -I$NIX_BUILD_TOP/epoxy-shim -I$NIX_BUILD_TOP/WebKit-b150840/Source/ThirdParty/ANGLE/include"
cd "$NIX_BUILD_TOP/WebKit-b150840/build"
exec ninja -j"$(sysctl -n hw.ncpu)" "$@"
