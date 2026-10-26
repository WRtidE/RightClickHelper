#!/bin/bash
# Read-only release/install diagnostics. Does not grant access or register bundles.
set -euo pipefail
APP="${1:-$HOME/Applications/RightClickHelper.app}"
sw_vers
test -d "$APP"
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1
pluginkit -m -A -D -v -i dev.rightclickhelper.prototype.FinderExtension
printf '%s\n' 'The following Gatekeeper check can fail for a local development build; it is not proof of notarization.'
spctl --assess --type execute --verbose "$APP" 2>&1 || true
