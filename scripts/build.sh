#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
if [[ ! -f Config/Local.xcconfig ]]; then bash scripts/configure-signing.sh; fi
xcodebuild -project RightClickHelper.xcodeproj -scheme RightClickHelper \
  -configuration Debug -derivedDataPath build/DerivedData build "$@"
codesign --verify --deep --strict build/DerivedData/Build/Products/Debug/RightClickHelper.app
