#!/usr/bin/env bash
# Download the prebuilt backend that matches this plugin's version into bin/.
#
#   scripts/fetch-backend.sh [VERSION]
#
# The archive must match the checksum committed in backend.sha256, not one
# fetched next to it: whoever could replace a release's files could replace its
# SHA256SUMS too, but not this repository's history. The binary must then report
# the expected version before it replaces bin/omafin. Exit codes:
# 3 unsupported machine, 4 download failed, 5 checksum mismatch or no checksum,
# 6 wrong binary.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:-$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$dir/manifest.json" | head -1)}"
repo="${OMAFIN_GITHUB:-dpetrariu/omafin}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "No valid version in manifest.json" >&2; exit 6; }

case "$(uname -m)" in
  x86_64|amd64) arch=x86_64 ;;
  aarch64|arm64) arch=aarch64 ;;
  *) echo "No prebuilt backend for $(uname -m); build it with ./install.sh --build" >&2; exit 3 ;;
esac

asset="omafin-$version-linux-$arch.tar.gz"
expected="$(awk -v asset="$asset" '$1 !~ /^#/ && $2 == asset { print $1 }' "$dir/backend.sha256" 2>/dev/null | head -1)"
if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
  echo "backend.sha256 has no checksum for $asset; build it with ./install.sh --build" >&2
  exit 5
fi
# OMAFIN_RELEASES_URL points at a mirror (or a test server) laid out like
# GitHub's: <url>/v<version>/<asset>.
base="${OMAFIN_RELEASES_URL:-https://github.com/$repo/releases/download}/v$version"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if ! curl -fsL --retry 2 -o "$tmp/$asset" "$base/$asset" 2>/dev/null; then
  # A private repository needs a signed-in GitHub CLI.
  if [[ -z "${OMAFIN_RELEASES_URL:-}" ]] && command -v gh >/dev/null && gh auth status >/dev/null 2>&1 \
      && gh release download "v$version" -R "$repo" -p "$asset" -D "$tmp" --clobber >/dev/null 2>&1; then
    :
  else
    echo "Could not download $asset from $base" >&2
    exit 4
  fi
fi

if ! printf '%s  %s\n' "$expected" "$asset" | (cd "$tmp" && sha256sum --check --quiet --strict - >/dev/null 2>&1); then
  echo "The download of $asset does not match the checksum in backend.sha256" >&2
  exit 5
fi

tar -xzf "$tmp/$asset" -C "$tmp" omafin
if ! "$tmp/omafin" version | grep -q "^omafin $version "; then
  echo "The downloaded backend is not version $version" >&2
  exit 6
fi

mkdir -p "$dir/bin"
install -m 755 "$tmp/omafin" "$dir/bin/.omafin.new"
mv -f "$dir/bin/.omafin.new" "$dir/bin/omafin"
echo "Installed the omafin $version backend ($arch)"
