#!/bin/bash
# Removes ModelThumbs and clears Quick Look's thumbnail cache.
set -u
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
for d in /Applications/ModelThumbs.app "$HOME/Applications/ModelThumbs.app"; do
  if [ -d "$d" ]; then
    pluginkit -r "$d/Contents/PlugIns/ModelThumbsThumbnailer.appex" 2>/dev/null
    "$LSREG" -u "$d" 2>/dev/null
    rm -rf "$d" && echo "Removed $d"
  fi
done
qlmanage -r >/dev/null 2>&1
qlmanage -r cache >/dev/null 2>&1
killall Finder 2>/dev/null
echo "Done."
