#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_bundle="$PWD/build/native/obs/kiraraki.plugin"
destination="$HOME/Library/Application Support/obs-studio/plugins/kiraraki.plugin"
[[ -d "$source_bundle" ]] || { printf 'Run scripts/build.sh --obs first\n'; exit 1; }
mkdir -p "$(dirname "$destination")"
if [[ -e "$destination" ]]; then
  backup="$destination.backup-$(date +%Y%m%d-%H%M%S)"
  mv "$destination" "$backup"
fi
ditto "$source_bundle" "$destination"
printf 'Installed: %s\nRestart OBS to load the plugin.\n' "$destination"
