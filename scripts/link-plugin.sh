#!/usr/bin/env bash
# Link this checkout into Omarchy's plugin folder and enable it.
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plugin_home="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
install_path="$plugin_home/dpetrariu.omafin"

command -v omarchy >/dev/null || { echo "omarchy is required" >&2; exit 1; }
[[ -x "$project_dir/bin/omafin" ]] || { echo "Build the backend first: make install" >&2; exit 1; }

omarchy plugin validate "$project_dir"
mkdir -p "$plugin_home"
# The plugin id was "omafin" before it became "dpetrariu.omafin": drop that link so both do not load.
old_path="$plugin_home/omafin"
if [[ -L "$old_path" && "$(readlink -f "$old_path")" == "$project_dir" ]]; then
  omarchy plugin disable omafin >/dev/null 2>&1 || true
  rm "$old_path"
fi
if [[ -L "$install_path" && "$(readlink -f "$install_path")" == "$project_dir" ]]; then
  :
elif [[ -e "$install_path" || -L "$install_path" ]]; then
  echo "$install_path already exists and is not this checkout; move it away first" >&2
  exit 1
else
  ln -s "$project_dir" "$install_path"
fi
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$apps"
install -m 644 "$project_dir/setup/omafin.desktop" "$apps/omafin.desktop"

# The launcher icon, by name, from the user icon theme.
icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
mkdir -p "$icons"
install -m 644 "$project_dir/ui/assets/icon.svg" "$icons/omafin.svg"
gtk-update-icon-cache -q -t "${icons%/scalable/apps}" 2>/dev/null || true
update-desktop-database "$apps" 2>/dev/null || true
omarchy-shell shell rescanPlugins
# The rescan finishes in the background; wait until the shell knows the plugin.
for _ in $(seq 1 20); do
  omarchy plugin list 2>/dev/null | grep -q '^dpetrariu\.omafin ' && break
  sleep 0.5
done
omarchy plugin enable dpetrariu.omafin
echo "Omafin is linked at $install_path. Click the film icon in the bar."
