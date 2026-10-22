#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
label=jp.meowkawaii.KiraRaki.render
domain="gui/$(id -u)"
plist="$PWD/build/$label.development.plist"
case "${1:-start}" in
  start)
    mkdir -p build
    /usr/bin/python3 - "$PWD" "$plist" <<'PY'
import plistlib, sys
root, path = sys.argv[1:]
with open(path, 'wb') as f:
    plistlib.dump({'Label':'jp.meowkawaii.KiraRaki.render', 'ProgramArguments':[root+'/build/KiraRaki.app/Contents/MacOS/KiraRakiService', root+'/build/KiraRaki.app/Contents/Resources/Effects.metal'], 'MachServices':{'jp.meowkawaii.KiraRaki.render':True}, 'ProcessType':'Interactive', 'StandardOutPath':root+'/build/service.log', 'StandardErrorPath':root+'/build/service.log'}, f)
PY
    if ! launchctl print "$domain/$label" >/dev/null 2>&1; then launchctl bootstrap "$domain" "$plist"; fi
    launchctl kickstart "$domain/$label"
    ;;
  stop) launchctl bootout "$domain/$label" ;;
  status) launchctl print "$domain/$label" ;;
  *) printf 'Usage: scripts/service.sh start|stop|status\n'; exit 2 ;;
esac
