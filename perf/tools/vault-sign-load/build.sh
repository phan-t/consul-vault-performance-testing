#!/bin/bash
# Build vault-sign-load on the load generator (first use, or when main.go changes).
# Installs an official Go toolchain under /opt/go if none is present.
#   build.sh            -> /usr/local/bin/vault-sign-load
set -euo pipefail
SRC=$(cd "$(dirname "$0")" && pwd)
BIN=/usr/local/bin/vault-sign-load
STAMP=/var/tmp/vault-sign-load.sha

sum=$(cat "$SRC/main.go" "$SRC/go.mod" | sha256sum | cut -d' ' -f1)
if [ -x "$BIN" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$sum" ]; then
  exit 0
fi

export PATH="/opt/go/bin:$PATH" GOPATH=/var/tmp/gopath GOCACHE=/var/tmp/gocache GOTOOLCHAIN=auto
if ! command -v go >/dev/null; then
  case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) arch=$(uname -m) ;; esac
  ver=$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)
  echo "installing $ver ($arch) to /opt/go"
  curl -fsSL "https://go.dev/dl/$ver.linux-$arch.tar.gz" | sudo tar -xz -C /opt
fi

work=$(mktemp -d /var/tmp/vsl-build.XXXXXX)
trap 'rm -rf "$work"' EXIT
cp "$SRC/main.go" "$SRC/go.mod" "$work/"
cd "$work"
go mod tidy >/dev/null
CGO_ENABLED=0 go build -trimpath -o vault-sign-load .
sudo install -m 0755 vault-sign-load "$BIN"
echo "$sum" > "$STAMP"
echo "built $BIN ($(go version | cut -d' ' -f3))"
