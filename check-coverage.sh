#!/usr/bin/env bash
set -euo pipefail

# Enforce per-directory line-coverage thresholds for the app target.
#
# Coverage in this project is LINE coverage: Xcode's xccov reports only
# coveredLines/executableLines/lineCoverage (no statement/branch metrics).
# Business logic in Sources/Managers/ is gated; Sources/Views/ is exempt
# (declarative SwiftUI bodies are only coverable via construction smoke tests)
#
# Usage:
# check-coverage.sh                   # run tests with coverage, then check
# check-coverage.sh path/to.xcresult  # check an existing result bundle

# Single source of truth for the threshold (percent).
MANAGERS_MIN=85

cd "$(dirname "$0")"

RESULT="${1:-build/TestResults.xcresult}"

if [ -z "${1:-}" ]; then
  rm -rf "$RESULT"
  xcodebuild \
    -project ClipboardTTSApp.xcodeproj \
    -scheme ClipboardTTSAppTests \
    -destination 'platform=macOS' \
    -enableCodeCoverage YES \
    -resultBundlePath "$RESULT" \
    test
fi

if [ ! -e "$RESULT" ]; then
  echo "error: result bundle not found: $RESULT" >&2
  exit 2
fi

xcrun xccov view --report --json "$RESULT" \
  | MANAGERS_MIN="$MANAGERS_MIN" /usr/bin/python3 -c '
import json, os, sys

min_pct = float(os.environ["MANAGERS_MIN"])
report = json.load(sys.stdin)

target = next((t for t in report["targets"] if t["name"] == "ClipboardTTSApp.app"), None)
if target is None:
    print("error: ClipboardTTSApp.app target not found in coverage report", file=sys.stderr)
    sys.exit(2)

groups = {"Managers": [], "Views": [], "Other": []}
for f in target["files"]:
    path = f["path"]
    if "/Sources/Managers/" in path:
        groups["Managers"].append(f)
    elif "/Sources/Views/" in path:
        groups["Views"].append(f)
    else:
        groups["Other"].append(f)

def pct(covered, executable):
    return 100.0 * covered / executable if executable else 100.0

def show(name, files):
    cov = sum(f["coveredLines"] for f in files)
    ex = sum(f["executableLines"] for f in files)
    print(f"\n{name} ({pct(cov, ex):.2f}%, {cov}/{ex}):")
    for f in sorted(files, key=lambda x: x["path"]):
        rel = f["path"].split("/Sources/", 1)[-1]
        line_pct = f["lineCoverage"] * 100
        print(f"  {line_pct:6.2f}%  Sources/{rel}")
    return cov, ex

print("=== Line coverage (app target) ===")
m_cov, m_ex = show("Managers  [gated >= %d%%]" % int(min_pct), groups["Managers"])
show("Views     [exempt]", groups["Views"])
if groups["Other"]:
    show("Other     [exempt]", groups["Other"])

managers_pct = pct(m_cov, m_ex)
print()
if managers_pct + 1e-9 < min_pct:
    print(f"FAIL: Managers line coverage {managers_pct:.2f}% is below the {min_pct:.0f}% threshold.")
    sys.exit(1)
print(f"PASS: Managers line coverage {managers_pct:.2f}% meets the {min_pct:.0f}% threshold.")
'
