#!/usr/bin/env python3
"""Sample only the installed helper and its own Finder extension (read-only)."""
import argparse
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--seconds", type=int, default=300)
parser.add_argument("--interval", type=int, default=5)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
app = Path.home() / "Applications/RightClickHelper.app"
executables = {
    str(app / "Contents/MacOS/RightClickHelper"): "app",
    str(app / "Contents/PlugIns/FinderExtension.appex/Contents/MacOS/FinderExtension"): "extension",
}


def cpu_seconds(value):
    total = 0.0
    for component in value.split(":"):
        total = total * 60 + float(component)
    return total


def snapshot():
    output = subprocess.check_output(["ps", "-axo", "pid=,time=,rss=,comm="], text=True)
    found = []
    for line in output.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) != 4 or parts[3] not in executables:
            continue
        found.append(dict(pid=int(parts[0]), cpu_seconds=cpu_seconds(parts[1]),
                          rss_mib=int(parts[2]) / 1024, role=executables[parts[3]]))
    return found


start = time.monotonic()
samples = []
while True:
    elapsed = time.monotonic() - start
    samples.append(dict(elapsed_seconds=elapsed, processes=snapshot()))
    if elapsed >= args.seconds:
        break
    time.sleep(min(args.interval, args.seconds - elapsed))

first = {p["pid"]: p for p in samples[0]["processes"]}
last = {p["pid"]: p for p in samples[-1]["processes"]}
stable = set(first) == set(last) and all({p["pid"] for p in s["processes"]} == set(first) for s in samples)
cpu_delta = sum(last[pid]["cpu_seconds"] - first[pid]["cpu_seconds"] for pid in set(first) & set(last))
summary = dict(duration_seconds=samples[-1]["elapsed_seconds"], process_set_stable=stable,
               process_count=len(last),
               combined_single_core_cpu_percent=100 * cpu_delta / samples[-1]["elapsed_seconds"] if args.seconds else None,
               start_rss_mib=sum(p["rss_mib"] for p in first.values()),
               end_rss_mib=sum(p["rss_mib"] for p in last.values()),
               peak_rss_mib=max(sum(p["rss_mib"] for p in s["processes"]) for s in samples))
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(dict(summary=summary, samples=samples), indent=2))
print(json.dumps(summary, indent=2))
