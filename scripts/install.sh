#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="${SOURCE_APP:-$PROJECT_ROOT/build/DerivedData/Build/Products/Debug/RightClickHelper.app}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
DEST_APP="$INSTALL_DIR/RightClickHelper.app"
if [[ ! -d "$SOURCE_APP" ]]; then printf '%s\n' 'Run bash scripts/build.sh first.' >&2; exit 1; fi
codesign --verify --deep --strict "$SOURCE_APP"
[[ "$SOURCE_APP" != "$DEST_APP" ]] || { printf '%s\n' 'Source and destination must differ.' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")" == 'dev.rightclickhelper.prototype' ]] || exit 1
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SOURCE_APP/Contents/PlugIns/FinderExtension.appex/Contents/Info.plist")" == 'dev.rightclickhelper.prototype.FinderExtension' ]] || exit 1

old_processes_running() {
  ps -axo comm= | awk -v main="$DEST_APP/Contents/MacOS/RightClickHelper" -v ext="$DEST_APP/Contents/PlugIns/FinderExtension.appex/Contents/MacOS/FinderExtension" '$0 == main || $0 == ext { found=1 } END { exit !found }'
}
# Disabling an extension is asynchronous. Give the system time to stop it;
# never kill Finder, other extensions, or an app with an open creation sheet.
for ((attempt=0; attempt<60; attempt++)); do
  if ! old_processes_running; then break; fi
  if [[ "$attempt" == 0 ]]; then printf '%s\n' 'Waiting up to 15 seconds for the old app/extension to exit…'; fi
  sleep 0.25
done
if old_processes_running; then
  printf '%s\n' 'Quit RightClickHelper and disable its Finder extension before reinstalling. Installed app was not changed.' >&2
  exit 1
fi
mkdir -p "$INSTALL_DIR"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
STAGING_DIR=$(mktemp -d "$INSTALL_DIR/.rightclickhelper-install.XXXXXX")
BACKUP_APP=''
REPLACED=0
COMPLETED=0
cleanup() {
  result=$?
  if [[ "$COMPLETED" == 0 && "$REPLACED" == 1 ]]; then
    if [[ -d "$DEST_APP" ]]; then
      pluginkit -r "$DEST_APP/Contents/PlugIns/FinderExtension.appex" 2>/dev/null || true
      "$LSREGISTER" -u "$DEST_APP" 2>/dev/null || true
      mv "$DEST_APP" "$STAGING_DIR/Failed.app"
    fi
    if [[ -n "$BACKUP_APP" && -d "$BACKUP_APP" ]]; then
      mv "$BACKUP_APP" "$DEST_APP"
      "$LSREGISTER" -f "$DEST_APP" || true
      pluginkit -a "$DEST_APP/Contents/PlugIns/FinderExtension.appex" || true
    fi
  fi
  rm -rf "$STAGING_DIR"
  exit "$result"
}
trap cleanup EXIT
ditto "$SOURCE_APP" "$STAGING_DIR/RightClickHelper.app"
codesign --verify --deep --strict "$STAGING_DIR/RightClickHelper.app"
if [[ -e "$DEST_APP" ]]; then
  EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DEST_APP/Contents/Info.plist")
  [[ "$EXISTING_ID" == 'dev.rightclickhelper.prototype' ]] || { printf '%s\n' 'Destination belongs to another app.' >&2; exit 1; }
  pluginkit -r "$DEST_APP/Contents/PlugIns/FinderExtension.appex" || true
  "$LSREGISTER" -u "$DEST_APP" || true
  mkdir -p "$PROJECT_ROOT/build/InstallBackups"
  BACKUP_DIR=$(mktemp -d "$PROJECT_ROOT/build/InstallBackups/update-XXXXXX")
  BACKUP_APP="$BACKUP_DIR/RightClickHelper.app.disabled"
  mv "$DEST_APP" "$BACKUP_APP"
fi
REPLACED=1
mv "$STAGING_DIR/RightClickHelper.app" "$DEST_APP"
codesign --verify --deep --strict "$DEST_APP"
# Xcode registers build products too. Keep the installed copy authoritative.
pluginkit -r "$SOURCE_APP/Contents/PlugIns/FinderExtension.appex" 2>/dev/null || true
"$LSREGISTER" -u "$SOURCE_APP" 2>/dev/null || true
"$LSREGISTER" -f "$DEST_APP"
pluginkit -a "$DEST_APP/Contents/PlugIns/FinderExtension.appex"
COMPLETED=1
open "$DEST_APP"
printf 'Installed: %s\nEnable “右键助手 Finder” through the app’s extension settings button.\n' "$DEST_APP"
