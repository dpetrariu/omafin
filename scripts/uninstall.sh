#!/usr/bin/env bash
# Remove Omafin from Omarchy. Your library and watch history stay on the Jellyfin server.
#
#   scripts/uninstall.sh          keep settings and the picture cache
#   scripts/uninstall.sh --purge  also delete those, and the saved session
set -euo pipefail

purge=false
[[ "${1:-}" == "--purge" ]] && purge=true

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="${XDG_CONFIG_HOME:-$HOME/.config}"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
cache="${XDG_CACHE_HOME:-$HOME/.cache}"
link="$config/omarchy/plugins/omafin"

if command -v omarchy >/dev/null; then
  omarchy plugin disable omafin >/dev/null 2>&1 || true
fi
# Only remove the plugin entry if it is a link (what install.sh makes), never a real folder.
if [[ -L "$link" ]]; then
  rm "$link"
fi
rm -f "$data/applications/omafin.desktop"
update-desktop-database "$data/applications" 2>/dev/null || true
command -v omarchy-shell >/dev/null && omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

if $purge; then
  for folder in "$config/omafin" "$data/omafin" "$cache/omafin"; do
    # Never the code itself, wherever it was cloned.
    [[ "$(readlink -f "$folder")" == "$project_dir" ]] && continue
    rm -rf "$folder"
  done
  if command -v secret-tool >/dev/null; then
    secret-tool clear service omafin account access_token 2>/dev/null || true
  fi
  echo "Removed Omafin, its settings, cache and saved session."
else
  echo "Removed Omafin from Omarchy. Settings are kept in $config/omafin; run with --purge to delete them."
fi
echo "The code is still in $project_dir; delete that folder too if you like."
echo "Restart the shell to finish: omarchy restart shell"
