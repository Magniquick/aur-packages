#!/usr/bin/env bash
# Build, install and test one package directory, then regenerate .SRCINFO.
# Runs as a non-root user with passwordless sudo (makepkg refuses root).
set -euo pipefail
pkg=${1:?usage: build.sh <package-dir>}
cd "$pkg"

makepkg --cleanbuild --force --syncdeps --noconfirm
sudo pacman -U --noconfirm ./*.pkg.tar.zst
if [[ -x e2e.sh ]]; then
	./e2e.sh
fi
makepkg --printsrcinfo >.SRCINFO
