#!/bin/bash
# Stage install-only share files into the uninstalled build dir
# (needed after re-creating build-gui). Usage: stage-share.sh [build-dir]
set -e
SRC="$(cd "$(dirname "$0")/../gnucash" && pwd)"
BUILD="${1:-$(dirname "$0")/../build-gui}"
mkdir -p "$BUILD/share/gnucash/chartjs-2" "$BUILD/share/gnucash/chartjs-4" "$BUILD/share/gnucash/ui"
cp "$SRC/borrowed/chartjs-2/"Chart.bundle*.js "$BUILD/share/gnucash/chartjs-2/"
cp "$SRC/borrowed/chartjs-4/"chart*.js "$BUILD/share/gnucash/chartjs-4/"
cp "$SRC/gnucash/ui/"*.ui "$BUILD/share/gnucash/ui/"
echo "staged chartjs + ui files into $BUILD"
