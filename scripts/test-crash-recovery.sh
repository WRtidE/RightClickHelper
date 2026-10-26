#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
mkdir -p build
# Compile the same shared sources as the app so model dependencies stay aligned.
swiftc Shared/*.swift scripts/crash_probe.swift -o build/crash-probe
python3 - <<'PY'
import json, pathlib, subprocess, tempfile
results = []
for phase, code, count in [('before-write', 77, 0), ('after-write', 78, 1), ('after-journal', 79, 1)]:
    root = tempfile.mkdtemp(prefix='crash-' + phase + '-', dir='build')
    child = subprocess.run(['build/crash-probe', root, phase], capture_output=True, text=True)
    assert child.returncode == code, (phase, child.stderr)
    inspection = subprocess.run(['build/crash-probe', root, 'inspect'], capture_output=True, text=True, check=True)
    assert f'files={count}' in inspection.stdout
    results.append(dict(phase=phase, exit=child.returncode, result=inspection.stdout.strip()))
pathlib.Path('build/crash-results.json').write_text(json.dumps(results, indent=2))
print(json.dumps(results, indent=2))
PY
