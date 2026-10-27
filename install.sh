#!/usr/bin/env bash
# Install or update Omafin, the Jellyfin client for the Omarchy shell.
#
#   curl -fsSL https://raw.githubusercontent.com/dpetrariu/omafin/main/install.sh | bash
#
# or, from a checkout: ./install.sh
#
# It gets the newest release (or updates to it), builds the backend, links the
# plugin into Omarchy, enables it and restarts the shell. Running it again updates.
#
# Options: --no-restart  leave the shell running (restart it yourself later)
#          --build       compile the backend here instead of downloading it
#          --prebuilt    download the backend even when run from a checkout
# Environment: OMAFIN_DIR  where the code lives (default ~/.local/share/omafin-plugin)
#              OMAFIN_REPO the git repository to clone
#              OMAFIN_COMMIT install this commit (full 40-character SHA) instead of the newest release
set -euo pipefail

repo="${OMAFIN_REPO:-https://github.com/dpetrariu/omafin.git}"
dir="${OMAFIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/omafin-plugin}"
restart=true
commit="${OMAFIN_COMMIT:-}"
release=""
mode=auto

for arg in "$@"; do
  case "$arg" in
    --no-restart) restart=false ;;
    --build) mode=build ;;
    --prebuilt) mode=prebuilt ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null || true; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v omarchy >/dev/null || fail "Omafin is an Omarchy shell plugin; Omarchy 4 is required."
command -v omarchy-shell >/dev/null || fail "This Omarchy has no shell plugins yet; update Omarchy (omarchy update) and run this again."

# Run from inside a checkout: use it instead of cloning.
here=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$here/manifest.json" ]] && grep -q '"id": "dpetrariu.omafin"' "$here/manifest.json"; then
    dir="$here"
  fi
fi

ensure_build_tools() {
  # A C compiler (SQLite is built in), make, and Rust.
  local missing=()
  command -v make >/dev/null || missing+=(make)
  command -v cc >/dev/null || missing+=(base-devel)
  if (( ${#missing[@]} )); then
    say "Installing build tools: ${missing[*]} (asks for your password)"
    sudo pacman -S --needed --noconfirm "${missing[@]}"
  fi
  if command -v cargo >/dev/null; then
    cargo=(cargo)
  elif command -v mise >/dev/null; then
    say "Installing Rust with mise"
    mise install rust@latest >/dev/null 2>&1
    cargo=(mise exec rust@latest -- cargo)
  else
    say "Installing Rust (asks for your password)"
    sudo pacman -S --needed --noconfirm rust
    cargo=(cargo)
  fi
}

if ! command -v git >/dev/null; then
  say "Installing git (asks for your password)"
  sudo pacman -S --needed --noconfirm git
fi

# The newest release tag (vX.Y.Z) and the commit it points to, from the remote.
newest_release() {
  git ls-remote --tags "$repo" 'refs/tags/v*' | awk '
    { ref = $2; sub("refs/tags/", "", ref); peeled = sub(/\^\{\}$/, "", ref)
      if (ref !~ /^v[0-9]+\.[0-9]+\.[0-9]+$/) next
      if (peeled || !(ref in sha)) sha[ref] = $1 }
    END { for (ref in sha) print ref, sha[ref] }' | sort -V | tail -n 1
}

# An install runs one exact commit, checked out detached: the newest release's,
# or OMAFIN_COMMIT's. Never whatever main holds at the moment, which can move
# after a release was reviewed.
if [[ "$dir" != "$here" ]]; then
  if [[ -z "$commit" ]]; then
    read -r release commit < <(newest_release) || true
    [[ -n "$commit" ]] || fail "No Omafin release found in $repo."
  fi
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "OMAFIN_COMMIT must be a full 40-character commit SHA."
  if [[ -d "$dir/.git" ]]; then
    say "Updating $dir to ${release:-$commit}"
  elif [[ -e "$dir" ]]; then
    fail "$dir exists but is not an Omafin checkout; move it away or set OMAFIN_DIR."
  else
    say "Downloading Omafin ${release:-$commit} into $dir"
    git init --quiet "$dir"
    git -C "$dir" remote add origin "$repo"
  fi
  git -C "$dir" fetch --quiet --depth 1 origin "$commit"
  git -C "$dir" checkout --quiet --detach "$commit"
fi

# A checkout someone is working in builds its own backend; an install
# downloads the release built for its version, and builds only if that fails.
[[ "$mode" == auto ]] && mode=$([[ "$dir" == "$here" ]] && echo build || echo prebuilt)
if [[ "$mode" == prebuilt ]]; then
  say "Downloading the backend"
  if ! "$dir/scripts/fetch-backend.sh"; then
    say "No download available; building it here instead"
    mode=build
  fi
fi
if [[ "$mode" == build ]]; then
  ensure_build_tools
  say "Building the backend (a few minutes the first time)"
  make -C "$dir" --no-print-directory install CARGO="${cargo[*]}" >/dev/null
fi

say "Linking the plugin into Omarchy"
"$dir/scripts/link-plugin.sh"

if $restart; then
  say "Restarting the Omarchy shell"
  omarchy restart shell >/dev/null 2>&1 || true
fi

cat <<EOF

Omafin is installed. Click the film icon in the bar, then enter your Jellyfin
address and sign in (Quick Connect or your user name and password).
$($restart || echo "Restart the shell first: omarchy restart shell")
Update later by running this installer again. Remove with:
  $dir/scripts/uninstall.sh
EOF
