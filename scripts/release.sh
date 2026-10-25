#!/usr/bin/env bash
# Cut a release: bump the version everywhere, commit, tag and push. The
# Release workflow then builds the backends and publishes them.
#
#   scripts/release.sh 0.2.0
set -euo pipefail
version="${1:?usage: scripts/release.sh X.Y.Z}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Versions look like 0.2.0" >&2; exit 2; }
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first" >&2; exit 1; }
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || { echo "Release from main" >&2; exit 1; }
git fetch --quiet origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "main is not in step with origin/main" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/v$version" >/dev/null && { echo "v$version already exists" >&2; exit 1; }

sed -i "0,/^version = \".*\"/s//version = \"$version\"/" Cargo.toml
sed -i "s/^\(  \"version\": \)\"[^\"]*\"/\1\"$version\"/" manifest.json
cargo=${CARGO:-cargo}
$cargo update --quiet --workspace --offline 2>/dev/null || $cargo update --quiet --workspace
grep -q "^version = \"$version\"" Cargo.toml && grep -q "\"version\": \"$version\"" manifest.json

git commit --quiet -am "Release v$version"
git tag -a "v$version" -m "Omafin $version"
git push --quiet origin main "v$version"
echo "Pushed v$version; the Release workflow builds and publishes it."
