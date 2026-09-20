#!/usr/bin/env bash
set -euo pipefail

# Enforce per-directory line-coverage thresholds for the app target.
#
# Coverage in this project is LINE coverage: Xcode's xccov reports only
# coveredLines/executableLines/lineCoverage (no statement/branch metrics).
# Business logic in Sources/Managers/ is gated; Sources/Views/ is exempt
# (declarative SwiftUI bodies are only coverable via construction smoke tests)
#
# The gate fails closed. A percentage is compared only once the report has been found to measure
# exactly the gated sources on disk, each carrying at least one executable line, so neither a report
# that measured none of them nor one carrying a stale record can decide the verdict. A report that
# cannot support a verdict exits 2; coverage that was measured and fell short exits 1.
#
# Usage:
# check-coverage.sh                   # run tests with coverage, then check
# check-coverage.sh path/to.xcresult  # check an existing result bundle
# check-coverage.sh path/to.json      # check an already-extracted xccov report
#
# The .json form is how verify-coverage-gate.sh drives this policy over synthetic reports.

# Single source of truth for the threshold (percent).
MANAGERS_MIN=85

cd "$(dirname "$0")"

RESULT="${1:-build/TestResults.xcresult}"
TEST_ARCH="$(uname -m)"

if [ -z "${1:-}" ]; then
  rm -rf "$RESULT"
  xcodebuild \
    -project ClipboardTTSApp.xcodeproj \
    -scheme ClipboardTTSApp \
    -destination "platform=macOS,arch=${TEST_ARCH}" \
    -enableCodeCoverage YES \
    -resultBundlePath "$RESULT" \
    test
fi

if [ ! -e "$RESULT" ]; then
  echo "error: result bundle not found: $RESULT" >&2
  exit 2
fi

# The gated population is what is on disk now, so a report that omits a gated source, or counts one
# that no longer exists, is refused rather than averaged.
GATED_SOURCES="$(find Sources/Managers -name '*.swift' 2>/dev/null | sed 's|^Sources/||' | sort)" \
  || GATED_SOURCES=""

if [ "${RESULT##*.}" = "json" ]; then
  report_json() { cat "$RESULT"; }
else
  report_json() { xcrun xccov view --report --json "$RESULT"; }
fi

# A report that could not be extracted is unmeasurable, not insufficient, so it must not reach the
# threshold comparison and exit as though coverage had been measured.
REPORT_JSON="$(report_json)" || {
  echo "error: could not extract a coverage report from $RESULT" >&2
  exit 2
}

printf '%s' "$REPORT_JSON" \
  | MANAGERS_MIN="$MANAGERS_MIN" GATED_SOURCES="$GATED_SOURCES" /usr/bin/python3 -c '
import json, os, sys

min_pct = float(os.environ["MANAGERS_MIN"])
expected_gated = {name for name in os.environ["GATED_SOURCES"].split("\n") if name}

def unmeasurable(message):
    """Refuse to report a verdict the report cannot support. Never the threshold exit code."""
    print(f"error: {message}", file=sys.stderr)
    sys.exit(2)

if not expected_gated:
    unmeasurable("no gated sources found under Sources/Managers/")

try:
    report = json.load(sys.stdin)
except ValueError as error:
    unmeasurable(f"coverage report is not valid JSON: {error}")

targets = report.get("targets") if isinstance(report, dict) else None
if not isinstance(targets, list):
    unmeasurable("coverage report declares no targets")

target = next(
    (t for t in targets if isinstance(t, dict) and t.get("name") == "ClipboardTTSApp.app"), None
)
if target is None:
    unmeasurable("ClipboardTTSApp.app target not found in coverage report")
if not isinstance(target.get("files"), list):
    unmeasurable("ClipboardTTSApp.app target declares no files")

def measurement(record):
    """One file record as (group, name relative to Sources/, display path, covered, executable).

    The relative name is read from the last /Sources/ component, so a checkout living under a
    directory that is itself named Sources still names its files the way the gated population does.
    Counts a report cannot mean — a boolean, a negative, or more covered lines than executable ones
    — are refused here rather than averaged into a percentage.
    """
    if not isinstance(record, dict):
        unmeasurable("coverage report contains a file record that is not an object")
    path = record.get("path")
    covered = record.get("coveredLines")
    executable = record.get("executableLines")
    if not isinstance(path, str):
        unmeasurable("coverage report contains a file record without a path")
    counts = (covered, executable)
    if any(isinstance(count, bool) or not isinstance(count, int) for count in counts):
        unmeasurable(f"coverage report record for {path} is missing a line count")
    if not 0 <= covered <= executable:
        unmeasurable(
            f"coverage report record for {path} counts {covered} of {executable} executable lines"
        )
    if "/Sources/" in path:
        name = path.rsplit("/Sources/", 1)[-1]
        display = "Sources/" + name
    else:
        name, display = path, path
    if name.startswith("Managers/"):
        group = "Managers"
    elif name.startswith("Views/"):
        group = "Views"
    else:
        group = "Other"
    return group, name, display, covered, executable

files = [measurement(record) for record in target["files"]]

def pct(covered, executable):
    # A population with no executable lines has no percentage. Reading it as 100% is what let a
    # report measuring nothing pass this gate.
    return "n/a" if executable == 0 else f"{100.0 * covered / executable:.2f}%"

def show(title, group):
    members = sorted((f for f in files if f[0] == group), key=lambda f: f[1])
    cov = sum(f[3] for f in members)
    ex = sum(f[4] for f in members)
    print(f"\n{title} ({pct(cov, ex)}, {cov}/{ex}):")
    for _, _, display, covered, executable in members:
        print(f"  {pct(covered, executable):>7}  {display}")
    return members, cov, ex

print("=== Line coverage (app target) ===")
gated, m_cov, m_ex = show("Managers  [gated >= %d%%]" % int(min_pct), "Managers")
show("Views     [exempt]", "Views")
if any(f[0] == "Other" for f in files):
    show("Other     [exempt]", "Other")
print()

measured_gated = {f[1] for f in gated}
absent = sorted(expected_gated - measured_gated)
if absent:
    unmeasurable("gated sources missing from the coverage report: " + ", ".join(absent))
unexpected = sorted(measured_gated - expected_gated)
if unexpected:
    unmeasurable("coverage report counts gated sources that are not on disk: " + ", ".join(unexpected))
if len(measured_gated) != len(gated):
    unmeasurable("coverage report counts a gated source more than once")
unmeasured = sorted(f[1] for f in gated if f[4] == 0)
if unmeasured:
    unmeasurable("gated sources report no executable lines: " + ", ".join(unmeasured))

# The guards above leave exactly one measured record per gated source on disk, each with at least
# one executable line, so this percentage is over the population the gate claims to measure.
managers_pct = 100.0 * m_cov / m_ex
if managers_pct + 1e-9 < min_pct:
    print(f"FAIL: Managers line coverage {managers_pct:.2f}% is below the {min_pct:.0f}% threshold.")
    sys.exit(1)
print(f"PASS: Managers line coverage {managers_pct:.2f}% meets the {min_pct:.0f}% threshold.")
'
