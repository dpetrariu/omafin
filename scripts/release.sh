#!/usr/bin/env bash
# Cut a release: bump the version everywhere, commit and tag, push the tag, wait
# for the Release workflow to build and publish the backends, then commit their
# checksums to backend.sha256 and push main.
#
#   scripts/release.sh 0.2.0
#   scripts/release.sh --pin 0.2.0   # only the last step, if it was interrupted
#
# main moves only once the backends are pinned: `omarchy plugin add` installs
# from main, and scripts/fetch-backend.sh refuses a version without a checksum.
set -euo pipefail
pin_only=false
if [[ "${1:-}" == --pin ]]; then
  pin_only=true
  shift
fi
version="${1:?usage: scripts/release.sh [--pin] X.Y.Z}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Versions look like 0.2.0" >&2; exit 2; }
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first" >&2; exit 1; }
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || { echo "Release from main" >&2; exit 1; }
command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || { echo "The release needs a signed-in GitHub CLI (gh auth login)" >&2; exit 1; }
git fetch --quiet origin

if ! $pin_only; then
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "main is not in step with origin/main" >&2; exit 1; }
  git rev-parse -q --verify "refs/tags/v$version" >/dev/null && { echo "v$version already exists" >&2; exit 1; }

  sed -i "0,/^version = \".*\"/s//version = \"$version\"/" Cargo.toml
  sed -i "s/^\(  \"version\": \)\"[^\"]*\"/\1\"$version\"/" manifest.json
  cargo=${CARGO:-cargo}
  $cargo update --quiet --workspace --offline 2>/dev/null || $cargo update --quiet --workspace
  grep -q "^version = \"$version\"" Cargo.toml && grep -q "\"version\": \"$version\"" manifest.json

  git commit --quiet -am "Release v$version"
  git tag -a "v$version" -m "Omafin $version"
  git push --quiet origin "v$version"
  echo "Pushed v$version; waiting for the Release workflow to publish it."
fi

git merge-base --is-ancestor "v$version" HEAD || { echo "main does not contain v$version" >&2; exit 1; }
tag_sha="$(git rev-parse "v$version^{commit}")"

run=""
for _ in $(seq 1 60); do
  run="$(gh run list --workflow release.yml --commit "$tag_sha" --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
  [[ -n "$run" ]] && break
  sleep 5
done
[[ -n "$run" ]] || { echo "No Release workflow run for v$version; see the Actions tab" >&2; exit 1; }
gh run watch "$run" --exit-status >/dev/null || { echo "The Release workflow failed; see: gh run view $run" >&2; exit 1; }

# Check what was published before pinning it: every archive is there and
# matches the SHA256SUMS the workflow wrote.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
gh release download "v$version" -D "$tmp" >/dev/null
for arch in x86_64 aarch64; do
  grep -q "  omafin-$version-linux-$arch.tar.gz\$" "$tmp/SHA256SUMS" || { echo "The release has no $arch backend" >&2; exit 1; }
done
(cd "$tmp" && sha256sum --check --quiet --strict SHA256SUMS) || { echo "The published archives do not match their SHA256SUMS" >&2; exit 1; }

{
  echo "# The prebuilt backends of v$version, as the Release workflow built them from tag v$version (${tag_sha:0:7})."
  echo "# scripts/fetch-backend.sh installs a download only if it matches a line here; scripts/release.sh"
  echo "# writes this file after each release."
  cat "$tmp/SHA256SUMS"
} > backend.sha256
git add backend.sha256
git commit --quiet -m "Pin the v$version backends"
git push --quiet origin main
echo "Released v$version: the backends are pinned in backend.sha256 and main is pushed."
