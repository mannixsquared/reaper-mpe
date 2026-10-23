#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
plugin_dir="${1:-$HOME/Library/Application Support/REAPER/UserPlugins}"
mkdir -p "$plugin_dir"
if [ -f "$plugin_dir/reaper_mpe_editor.dylib" ]; then
 cp -p "$plugin_dir/reaper_mpe_editor.dylib" "$plugin_dir/reaper_mpe_editor.dylib.previous"
fi
cp build/reaper_mpe_editor.dylib "$plugin_dir/reaper_mpe_editor.dylib"
printf 'Installed in %s. Restart REAPER to load it.\n' "$plugin_dir"
