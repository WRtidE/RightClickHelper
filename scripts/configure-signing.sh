#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${SIGNING_TEAM:-}" ]]; then
  SIGNING_TEAM="$(security find-certificate -c 'Apple Development' -p | openssl x509 -noout -subject -nameopt RFC2253 | sed -nE 's/.*OU=([A-Z0-9]{10})(,|$).*/\1/p')"
fi
if [[ ! "$SIGNING_TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
  printf '%s\n' 'No development team found. Run SIGNING_TEAM=YOURTEAMID bash scripts/configure-signing.sh.' >&2
  exit 1
fi
printf 'DEVELOPMENT_TEAM = %s\n' "$SIGNING_TEAM" > "$PROJECT_ROOT/Config/Local.xcconfig"
printf '%s\n' 'Local signing team configured (Config/Local.xcconfig is gitignored).'
